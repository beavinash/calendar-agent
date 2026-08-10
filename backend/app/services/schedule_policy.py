"""Deterministic validation for untrusted model schedule proposals."""

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import ValidationError

from app.core.config import Settings
from app.schemas.agent import (
  AgentTurnRequest,
  CalendarProposal,
  FocusEventSuggestion,
  LLMCalendarProposal,
  LLMFocusEventSuggestion,
  LLMTurn,
)


@dataclass(frozen=True)
class SchedulePolicyResult:
  """Accepted proposal drafts and safe user-facing warnings."""

  proposals: list[CalendarProposal]
  warnings: list[str]


@dataclass(frozen=True)
class FocusSuggestionPolicyResult:
  """Safe read-only suggestions and non-sensitive filter warnings."""

  suggestions: list[FocusEventSuggestion]
  warnings: list[str]


class SchedulePolicy:
  """Apply hard calendar constraints independent of model behavior."""

  _MINIMUM_BLOCK_MINUTES = 15

  def __init__(self, settings: Settings) -> None:
    """Store server-side limits."""

    self._settings = settings

  def validate(
    self,
    turn: LLMTurn,
    request: AgentTurnRequest,
  ) -> SchedulePolicyResult:
    """Filter proposals that violate time, focus, or conflict policy."""

    if not request.calendar_action_requested:
      intent_warnings: list[str] = []
      if turn.proposals:
        intent_warnings.append(
          "Unexpected calendar proposals were removed because this chat "
          "turn did not request scheduling."
        )
      return SchedulePolicyResult(
        proposals=[],
        warnings=intent_warnings,
      )

    preflight_warning = self.preflight_warning(request)
    if preflight_warning is not None:
      return SchedulePolicyResult(
        proposals=[],
        warnings=[preflight_warning],
      )

    timezone = ZoneInfo(request.preferences.timezone)

    accepted: list[CalendarProposal] = []
    warnings: list[str] = []

    for proposal in turn.proposals:
      if len(accepted) >= self._settings.max_proposals:
        warnings.append(
          "Extra proposed blocks were removed by the response limit."
        )
        break

      rejection = self._rejection_reason(
        proposal.start_at,
        proposal.end_at,
        proposal.focus_area,
        request,
        timezone,
        accepted,
      )
      if rejection is not None:
        warnings.append(rejection)
        continue

      accepted.append(CalendarProposal.model_validate(proposal.model_dump()))

    return SchedulePolicyResult(
      proposals=accepted,
      warnings=_deduplicate(warnings),
    )

  def preflight_warning(self, request: AgentTurnRequest) -> str | None:
    """Return a request-wide issue before spending a provider call."""

    timezone_warning = self.timezone_warning(request)
    if timezone_warning is not None:
      return timezone_warning
    if request.planning_end - request.planning_start > timedelta(
      days=self._settings.planning_horizon_days
    ):
      return "The requested planning horizon is too long."
    return None

  def validate_review_suggestions(
    self,
    suggestions: Sequence[LLMFocusEventSuggestion],
    request: AgentTurnRequest,
  ) -> FocusSuggestionPolicyResult:
    """Accept the negotiated all-or-zero review suggestion batch."""

    if (
      not request.focus_review_requested
      or request.focus_review_start is None
      or request.focus_review_end is None
    ):
      return FocusSuggestionPolicyResult(
        suggestions=[],
        warnings=(
          ["Unexpected review suggestions were removed."] if suggestions else []
        ),
      )

    timezone_warning = self.timezone_warning(request)
    if timezone_warning is not None:
      return FocusSuggestionPolicyResult(
        suggestions=[],
        warnings=[timezone_warning],
      )

    if not suggestions:
      return FocusSuggestionPolicyResult(suggestions=[], warnings=[])
    if len(suggestions) != request.review_suggestion_count:
      return _unsafe_review_batch(request.review_suggestion_count)

    timezone = ZoneInfo(request.preferences.timezone)
    accepted: list[FocusEventSuggestion] = []
    accepted_blocks: list[CalendarProposal] = []
    warnings: list[str] = []

    for suggestion in suggestions:
      try:
        trusted_suggestion = FocusEventSuggestion.model_validate(
          suggestion.model_dump()
        )
      except ValidationError:
        return _unsafe_review_batch(request.review_suggestion_count)
      candidate = LLMCalendarProposal(
        title=trusted_suggestion.title,
        start_at=trusted_suggestion.suggested_start_at,
        end_at=trusted_suggestion.suggested_end_at,
        focus_area=trusted_suggestion.focus_area,
        rationale=trusted_suggestion.rationale,
        notes="",
        reminder_minutes=0,
      )
      rejection = self._rejection_reason(
        candidate.start_at,
        candidate.end_at,
        candidate.focus_area,
        request,
        timezone,
        accepted_blocks,
        review_suggestion=True,
      )
      if rejection is not None:
        return _unsafe_review_batch(request.review_suggestion_count)
      accepted.append(trusted_suggestion)
      accepted_blocks.append(
        CalendarProposal.model_validate(candidate.model_dump())
      )

    return FocusSuggestionPolicyResult(
      suggestions=accepted,
      warnings=_deduplicate(warnings),
    )

  def timezone_warning(self, request: AgentTurnRequest) -> str | None:
    """Validate the shared IANA timezone without scheduling-only bounds."""

    try:
      ZoneInfo(request.preferences.timezone)
    except (ZoneInfoNotFoundError, ValueError):
      return "The requested timezone is invalid."
    return None

  def _rejection_reason(
    self,
    start_at: datetime,
    end_at: datetime,
    focus_area: object,
    request: AgentTurnRequest,
    timezone: ZoneInfo,
    accepted: list[CalendarProposal],
    *,
    review_suggestion: bool = False,
  ) -> str | None:
    """Return a non-sensitive rejection reason, or None when valid."""

    if not _is_aware(start_at) or not _is_aware(end_at):
      return "A proposed block was removed because it lacked a timezone."
    if end_at <= start_at:
      return "A proposed block was removed because its time range was invalid."
    if start_at < request.current_time:
      return "A proposed block in the past was removed."
    if start_at < request.planning_start or end_at > request.planning_end:
      return "A proposed block outside the planning window was removed."
    duration_minutes = (end_at - start_at).total_seconds() / 60
    if duration_minutes < self._MINIMUM_BLOCK_MINUTES:
      return "A proposed block was removed because it was too short."
    if duration_minutes > self._settings.max_block_minutes:
      return "A proposed block was removed because it was too long."
    if focus_area not in request.preferences.selected_focus_areas:
      return "A block for a disabled focus area was removed."

    local_start = start_at.astimezone(timezone)
    local_end = end_at.astimezone(timezone)
    if local_start.date() != local_end.date():
      return "A proposed block crossing a local day was removed."
    local_start_time = local_start.time().replace(tzinfo=None)
    local_end_time = local_end.time().replace(tzinfo=None)
    is_weekend = local_start.weekday() >= 5
    if review_suggestion and is_weekend and not 60 <= duration_minutes <= 120:
      return (
        "A weekend suggestion was removed because it was not between one "
        "and two hours."
      )

    if is_weekend:
      fits_allowed_window = (
        local_start_time >= request.preferences.weekend_start
        and local_end_time <= request.preferences.weekend_end
      )
    else:
      fits_morning = (
        local_start_time >= request.preferences.day_start
        and local_end_time <= request.preferences.morning_end
      )
      fits_evening = (
        local_start_time >= request.preferences.evening_start
        and local_end_time <= request.preferences.day_end
      )
      fits_allowed_window = fits_morning or fits_evening
    if not fits_allowed_window:
      return (
        "A proposed block outside the allowed scheduling windows was removed."
      )

    meal_windows = (
      (
        request.preferences.breakfast_start,
        request.preferences.breakfast_end,
      ),
      (request.preferences.lunch_start, request.preferences.lunch_end),
      (request.preferences.dinner_start, request.preferences.dinner_end),
    )
    if any(
      _wall_clock_overlaps(
        local_start_time,
        local_end_time,
        meal_start,
        meal_end,
      )
      for meal_start, meal_end in meal_windows
    ):
      return "A proposed block overlapping a protected meal was removed."

    existing_agent_count = sum(
      event.focus_area is not None
      and event.start_at.astimezone(timezone).date() == local_start.date()
      for event in request.calendar
    )
    accepted_count = sum(
      existing.start_at.astimezone(timezone).date() == local_start.date()
      for existing in accepted
    )
    if (
      existing_agent_count + accepted_count
      >= request.preferences.max_daily_blocks
    ):
      return "Extra proposed blocks were removed by the daily limit."

    buffer = timedelta(minutes=request.preferences.minimum_break_minutes)
    buffered_start = start_at - buffer
    buffered_end = end_at + buffer
    for event in request.calendar:
      if _overlaps(
        buffered_start,
        buffered_end,
        event.start_at,
        event.end_at,
      ):
        return "A proposed block conflicting with the calendar was removed."
    for proposal in accepted:
      if _overlaps(
        buffered_start,
        buffered_end,
        proposal.start_at,
        proposal.end_at,
      ):
        return "Overlapping proposed blocks were removed."
    return None


def _is_aware(value: datetime) -> bool:
  """Return whether a datetime represents an absolute instant."""

  return value.tzinfo is not None and value.utcoffset() is not None


def _overlaps(
  left_start: datetime,
  left_end: datetime,
  right_start: datetime,
  right_end: datetime,
) -> bool:
  """Return whether two half-open intervals overlap."""

  return left_start < right_end and left_end > right_start


def _wall_clock_overlaps(
  left_start: time,
  left_end: time,
  right_start: time,
  right_end: time,
) -> bool:
  """Return whether two validated same-type wall-clock intervals overlap."""

  return left_start < right_end and left_end > right_start


def _deduplicate(values: list[str]) -> list[str]:
  """Preserve warning order while removing duplicates."""

  return list(dict.fromkeys(values))


def _unsafe_review_batch(
  expected_count: int,
) -> FocusSuggestionPolicyResult:
  """Return the single safe warning for an unusable confirmation batch."""

  count_label = {5: "five", 7: "seven"}.get(
    expected_count,
    str(expected_count),
  )
  return FocusSuggestionPolicyResult(
    suggestions=[],
    warnings=[
      f"All {count_label} suggestions were withheld because one or more "
      "could not be scheduled safely."
    ],
  )
