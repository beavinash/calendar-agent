"""Agent orchestration with no direct calendar side effects."""

import logging
import re
from datetime import datetime
from uuid import uuid4

from app.core.config import Settings
from app.core.exceptions import InvalidPlanningRequestError
from app.core.llm.base import LLMProviderBuilder
from app.repositories.agent_turn_repository import AgentTurnAuditWriter
from app.schemas.agent import (
  AgentTurnRequest,
  AgentTurnResponse,
  CalendarEventSnapshot,
  EvidenceConfidence,
  FocusArea,
  FocusReviewResult,
  HistoryCoverage,
  LLMFocusAreaReview,
  LLMTurn,
  ScheduleVisibility,
)
from app.services.follow_through import (
  FollowThroughSummary,
  summarize_follow_through,
)
from app.services.prompt_builder import PromptBuilder
from app.services.schedule_policy import SchedulePolicy

logger = logging.getLogger(__name__)

_TITLE_PATTERNS: dict[FocusArea, tuple[str, ...]] = {
  FocusArea.WORK: (
    r"\bwork\b",
    r"\boffice\b",
    r"\bclient(?:s)?\b",
    r"\bjob\b",
  ),
  FocusArea.STUDY: (
    r"\bstud(?:y|ying)\b",
    r"\bclass(?:es)?\b",
    r"\bcourse(?:work)?\b",
    r"\bhomework\b",
    r"\blecture(?:s)?\b",
  ),
  FocusArea.EXERCISE: (
    r"\bexercise\b",
    r"\bworkout\b",
    r"\bgym\b",
    r"\brunning\b",
    r"\bjog(?:ging)?\b",
  ),
  FocusArea.APPOINTMENTS: (
    r"\bappointments?\b",
    r"\bmeetings?\b",
    r"\bconsultation\b",
    r"\bdoctor(?:'s)? visit\b",
    r"\bdentist(?:'s)? visit\b",
  ),
  FocusArea.ERRANDS: (
    r"\berrands?\b",
    r"\bgrocer(?:y|ies)\b",
    r"\bshopping\b",
    r"\bpick[- ]?up\b",
    r"\bdrop[- ]?off\b",
    r"\bpharmacy\b",
  ),
}

_AMBIGUOUS_INTEREST_TITLE_PATTERNS = (
  r"\bdeep work\b",
  r"\bfocus(?:ed)?(?: block| session| time)?\b",
  r"\bpractice\b",
  r"\bproject\b",
  r"\bresearch\b",
  r"\bsession\b",
  r"\btraining\b",
)


class AgentService:
  """Compose prompts, call one provider, validate, and audit metadata."""

  def __init__(
    self,
    settings: Settings,
    provider_factory: LLMProviderBuilder,
    audit_writer: AgentTurnAuditWriter,
    prompt_builder: PromptBuilder | None = None,
  ) -> None:
    """Initialize injected, testable boundaries."""

    self._settings = settings
    self._provider_factory = provider_factory
    self._audit_writer = audit_writer
    self._prompt_builder = prompt_builder or PromptBuilder()
    self._policy = SchedulePolicy(settings)

  async def create_turn(
    self,
    request: AgentTurnRequest,
    api_key_override: str | None,
  ) -> AgentTurnResponse:
    """Generate a proposal-only turn and store aggregate audit metadata."""

    if request.calendar_action_requested:
      preflight_warning = self._policy.preflight_warning(request)
      if preflight_warning is not None:
        raise InvalidPlanningRequestError(preflight_warning)
    elif request.focus_review_requested:
      preflight_warning = self._policy.preflight_warning(request)
      if preflight_warning is not None:
        raise InvalidPlanningRequestError(preflight_warning)

    provider = self._provider_factory.create(
      request.provider,
      request.model,
      api_key_override,
    )
    effective_provider = (
      "openai"
      if self._settings.environment.lower() == "production"
      else request.provider
    )
    try:
      turn = await provider.generate_turn(
        self._prompt_builder.system_prompt,
        self._prompt_builder.build_user_prompt(
          request,
          self._settings.max_block_minutes,
          self._settings.max_proposals,
        ),
      )
    finally:
      try:
        await provider.close()
      except Exception:
        logger.warning("Model provider transport cleanup failed")
    policy_result = self._policy.validate(turn, request)
    warnings = list(policy_result.warnings)
    focus_review = self._focus_review_result(turn, request, warnings)
    request_id = uuid4()
    rejected_count = len(turn.proposals) - len(policy_result.proposals)

    try:
      await self._audit_writer.create(
        request_id=request_id,
        device_id=request.device_id,
        provider=effective_provider,
        model=provider.model,
        proposal_count=len(policy_result.proposals),
        rejected_count=rejected_count,
      )
    except Exception:
      logger.warning(
        "Agent turn audit write failed for request_id=%s",
        request_id,
      )

    message = turn.message
    check_in_question = turn.check_in_question
    if request.focus_review_requested:
      message = (
        "Here is your calendar review. Eligible ended unmarked events since "
        "tracking began are treated as 70% likely incomplete in coaching "
        "insights."
        if focus_review is not None
        else "I could not produce a reliable interest schedule review."
      )
      check_in_question = (
        "Which past scheduled blocks did you actually follow through on?"
      )

    return AgentTurnResponse(
      request_id=request_id,
      message=message,
      proposals=policy_result.proposals,
      check_in_question=check_in_question,
      warnings=list(dict.fromkeys(warnings)),
      provider=effective_provider,
      model=provider.model,
      focus_review=focus_review,
    )

  def _focus_review_result(
    self,
    turn: LLMTurn,
    request: AgentTurnRequest,
    warnings: list[str],
  ) -> FocusReviewResult | None:
    """Bind model interpretation to deterministic calendar limitations."""

    if not request.focus_review_requested:
      if turn.focus_review is not None:
        warnings.append(
          "An unexpected interest review was removed because this turn did not "
          "request one."
        )
      return None
    if turn.focus_review is None:
      warnings.append("The model did not return the required interest review.")
      return None

    recent_start = request.focus_review_start
    period_end = request.focus_review_end
    upcoming_end = request.planning_end
    period = request.focus_review_period
    if recent_start is None or period_end is None or period is None:
      return None
    history_coverage = _history_coverage(
      recent_start,
      period_end,
      request.tracking_started_at,
    )

    expected_areas = set(request.preferences.selected_focus_areas)
    provider_areas = {area.focus_area: area for area in turn.focus_review.areas}
    if set(provider_areas) != expected_areas:
      warnings.append(
        "The model review did not match the selected interest areas."
      )
      return None

    areas: list[LLMFocusAreaReview] = []
    has_unclear_area = False
    for focus_area in request.preferences.selected_focus_areas:
      area = provider_areas[focus_area]
      recent_explicit, recent_inferred, recent_ambiguous = _period_counts(
        request.review_calendar,
        recent_start,
        period_end,
        focus_area,
      )
      upcoming_explicit, upcoming_inferred, upcoming_ambiguous = _period_counts(
        request.calendar,
        request.planning_start,
        upcoming_end,
        focus_area,
      )
      completion_summary = _completion_summary(
        request.review_calendar,
        recent_start,
        period_end,
        focus_area,
        request.current_time,
        request.tracking_started_at,
      )
      recent_count = recent_explicit + recent_inferred
      upcoming_count = upcoming_explicit + upcoming_inferred
      recent_visibility = _visibility(recent_count, recent_ambiguous)
      upcoming_visibility = _visibility(upcoming_count, upcoming_ambiguous)
      inferred_count = recent_inferred + upcoming_inferred
      ambiguous_count = recent_ambiguous + upcoming_ambiguous

      if recent_count or upcoming_count:
        evidence = (
          "Agent labels or clear title keywords show "
          f"{recent_count} reviewed and {upcoming_count} upcoming scheduled "
          "event(s) for this area."
        )
        if ambiguous_count:
          evidence += " Other unlabelled titles remain ambiguous."
      elif ambiguous_count:
        evidence = (
          "One or more unlabelled event titles are too ambiguous to assign "
          "to this area."
        )
      else:
        evidence = (
          "No scheduled event for this area is visible in the supplied periods."
        )
      if completion_summary.eligible_count:
        evidence += (
          " Follow-through: "
          f"{completion_summary.explicit_complete_count} user-marked "
          "complete, "
          f"{completion_summary.explicit_incomplete_count} user-marked "
          "incomplete, "
          f"{completion_summary.inferred_unmarked_count} unmarked ended"
        )
        if completion_summary.inferred_unmarked_count:
          evidence += (
            " (70% likely incomplete; estimated incomplete weight "
            f"{completion_summary.estimated_incomplete_weight:.1f})."
          )
        else:
          evidence += "."

      if (
        recent_visibility == ScheduleVisibility.UNCLEAR
        or upcoming_visibility == ScheduleVisibility.UNCLEAR
      ):
        confidence = EvidenceConfidence.LOW
      elif inferred_count:
        confidence = EvidenceConfidence.MEDIUM
      else:
        confidence = EvidenceConfidence.HIGH
      if (
        completion_summary.inferred_unmarked_count
        and confidence == EvidenceConfidence.HIGH
      ):
        confidence = EvidenceConfidence.MEDIUM

      history_incomplete = (
        request.review_calendar_context_truncated
        or history_coverage != HistoryCoverage.FULL
      )
      if history_incomplete:
        if recent_visibility == ScheduleVisibility.NOT_VISIBLE:
          recent_visibility = ScheduleVisibility.UNCLEAR
        confidence = EvidenceConfidence.LOW
        if history_coverage == HistoryCoverage.PARTIAL:
          prefix = "Tracking covers only part of this period. "
        elif history_coverage == HistoryCoverage.BEFORE_TRACKING:
          prefix = "This period is before tracking began. "
        else:
          prefix = "Historical snapshot incomplete. "
        evidence = f"{prefix}{evidence}"[:300].rstrip()
      if request.calendar_context_truncated:
        if upcoming_visibility == ScheduleVisibility.NOT_VISIBLE:
          upcoming_visibility = ScheduleVisibility.UNCLEAR
        confidence = EvidenceConfidence.LOW
        prefix = "Future availability snapshot incomplete. "
        evidence = f"{prefix}{evidence}"[:300].rstrip()

      area_is_unclear = (
        recent_visibility == ScheduleVisibility.UNCLEAR
        or upcoming_visibility == ScheduleVisibility.UNCLEAR
      )
      has_unclear_area = has_unclear_area or area_is_unclear
      likely_impact = area.likely_impact
      if recent_visibility == ScheduleVisibility.UNCLEAR:
        likely_impact = (
          "Unknown because the supplied calendar evidence is incomplete or "
          "ambiguous."
        )

      areas.append(
        LLMFocusAreaReview(
          focus_area=focus_area,
          recent_visibility=recent_visibility,
          upcoming_visibility=upcoming_visibility,
          scheduled_evidence=evidence,
          likely_impact=likely_impact,
          confidence=confidence,
        )
      )

    if request.review_calendar_context_truncated:
      warnings.append(
        "The historical Apple Calendar snapshot was incomplete, so absence is "
        "shown as unclear."
      )
    if request.calendar_context_truncated:
      warnings.append(
        "The future Apple Calendar snapshot was incomplete, so availability is "
        "unclear."
      )
    next_adjustment = turn.focus_review.next_adjustment
    if has_unclear_area:
      next_adjustment = (
        "Confirm ambiguous interest events in chat before changing the "
        "schedule."
      )

    suggestion_result = self._policy.validate_review_suggestions(
      turn.focus_review.suggested_events,
      request,
    )
    warnings.extend(suggestion_result.warnings)

    return FocusReviewResult(
      areas=areas,
      next_adjustment=next_adjustment,
      suggested_events=suggestion_result.suggestions,
      period=period,
      recent_start_at=recent_start,
      period_end_at=period_end,
      current_time=request.current_time,
      upcoming_end_at=upcoming_end,
      tracking_started_at=request.tracking_started_at,
      history_coverage=history_coverage,
      completion_evidence=(
        "user_input"
        if any(
          event.completion_status is not None
          for event in request.review_calendar
        )
        else "not_provided"
      ),
      context_truncated=(
        request.review_calendar_context_truncated
        or request.calendar_context_truncated
      ),
    )


def _period_counts(
  events: list[CalendarEventSnapshot],
  start: datetime,
  end: datetime,
  focus_area: FocusArea,
) -> tuple[int, int, int]:
  """Count explicit, clearly inferred, and ambiguous scheduled events."""

  explicit = 0
  inferred = 0
  ambiguous = 0
  for event in events:
    if event.start_at >= end or event.end_at <= start:
      continue
    if event.focus_area == focus_area:
      explicit += 1
      continue
    if event.focus_area is not None:
      continue
    inferred_areas = _title_focus_areas(event.title)
    if focus_area in inferred_areas:
      inferred += 1
    elif not inferred_areas and _is_ambiguous_interest_title(event.title):
      ambiguous += 1
  return explicit, inferred, ambiguous


def _completion_summary(
  events: list[CalendarEventSnapshot],
  start: datetime,
  end: datetime,
  focus_area: FocusArea,
  current_time: datetime,
  tracking_started_at: datetime,
) -> FollowThroughSummary:
  """Summarize matched historical outcomes and 70% inferences."""

  matched = [
    event
    for event in events
    if event.start_at < end
    and event.end_at > start
    and (
      event.focus_area == focus_area
      or (
        event.focus_area is None
        and focus_area in _title_focus_areas(event.title)
      )
    )
  ]
  return summarize_follow_through(
    matched,
    current_time,
    tracking_started_at,
  )


def _history_coverage(
  period_start: datetime,
  period_end: datetime,
  tracking_started_at: datetime,
) -> HistoryCoverage:
  """Classify review coverage relative to first app use."""

  if tracking_started_at <= period_start:
    return HistoryCoverage.FULL
  if tracking_started_at >= period_end:
    return HistoryCoverage.BEFORE_TRACKING
  return HistoryCoverage.PARTIAL


def _title_focus_areas(title: str | None) -> set[FocusArea]:
  """Classify only titles containing conservative, explicit domain terms."""

  if not title:
    return set()
  lowered = title.casefold()
  return {
    area
    for area, patterns in _TITLE_PATTERNS.items()
    if any(re.search(pattern, lowered) for pattern in patterns)
  }


def _is_ambiguous_interest_title(title: str | None) -> bool:
  """Return whether an unclassified title could still hide an interest."""

  if title is None or not title.strip():
    return True
  lowered = title.casefold().strip()
  if lowered in {"busy", "private", "redacted", "untitled"}:
    return True
  return any(
    re.search(pattern, lowered)
    for pattern in _AMBIGUOUS_INTEREST_TITLE_PATTERNS
  )


def _visibility(count: int, ambiguous_count: int) -> ScheduleVisibility:
  """Return a fail-closed visibility from deterministic calendar evidence."""

  if count:
    return ScheduleVisibility.VISIBLE
  if ambiguous_count:
    return ScheduleVisibility.UNCLEAR
  return ScheduleVisibility.NOT_VISIBLE
