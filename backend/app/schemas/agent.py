"""Typed contracts for agent planning turns."""

from __future__ import annotations

import re
from datetime import datetime, time, timedelta
from enum import StrEnum
from typing import Literal, Self
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import (
  BaseModel,
  ConfigDict,
  Field,
  field_validator,
  model_validator,
)


class StrictModel(BaseModel):
  """Schema base that rejects silent contract drift."""

  model_config = ConfigDict(extra="forbid")


class FocusArea(StrEnum):
  """The first-class coaching domains."""

  WORK = "work"
  STUDY = "study"
  EXERCISE = "exercise"
  APPOINTMENTS = "appointments"
  ERRANDS = "errands"


class ScheduleVisibility(StrEnum):
  """Whether a focus area is visible in the supplied calendar window."""

  VISIBLE = "visible"
  NOT_VISIBLE = "not_visible"
  UNCLEAR = "unclear"


class EvidenceConfidence(StrEnum):
  """Confidence supported by explicit labels or interpretable titles."""

  HIGH = "high"
  MEDIUM = "medium"
  LOW = "low"


class FocusReviewPeriod(StrEnum):
  """Trusted review selection with Today/last-period semantics."""

  DAY = "day"
  WEEK = "week"
  MONTH = "month"


class CompletionStatus(StrEnum):
  """Explicit follow-through status supplied by the user."""

  COMPLETE = "complete"
  INCOMPLETE = "incomplete"


class HistoryCoverage(StrEnum):
  """How much of a review period occurred after tracking began."""

  FULL = "full"
  PARTIAL = "partial"
  BEFORE_TRACKING = "before_tracking"


class FocusSuggestionAction(StrEnum):
  """Required one-click confirmation before on-device scheduling."""

  REQUIRES_EXPLICIT_SCHEDULING = "requires_explicit_scheduling"


LEGACY_REVIEW_SUGGESTION_COUNT = 5
REQUIRED_REVIEW_SUGGESTION_COUNT = 7
MAX_MISSED_PATTERN_GROUPS = 25


class CalendarEventSnapshot(StrictModel):
  """Privacy-minimized event interval sent from the device."""

  event_id: str = Field(min_length=1, max_length=128)
  calendar_id: str = Field(min_length=1, max_length=128)
  start_at: datetime
  end_at: datetime
  is_all_day: bool = False
  title: str | None = Field(default=None, max_length=120)
  focus_area: FocusArea | None = None
  completion_status: CompletionStatus | None = None

  @model_validator(mode="after")
  def validate_interval(self) -> Self:
    """Require timezone-aware, positive event intervals."""

    _require_aware(self.start_at, "start_at")
    _require_aware(self.end_at, "end_at")
    if self.end_at <= self.start_at:
      raise ValueError("end_at must be after start_at")
    return self


class NoteContext(StrictModel):
  """A bounded local note explicitly selected for model context."""

  id: UUID
  text: str = Field(min_length=1, max_length=1500)
  focus_area: FocusArea | None = None
  created_at: datetime

  @field_validator("created_at")
  @classmethod
  def validate_created_at(cls, value: datetime) -> datetime:
    """Require an absolute note timestamp."""

    return _require_aware(value, "created_at")


class ConversationMessage(StrictModel):
  """A bounded recent chat message."""

  role: Literal["user", "assistant"]
  content: str = Field(min_length=1, max_length=4000)


class CalendarPreferences(StrictModel):
  """User planning constraints and selected areas."""

  timezone: str = Field(min_length=1, max_length=64)
  day_start: time = time(hour=6)
  morning_end: time = time(hour=8)
  evening_start: time = time(hour=17, minute=30)
  day_end: time = time(hour=23)
  week_starts_on: int = Field(default=1, ge=1, le=7)
  weekend_start: time = time(hour=6)
  weekend_end: time = time(hour=23)
  breakfast_start: time = time(hour=7, minute=45)
  breakfast_end: time = time(hour=8, minute=15)
  lunch_start: time = time(hour=11, minute=30)
  lunch_end: time = time(hour=12)
  dinner_start: time = time(hour=19)
  dinner_end: time = time(hour=19, minute=30)
  minimum_break_minutes: int = Field(default=10, ge=0, le=120)
  max_daily_blocks: int = Field(default=5, ge=1, le=5)
  selected_focus_areas: list[FocusArea] = Field(
    default_factory=lambda: list(FocusArea),
    min_length=1,
    max_length=5,
  )

  @field_validator(
    "day_start",
    "morning_end",
    "evening_start",
    "day_end",
    "weekend_start",
    "weekend_end",
    "breakfast_start",
    "breakfast_end",
    "lunch_start",
    "lunch_end",
    "dinner_start",
    "dinner_end",
  )
  @classmethod
  def validate_wall_clock(cls, value: time) -> time:
    """Keep offsets in the separate IANA timezone field."""

    if value.tzinfo is not None:
      raise ValueError("active-hour times must not include an offset")
    return value

  @model_validator(mode="after")
  def validate_active_day(self) -> Self:
    """Require two ordered local scheduling windows."""

    if not (
      self.day_start < self.morning_end < self.evening_start < self.day_end
    ):
      raise ValueError(
        "planning boundaries must be ordered: day_start, morning_end, "
        "evening_start, day_end"
      )
    if not self.weekend_start < self.weekend_end:
      raise ValueError("weekend_start must be before weekend_end")
    if not (
      self.weekend_start
      <= self.breakfast_start
      < self.breakfast_end
      <= self.lunch_start
      < self.lunch_end
      <= self.dinner_start
      < self.dinner_end
      <= self.weekend_end
    ):
      raise ValueError("meal windows must be ordered inside the active day")
    if len(set(self.selected_focus_areas)) != len(self.selected_focus_areas):
      raise ValueError("selected_focus_areas must be unique")
    return self


class MissedPatternTrackingCoverage(StrEnum):
  """How much of the aggregate window occurred after tracking began."""

  FULL = "full"
  PARTIAL = "partial"
  NONE = "none"


class MissedPatternGroup(StrictModel):
  """One deterministic title family without calendar identifiers."""

  rank: int = Field(ge=1, le=MAX_MISSED_PATTERN_GROUPS)
  display_title: str = Field(min_length=1, max_length=120)
  missed_count: int = Field(ge=1, le=10_000)
  inferred_unmarked_count: int = Field(ge=0, le=10_000)
  explicit_incomplete_count: int = Field(ge=0, le=10_000)

  @field_validator("display_title")
  @classmethod
  def reject_blank_title(cls, value: str) -> str:
    """Reject whitespace-only titles after the length check."""

    if not value.strip():
      raise ValueError("display_title must not be blank")
    return value

  @model_validator(mode="after")
  def validate_count_breakdown(self) -> Self:
    """The total is exactly explicit plus probabilistically inferred."""

    if self.missed_count != (
      self.inferred_unmarked_count + self.explicit_incomplete_count
    ):
      raise ValueError("missed_count must equal explicit plus inferred")
    return self


class MissedPatternContext(StrictModel):
  """Bounded aggregate shown locally before an explicit AI action."""

  source_review_period: FocusReviewPeriod
  window_start_at: datetime
  window_end_at: datetime
  tracking_coverage: MissedPatternTrackingCoverage
  evaluated_event_count: int = Field(ge=0, le=10_000)
  covered_evaluated_event_count: int = Field(ge=0, le=10_000)
  missed_event_count: int = Field(ge=0, le=10_000)
  inferred_unmarked_count: int = Field(ge=0, le=10_000)
  explicit_incomplete_count: int = Field(ge=0, le=10_000)
  omitted_group_count: int = Field(ge=0, le=10_000)
  groups: list[MissedPatternGroup] = Field(
    default_factory=list,
    max_length=MAX_MISSED_PATTERN_GROUPS,
  )

  @model_validator(mode="after")
  def validate_aggregate(self) -> Self:
    """Require aware bounds, ranked groups, and internally consistent totals."""

    _require_aware(self.window_start_at, "window_start_at")
    _require_aware(self.window_end_at, "window_end_at")
    if self.window_end_at <= self.window_start_at:
      raise ValueError("missed pattern window must be positive")
    if self.covered_evaluated_event_count > self.evaluated_event_count:
      raise ValueError("covered count cannot exceed evaluated count")
    if self.missed_event_count > self.evaluated_event_count:
      raise ValueError("missed count cannot exceed evaluated count")
    if self.missed_event_count != (
      self.inferred_unmarked_count + self.explicit_incomplete_count
    ):
      raise ValueError("missed count must equal explicit plus inferred")
    if [group.rank for group in self.groups] != list(
      range(1, len(self.groups) + 1)
    ):
      raise ValueError("missed pattern ranks must be contiguous and ordered")

    group_missed = sum(group.missed_count for group in self.groups)
    group_inferred = sum(group.inferred_unmarked_count for group in self.groups)
    group_explicit = sum(
      group.explicit_incomplete_count for group in self.groups
    )
    if (
      group_missed > self.missed_event_count
      or group_inferred > self.inferred_unmarked_count
      or group_explicit > self.explicit_incomplete_count
    ):
      raise ValueError("missed pattern group totals exceed aggregate totals")
    if self.omitted_group_count == 0 and (
      group_missed != self.missed_event_count
      or group_inferred != self.inferred_unmarked_count
      or group_explicit != self.explicit_incomplete_count
    ):
      raise ValueError("complete missed pattern groups must match totals")
    if (
      self.omitted_group_count and len(self.groups) != MAX_MISSED_PATTERN_GROUPS
    ):
      raise ValueError("omitted groups require a full bounded group list")
    return self


class AgentTurnRequest(StrictModel):
  """One context-bounded coaching and planning request."""

  device_id: UUID
  message: str = Field(min_length=1, max_length=4000)
  calendar_action_requested: bool = False
  focus_review_requested: bool = False
  focus_review_period: FocusReviewPeriod | None = None
  focus_review_start: datetime | None = None
  focus_review_end: datetime | None = None
  review_calendar_context_truncated: bool = False
  calendar_context_truncated: bool = False
  review_suggestion_count: Literal[5, 7] = 5
  missed_pattern_context: MissedPatternContext | None = None
  provider: Literal["openai", "gemini"] = "openai"
  model: str | None = Field(
    default=None,
    min_length=1,
    max_length=80,
    pattern=r"^[A-Za-z0-9._-]+$",
  )
  current_time: datetime
  tracking_started_at: datetime
  planning_start: datetime
  planning_end: datetime
  preferences: CalendarPreferences
  calendar: list[CalendarEventSnapshot] = Field(
    default_factory=list,
    max_length=300,
  )
  review_calendar: list[CalendarEventSnapshot] = Field(
    default_factory=list,
    max_length=300,
  )
  notes: list[NoteContext] = Field(default_factory=list, max_length=20)
  history: list[ConversationMessage] = Field(
    default_factory=list,
    max_length=20,
  )

  @model_validator(mode="after")
  def validate_planning_window(self) -> Self:
    """Require bounded planning and explicit period review context."""

    for name in (
      "current_time",
      "tracking_started_at",
      "planning_start",
      "planning_end",
    ):
      _require_aware(getattr(self, name), name)
    if self.tracking_started_at > self.current_time:
      raise ValueError("tracking_started_at must not be in the future")
    if self.planning_end <= self.planning_start:
      raise ValueError("planning_end must be after planning_start")
    if self.planning_end - self.planning_start > timedelta(days=31):
      raise ValueError("planning window must not exceed 31 days")

    if self.focus_review_requested and self.calendar_action_requested:
      raise ValueError("a focus review cannot also schedule calendar events")
    if self.focus_review_requested:
      if (
        self.planning_start < self.current_time
        or self.planning_end <= self.current_time
      ):
        raise ValueError(
          "focus review suggestions require a future planning window"
        )
      if (
        self.focus_review_period is None
        or self.focus_review_start is None
        or self.focus_review_end is None
      ):
        raise ValueError("focus review period and bounds are required")
      _require_aware(self.focus_review_start, "focus_review_start")
      _require_aware(self.focus_review_end, "focus_review_end")
      _validate_review_period_bounds(
        self.focus_review_period,
        self.focus_review_start,
        self.focus_review_end,
        self.current_time,
        self.preferences.timezone,
        self.preferences.week_starts_on,
      )
      if any(
        event.end_at <= self.focus_review_start
        or event.start_at >= self.focus_review_end
        for event in self.review_calendar
      ):
        raise ValueError("focus review event is outside the review window")
    elif any(
      value is not None
      for value in (
        self.focus_review_period,
        self.focus_review_start,
        self.focus_review_end,
      )
    ):
      raise ValueError("focus review period and bounds require review intent")

    if self.review_calendar and not self.focus_review_requested:
      raise ValueError("review calendar requires explicit review intent")
    if (
      self.review_calendar_context_truncated and not self.focus_review_requested
    ):
      raise ValueError("review calendar truncation requires review intent")

    if self.missed_pattern_context is not None:
      if not self.focus_review_requested:
        raise ValueError(
          "missed pattern context requires explicit focus review intent"
        )
      if (
        self.missed_pattern_context.source_review_period
        != self.focus_review_period
      ):
        raise ValueError(
          "missed pattern source period must match focus review period"
        )
      _validate_missed_pattern_bounds(
        self.missed_pattern_context,
        self.current_time,
        self.tracking_started_at,
        self.preferences.timezone,
        self.preferences.week_starts_on,
      )

    if any(event.title is not None for event in self.calendar):
      raise ValueError("future availability calendar must not contain titles")
    if any(event.completion_status is not None for event in self.calendar):
      raise ValueError(
        "future availability calendar must not contain completion status"
      )
    if any(
      event.end_at <= self.planning_start or event.start_at >= self.planning_end
      for event in self.calendar
    ):
      raise ValueError("future availability event is outside planning window")

    has_calendar_intent = (
      self.calendar_action_requested or self.focus_review_requested
    )
    if self.calendar and not has_calendar_intent:
      raise ValueError("calendar context requires planning or review intent")
    if self.calendar_context_truncated and not has_calendar_intent:
      raise ValueError("calendar truncation requires planning or review intent")
    return self


class LLMCalendarProposal(StrictModel):
  """Untrusted structured proposal returned by a model provider."""

  title: str = Field(min_length=1, max_length=80)
  start_at: datetime
  end_at: datetime
  focus_area: FocusArea
  rationale: str = Field(min_length=1, max_length=300)
  notes: str = Field(max_length=500)
  reminder_minutes: int = Field(ge=0, le=1440)


class LLMFocusAreaReview(StrictModel):
  """One model interpretation grounded in scheduled calendar evidence."""

  focus_area: FocusArea
  recent_visibility: ScheduleVisibility
  upcoming_visibility: ScheduleVisibility
  scheduled_evidence: str = Field(min_length=1, max_length=300)
  likely_impact: str = Field(min_length=1, max_length=300)
  confidence: EvidenceConfidence

  @field_validator("scheduled_evidence", "likely_impact")
  @classmethod
  def reject_completion_claims(cls, value: str) -> str:
    """Calendar evidence cannot establish real-world completion."""

    return _reject_unsupported_review_claims(value)

  @field_validator("likely_impact")
  @classmethod
  def require_conditional_impact(cls, value: str) -> str:
    """Goal impact must remain a possibility rather than fabricated fact."""

    lowered = value.strip().casefold()
    if not lowered.startswith(("may ", "could ", "if ", "unknown")):
      raise ValueError("likely impact must be conditional or unknown")
    return value


class LLMFocusEventSuggestion(StrictModel):
  """Untrusted review suggestion draft returned by a model provider."""

  focus_area: FocusArea
  title: str = Field(min_length=1, max_length=80)
  suggested_start_at: datetime
  suggested_end_at: datetime
  rationale: str = Field(min_length=1, max_length=300)
  confidence: EvidenceConfidence
  action: FocusSuggestionAction


class FocusEventSuggestion(LLMFocusEventSuggestion):
  """Validated read-only advice awaiting one-click confirmation."""

  @field_validator("rationale")
  @classmethod
  def reject_unsupported_rationale_claims(cls, value: str) -> str:
    """A suggestion cannot claim an outcome calendar data cannot prove."""

    return _reject_unsupported_review_claims(value)

  @model_validator(mode="after")
  def validate_interval(self) -> Self:
    """Require an absolute, positive suggestion interval."""

    _require_aware(self.suggested_start_at, "suggested_start_at")
    _require_aware(self.suggested_end_at, "suggested_end_at")
    if self.suggested_end_at <= self.suggested_start_at:
      raise ValueError("suggested_end_at must be after suggested_start_at")
    return self


class LLMFocusReview(StrictModel):
  """Selected-interest review returned by a model provider."""

  areas: list[LLMFocusAreaReview] = Field(min_length=1, max_length=5)
  next_adjustment: str = Field(min_length=1, max_length=300)
  suggested_events: list[LLMFocusEventSuggestion] = Field(
    max_length=REQUIRED_REVIEW_SUGGESTION_COUNT
  )

  @field_validator("next_adjustment")
  @classmethod
  def reject_unsupported_adjustment_claims(cls, value: str) -> str:
    """A recommendation cannot smuggle in an unsupported outcome claim."""

    return _reject_unsupported_review_claims(value)

  @model_validator(mode="after")
  def require_unique_focus_areas(self) -> Self:
    """Prevent duplicate review areas in the provider draft."""

    if len({area.focus_area for area in self.areas}) != len(self.areas):
      raise ValueError("focus review areas must be unique")
    return self


class LLMTurn(StrictModel):
  """Provider-level structured output."""

  message: str = Field(min_length=1, max_length=4000)
  proposals: list[LLMCalendarProposal] = Field(max_length=5)
  check_in_question: str | None = Field(max_length=300)
  focus_review: LLMFocusReview | None = None


class CalendarProposal(LLMCalendarProposal):
  """Validated proposal crossing the on-device execution boundary."""

  proposal_id: UUID = Field(default_factory=uuid4)


class FocusReviewResult(StrictModel):
  """Review result with deterministic device-context limitations."""

  areas: list[LLMFocusAreaReview] = Field(min_length=1, max_length=5)
  next_adjustment: str = Field(min_length=1, max_length=300)
  suggested_events: list[FocusEventSuggestion] = Field(
    max_length=REQUIRED_REVIEW_SUGGESTION_COUNT
  )
  period: FocusReviewPeriod
  recent_start_at: datetime
  period_end_at: datetime
  current_time: datetime
  upcoming_end_at: datetime
  tracking_started_at: datetime
  history_coverage: HistoryCoverage
  completion_evidence: Literal["not_provided", "user_input"] = "not_provided"
  context_truncated: bool

  @field_validator("next_adjustment")
  @classmethod
  def reject_unsupported_adjustment_claims(cls, value: str) -> str:
    """A trusted result cannot contain an unsupported outcome claim."""

    return _reject_unsupported_review_claims(value)

  @model_validator(mode="after")
  def validate_review_window(self) -> Self:
    """Keep the displayed evidence windows absolute and ordered."""

    if len({area.focus_area for area in self.areas}) != len(self.areas):
      raise ValueError("focus review areas must be unique")
    _require_aware(self.recent_start_at, "recent_start_at")
    _require_aware(self.period_end_at, "period_end_at")
    _require_aware(self.current_time, "current_time")
    _require_aware(self.upcoming_end_at, "upcoming_end_at")
    _require_aware(self.tracking_started_at, "tracking_started_at")
    if not (
      self.recent_start_at
      <= self.period_end_at
      <= self.current_time
      < self.upcoming_end_at
    ):
      raise ValueError("focus review result times must be ordered")
    if self.tracking_started_at > self.current_time:
      raise ValueError("tracking_started_at must not be in the future")
    if len(self.suggested_events) not in {
      0,
      LEGACY_REVIEW_SUGGESTION_COUNT,
      REQUIRED_REVIEW_SUGGESTION_COUNT,
    }:
      raise ValueError(
        "suggested events must contain exactly five or seven or be empty"
      )
    return self


class AgentTurnResponse(StrictModel):
  """Safe API response with no executable side effects."""

  request_id: UUID
  message: str
  proposals: list[CalendarProposal] = Field(max_length=5)
  check_in_question: str | None
  warnings: list[str]
  provider: str
  model: str
  focus_review: FocusReviewResult | None = None


class HealthResponse(StrictModel):
  """Liveness response."""

  status: Literal["ok"] = "ok"
  service: Literal["calendar-agent"] = "calendar-agent"


class BackendStatusResponse(HealthResponse):
  """Authenticated non-sensitive hosted-backend capabilities."""

  provider: Literal["openai"] = "openai"
  model: str = Field(min_length=1, max_length=80)
  byok_enabled: bool
  audit_persistence_enabled: bool


def _require_aware(value: datetime, field_name: str) -> datetime:
  """Return an aware datetime or raise a validation error."""

  if value.tzinfo is None or value.utcoffset() is None:
    raise ValueError(f"{field_name} must include a timezone offset")
  return value


def _validate_review_period_bounds(
  period: FocusReviewPeriod,
  start: datetime,
  end: datetime,
  current_time: datetime,
  timezone_name: str,
  week_starts_on: int,
) -> None:
  """Validate Today, immediately previous week, or previous month bounds."""

  try:
    timezone = ZoneInfo(timezone_name)
  except (ZoneInfoNotFoundError, ValueError) as error:
    raise ValueError("focus review timezone is invalid") from error

  local_start = start.astimezone(timezone)
  local_end = end.astimezone(timezone)
  local_current = current_time.astimezone(timezone)
  if local_start.time().replace(tzinfo=None) != time.min:
    raise ValueError("focus review start must use local midnight")

  start_date = local_start.date()
  end_date = local_end.date()
  if period == FocusReviewPeriod.DAY:
    valid = start_date == local_current.date() and end == current_time
  elif period == FocusReviewPeriod.WEEK:
    if local_end.time().replace(tzinfo=None) != time.min:
      raise ValueError("completed review periods must end at local midnight")
    python_week_start = (week_starts_on + 5) % 7
    days_since_week_start = (
      local_current.date().weekday() - python_week_start
    ) % 7
    current_week_start = local_current.date() - timedelta(
      days=days_since_week_start
    )
    expected_start = current_week_start - timedelta(days=7)
    valid = start_date == expected_start and end_date == current_week_start
  else:
    if local_end.time().replace(tzinfo=None) != time.min:
      raise ValueError("completed review periods must end at local midnight")
    current_month_start = local_current.date().replace(day=1)
    previous_month_last = current_month_start - timedelta(days=1)
    previous_month_start = previous_month_last.replace(day=1)
    valid = (
      start_date == previous_month_start and end_date == current_month_start
    )
  if not valid:
    label = {
      FocusReviewPeriod.DAY: "current local day through current_time",
      FocusReviewPeriod.WEEK: "immediately previous completed local week",
      FocusReviewPeriod.MONTH: "immediately previous completed local month",
    }[period]
    raise ValueError(f"focus review bounds do not match {label}")


def _validate_missed_pattern_bounds(
  context: MissedPatternContext,
  current_time: datetime,
  tracking_started_at: datetime,
  timezone_name: str,
  week_starts_on: int,
) -> None:
  """Validate the UI's rolling-day or completed-period aggregation bounds."""

  if context.source_review_period != FocusReviewPeriod.DAY:
    _validate_review_period_bounds(
      context.source_review_period,
      context.window_start_at,
      context.window_end_at,
      current_time,
      timezone_name,
      week_starts_on,
    )
  else:
    try:
      timezone = ZoneInfo(timezone_name)
    except (ZoneInfoNotFoundError, ValueError) as error:
      raise ValueError("missed pattern timezone is invalid") from error

    local_current = current_time.astimezone(timezone)
    local_start = context.window_start_at.astimezone(timezone)
    if local_start.time().replace(tzinfo=None) != time.min:
      raise ValueError(
        "rolling seven-day missed pattern must start at midnight"
      )
    expected_start_date = local_current.date() - timedelta(days=6)
    if (
      local_start.date() != expected_start_date
      or context.window_end_at != current_time
    ):
      raise ValueError(
        "missed pattern bounds must match the rolling seven-day window"
      )

  if tracking_started_at <= context.window_start_at:
    expected_coverage = MissedPatternTrackingCoverage.FULL
  elif tracking_started_at >= context.window_end_at:
    expected_coverage = MissedPatternTrackingCoverage.NONE
  else:
    expected_coverage = MissedPatternTrackingCoverage.PARTIAL
  if context.tracking_coverage != expected_coverage:
    raise ValueError("missed pattern tracking coverage does not match bounds")
  if (
    expected_coverage == MissedPatternTrackingCoverage.FULL
    and context.covered_evaluated_event_count != context.evaluated_event_count
  ):
    raise ValueError("full tracking coverage must cover every evaluated event")
  if (
    expected_coverage == MissedPatternTrackingCoverage.NONE
    and context.covered_evaluated_event_count != 0
  ):
    raise ValueError("no tracking coverage cannot cover evaluated events")


def _reject_unsupported_review_claims(value: str) -> str:
  """Reject claims that cannot be established by calendar presence."""

  lowered = value.casefold()
  unsupported_claims = (
    "you completed",
    "you finished",
    "you attended",
    "you skipped",
    "you failed",
    "you succeeded",
    "you achieved",
    "you did not",
    "you didn't",
    "you weren't",
    "you were not",
    "you mastered this",
    "you have depression",
    "you are depressed",
    "you have anxiety",
    "you are anxious",
    "cure your",
    "treat your",
  )
  outcome_verb = re.search(
    r"\b(?:completed|finished|attended|skipped|failed|succeeded|achieved|"
    r"done|did|performed|practiced|trained|exercised|studied|mastered|"
    r"worked)\b",
    lowered,
  )
  if outcome_verb or any(claim in lowered for claim in unsupported_claims):
    raise ValueError("focus review text contains an unsupported outcome claim")
  return value
