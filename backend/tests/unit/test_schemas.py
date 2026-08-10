"""Schema contract tests."""

from collections.abc import Callable
from datetime import UTC, datetime, time, timedelta, timezone
from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.schemas.agent import (
  AgentTurnRequest,
  CalendarEventSnapshot,
  CalendarPreferences,
  CompletionStatus,
  EvidenceConfidence,
  FocusArea,
  FocusEventSuggestion,
  FocusReviewPeriod,
  FocusReviewResult,
  FocusSuggestionAction,
  HistoryCoverage,
  LLMFocusAreaReview,
  LLMFocusEventSuggestion,
  LLMFocusReview,
  MissedPatternContext,
  MissedPatternGroup,
  MissedPatternTrackingCoverage,
  NoteContext,
  ScheduleVisibility,
)


def test_focus_areas_are_neutral_public_defaults() -> None:
  """The public build must ship only generic calendar categories."""

  assert [area.value for area in FocusArea] == [
    "work",
    "study",
    "exercise",
    "appointments",
    "errands",
  ]


def missed_pattern_context() -> MissedPatternContext:
  """Build the rolling seven-day aggregate shown by Analyze Today."""

  return MissedPatternContext(
    source_review_period=FocusReviewPeriod.DAY,
    window_start_at=datetime(2026, 7, 10, 0, tzinfo=UTC),
    window_end_at=datetime(2026, 7, 16, 8, tzinfo=UTC),
    tracking_coverage=MissedPatternTrackingCoverage.FULL,
    evaluated_event_count=8,
    covered_evaluated_event_count=8,
    missed_event_count=6,
    inferred_unmarked_count=4,
    explicit_incomplete_count=2,
    omitted_group_count=0,
    groups=[
      MissedPatternGroup(
        rank=1,
        display_title="Study session",
        missed_count=4,
        inferred_unmarked_count=3,
        explicit_incomplete_count=1,
      ),
      MissedPatternGroup(
        rank=2,
        display_title="Grocery run",
        missed_count=2,
        inferred_unmarked_count=1,
        explicit_incomplete_count=1,
      ),
    ],
  )


def area_review(area: FocusArea) -> LLMFocusAreaReview:
  """Build one honest typed review entry."""

  return LLMFocusAreaReview(
    focus_area=area,
    recent_visibility=ScheduleVisibility.NOT_VISIBLE,
    upcoming_visibility=ScheduleVisibility.NOT_VISIBLE,
    scheduled_evidence="No matching scheduled event is visible.",
    likely_impact="May slow this goal if the pattern continues.",
    confidence=EvidenceConfidence.MEDIUM,
  )


def test_event_rejects_naive_or_reversed_times() -> None:
  """Calendar context must contain absolute positive intervals."""

  with pytest.raises(ValidationError, match="timezone"):
    CalendarEventSnapshot(
      event_id="event",
      calendar_id="calendar",
      start_at=datetime(2026, 1, 1, 10),
      end_at=datetime(2026, 1, 1, 11),
    )

  with pytest.raises(ValidationError, match="after"):
    CalendarEventSnapshot(
      event_id="event",
      calendar_id="calendar",
      start_at=datetime(2026, 1, 1, 11, tzinfo=UTC),
      end_at=datetime(2026, 1, 1, 10, tzinfo=UTC),
    )


def test_note_requires_absolute_created_at() -> None:
  """Note ordering must not depend on a guessed timezone."""

  with pytest.raises(ValidationError, match="timezone"):
    NoteContext(
      id=uuid4(),
      text="A useful note",
      created_at=datetime(2026, 1, 1, 10),
    )


def test_preferences_reject_invalid_day_and_duplicates() -> None:
  """Active hours and focus selections must be unambiguous."""

  with pytest.raises(ValidationError, match="day_end"):
    CalendarPreferences(
      timezone="UTC",
      day_start=time(23),
      day_end=time(6),
    )

  with pytest.raises(ValidationError, match="ordered"):
    CalendarPreferences(
      timezone="UTC",
      day_start=time(6),
      morning_end=time(18),
      evening_start=time(17, 30),
      day_end=time(23),
    )

  with pytest.raises(ValidationError, match="unique"):
    CalendarPreferences(
      timezone="UTC",
      selected_focus_areas=[FocusArea.WORK] * 2,
    )

  with pytest.raises(ValidationError, match="must not include an offset"):
    offset = timezone(timedelta(hours=5))
    CalendarPreferences(
      timezone="UTC",
      day_start=time(6, tzinfo=offset),
      day_end=time(23, tzinfo=offset),
    )


def test_preferences_default_to_requested_split_windows() -> None:
  """Planning defaults include weekday, weekend, and meal boundaries."""

  preferences = CalendarPreferences(timezone="UTC")

  assert preferences.day_start == time(6)
  assert preferences.morning_end == time(8)
  assert preferences.evening_start == time(17, 30)
  assert preferences.day_end == time(23)
  assert preferences.week_starts_on == 1
  assert preferences.weekend_start == time(6)
  assert preferences.weekend_end == time(23)
  assert preferences.breakfast_start == time(7, 45)
  assert preferences.breakfast_end == time(8, 15)
  assert preferences.lunch_start == time(11, 30)
  assert preferences.lunch_end == time(12)
  assert preferences.dinner_start == time(19)
  assert preferences.dinner_end == time(19, 30)
  assert preferences.max_daily_blocks == 5


@pytest.mark.parametrize(
  ("period", "start", "end"),
  [
    (
      FocusReviewPeriod.DAY,
      datetime(2026, 7, 16, 0, tzinfo=UTC),
      datetime(2026, 7, 16, 8, tzinfo=UTC),
    ),
    (
      FocusReviewPeriod.WEEK,
      datetime(2026, 7, 5, 0, tzinfo=UTC),
      datetime(2026, 7, 12, 0, tzinfo=UTC),
    ),
    (
      FocusReviewPeriod.MONTH,
      datetime(2026, 6, 1, 0, tzinfo=UTC),
      datetime(2026, 7, 1, 0, tzinfo=UTC),
    ),
  ],
)
def test_focus_review_requires_trusted_local_period_bounds(
  request_factory: Callable[..., AgentTurnRequest],
  period: FocusReviewPeriod,
  start: datetime,
  end: datetime,
) -> None:
  """Review bounds mean Today, last completed week, or last month."""

  review = request_factory(
    message="Review how my interests appear in Apple Calendar.",
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=period,
    focus_review_start=start,
    focus_review_end=end,
  )

  assert review.focus_review_requested is True
  assert review.focus_review_period == period
  assert review.focus_review_start == start
  assert review.focus_review_end == end

  with pytest.raises(ValidationError, match="period and bounds are required"):
    request_factory(
      calendar_action_requested=False,
      focus_review_requested=True,
    )

  with pytest.raises(ValidationError, match="current local day"):
    request_factory(
      calendar_action_requested=False,
      focus_review_requested=True,
      focus_review_period=FocusReviewPeriod.DAY,
      focus_review_start=datetime(2026, 7, 1, 0, tzinfo=UTC),
      focus_review_end=datetime(2026, 7, 1, 8, tzinfo=UTC),
    )

  with pytest.raises(ValidationError, match="cannot also schedule"):
    request_factory(
      focus_review_requested=True,
      focus_review_period=FocusReviewPeriod.MONTH,
      focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
      focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    )

  with pytest.raises(ValidationError, match="immediately previous"):
    request_factory(
      calendar_action_requested=False,
      focus_review_requested=True,
      focus_review_period=FocusReviewPeriod.WEEK,
      focus_review_start=datetime(2026, 7, 12, 0, tzinfo=UTC),
      focus_review_end=datetime(2026, 7, 19, 0, tzinfo=UTC),
      calendar=[],
    )

  with pytest.raises(ValidationError, match="future planning window"):
    request_factory(
      calendar_action_requested=False,
      focus_review_requested=True,
      focus_review_period=FocusReviewPeriod.DAY,
      focus_review_start=datetime(2026, 7, 16, 0, tzinfo=UTC),
      focus_review_end=datetime(2026, 7, 16, 8, tzinfo=UTC),
      planning_start=datetime(2026, 7, 16, 7, tzinfo=UTC),
      planning_end=datetime(2026, 7, 16, 7, 30, tzinfo=UTC),
      calendar=[],
    )


def test_focus_review_accepts_local_week_across_dst_fall_back(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A seven-local-day iPhone review survives the extra fall-back hour."""

  daylight = timezone(timedelta(hours=-7))
  standard = timezone(timedelta(hours=-8))
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.WEEK,
    current_time=datetime(2026, 11, 9, 12, tzinfo=standard),
    planning_start=datetime(2026, 11, 9, 13, tzinfo=standard),
    planning_end=datetime(2026, 11, 10, 22, tzinfo=standard),
    focus_review_start=datetime(2026, 11, 1, 0, tzinfo=daylight),
    focus_review_end=datetime(2026, 11, 8, 0, tzinfo=standard),
    calendar=[],
    preferences={
      "timezone": "America/Los_Angeles",
      "selected_focus_areas": list(FocusArea),
    },
  )

  assert review.focus_review_start is not None
  assert review.focus_review_end is not None
  assert review.focus_review_end - review.focus_review_start == timedelta(
    days=7,
    hours=1,
  )


def test_focus_review_uses_swift_calendar_week_start_numbering(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Swift's Monday value of two selects the prior Monday-to-Monday week."""

  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.WEEK,
    focus_review_start=datetime(2026, 7, 6, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 13, 0, tzinfo=UTC),
    calendar=[],
    preferences={
      "timezone": "UTC",
      "week_starts_on": 2,
      "selected_focus_areas": list(FocusArea),
    },
  )

  assert review.preferences.week_starts_on == 2


def test_missed_pattern_context_requires_explicit_intent_and_valid_counts(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Private aggregate titles cross only for an explicit interest review."""

  context = missed_pattern_context()
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.DAY,
    focus_review_start=datetime(2026, 7, 16, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 16, 8, tzinfo=UTC),
    planning_start=datetime(2026, 7, 17, 0, tzinfo=UTC),
    planning_end=datetime(2026, 7, 24, 0, tzinfo=UTC),
    calendar=[],
    missed_pattern_context=context,
  )
  assert review.missed_pattern_context == context

  with pytest.raises(ValidationError, match="focus review intent"):
    request_factory(missed_pattern_context=context)

  with pytest.raises(ValidationError, match="focus review intent"):
    request_factory(
      calendar_action_requested=False,
      calendar=[],
      missed_pattern_context=context,
    )

  invalid_payload = context.model_dump()
  invalid_payload["groups"][0]["missed_count"] = 99
  with pytest.raises(ValidationError, match="explicit plus inferred"):
    MissedPatternContext.model_validate(invalid_payload)


def test_missed_pattern_context_rejects_wrong_period_bounds(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Today summary means the exact rolling seven local calendar days."""

  context = missed_pattern_context()
  review_values: dict[str, object] = {
    "calendar_action_requested": False,
    "focus_review_requested": True,
    "focus_review_period": FocusReviewPeriod.DAY,
    "focus_review_start": datetime(2026, 7, 16, 0, tzinfo=UTC),
    "focus_review_end": datetime(2026, 7, 16, 8, tzinfo=UTC),
    "planning_start": datetime(2026, 7, 17, 0, tzinfo=UTC),
    "planning_end": datetime(2026, 7, 24, 0, tzinfo=UTC),
    "calendar": [],
  }
  with pytest.raises(ValidationError, match="rolling seven-day"):
    request_factory(
      **review_values,
      missed_pattern_context=context.model_copy(
        update={
          "window_start_at": datetime(2026, 7, 11, 0, tzinfo=UTC),
        }
      ),
    )

  with pytest.raises(ValidationError, match="source period"):
    request_factory(
      **review_values,
      missed_pattern_context=context.model_copy(
        update={"source_review_period": FocusReviewPeriod.WEEK}
      ),
    )


def test_missed_pattern_tracking_coverage_matches_first_use(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """The server verifies client coverage labels and covered-event counts."""

  review_values: dict[str, object] = {
    "calendar_action_requested": False,
    "focus_review_requested": True,
    "focus_review_period": FocusReviewPeriod.DAY,
    "focus_review_start": datetime(2026, 7, 16, 0, tzinfo=UTC),
    "focus_review_end": datetime(2026, 7, 16, 8, tzinfo=UTC),
    "planning_start": datetime(2026, 7, 17, 0, tzinfo=UTC),
    "planning_end": datetime(2026, 7, 24, 0, tzinfo=UTC),
    "calendar": [],
  }
  context = missed_pattern_context()
  with pytest.raises(ValidationError, match="tracking coverage"):
    request_factory(
      **review_values,
      missed_pattern_context=context.model_copy(
        update={"tracking_coverage": MissedPatternTrackingCoverage.PARTIAL}
      ),
    )
  with pytest.raises(ValidationError, match="cover every evaluated"):
    request_factory(
      **review_values,
      missed_pattern_context=context.model_copy(
        update={"covered_evaluated_event_count": 7}
      ),
    )


def test_focus_review_accepts_multiple_calendars_and_period_start(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Interest review spans Apple Calendar and may begin at local midnight."""

  first_event = (
    request_factory()
    .calendar[0]
    .model_copy(
      update={
        "start_at": datetime(2026, 7, 16, 6, tzinfo=UTC),
        "end_at": datetime(2026, 7, 16, 7, tzinfo=UTC),
      }
    )
  )
  second_event = first_event.model_copy(
    update={"event_id": "event-2", "calendar_id": "calendar-2"}
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.DAY,
    current_time=datetime(2026, 7, 16, 8, tzinfo=UTC),
    focus_review_start=datetime(2026, 7, 16, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 16, 8, tzinfo=UTC),
    calendar=[],
    review_calendar=[first_event, second_event],
  )

  assert {event.calendar_id for event in review.review_calendar} == {
    "calendar-1",
    "calendar-2",
  }


def test_review_fields_require_review_intent(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A period cannot smuggle calendar-review context into ordinary chat."""

  with pytest.raises(ValidationError, match="require review intent"):
    request_factory(
      calendar_action_requested=False,
      calendar=[],
      focus_review_period=FocusReviewPeriod.DAY,
    )


def test_calendar_titles_require_explicit_review_intent(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A buggy planning client cannot cross the review-only title boundary."""

  titled_event = (
    request_factory()
    .calendar[0]
    .model_copy(update={"title": "Private focus title"})
  )
  with pytest.raises(ValidationError, match="must not contain titles"):
    request_factory(calendar=[titled_event])

  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    calendar=[],
    review_calendar=[
      titled_event.model_copy(
        update={
          "start_at": datetime(2026, 6, 16, 20, tzinfo=UTC),
          "end_at": datetime(2026, 6, 16, 21, tzinfo=UTC),
        }
      )
    ],
  )

  assert review.review_calendar[0].title == "Private focus title"


def test_review_calendar_accepts_user_completion_status(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Only historical review events carry explicit completion check-ins."""

  event = (
    request_factory()
    .calendar[0]
    .model_copy(
      update={
        "start_at": datetime(2026, 6, 16, 20, tzinfo=UTC),
        "end_at": datetime(2026, 6, 16, 21, tzinfo=UTC),
        "completion_status": CompletionStatus.COMPLETE,
      }
    )
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    calendar=[],
    review_calendar=[event],
  )

  assert (
    review.review_calendar[0].completion_status == CompletionStatus.COMPLETE
  )

  with pytest.raises(ValidationError, match="future availability"):
    request_factory(
      calendar=[
        request_factory()
        .calendar[0]
        .model_copy(update={"completion_status": CompletionStatus.INCOMPLETE})
      ]
    )


def test_typed_focus_review_requires_five_honest_unique_areas() -> None:
  """Provider review output cannot omit areas or claim real-world outcomes."""

  review = LLMFocusReview(
    areas=[area_review(area) for area in FocusArea],
    next_adjustment="Protect one small block for the least visible goal.",
    suggested_events=[],
  )
  assert len(review.areas) == 5

  duplicates = [area_review(FocusArea.WORK) for _ in range(5)]
  with pytest.raises(ValidationError, match="areas must be unique"):
    LLMFocusReview(
      areas=duplicates,
      next_adjustment="Protect one small block.",
      suggested_events=[],
    )

  unconditional = area_review(FocusArea.WORK).model_dump()
  unconditional["likely_impact"] = "This proves the goal is progressing."
  with pytest.raises(ValidationError, match="conditional or unknown"):
    LLMFocusAreaReview.model_validate(unconditional)

  unsafe = area_review(FocusArea.WORK).model_dump()
  unsafe["likely_impact"] = "May prove you completed every planned block."
  with pytest.raises(ValidationError, match="unsupported outcome"):
    LLMFocusAreaReview.model_validate(unsafe)

  unsafe["likely_impact"] = "May mean all planned tasks were done."
  with pytest.raises(ValidationError, match="unsupported outcome"):
    LLMFocusAreaReview.model_validate(unsafe)

  with pytest.raises(ValidationError, match="unsupported outcome"):
    LLMFocusReview(
      areas=[area_review(area) for area in FocusArea],
      next_adjustment="Because you skipped exercise, add two sessions.",
      suggested_events=[],
    )


def test_focus_review_transport_accepts_bounded_untrusted_drafts() -> None:
  """Provider drafts may be partial before deterministic policy runs."""

  suggestion = FocusEventSuggestion(
    focus_area=FocusArea.EXERCISE,
    title="Weekend exercise session",
    suggested_start_at=datetime(2026, 7, 18, 9, tzinfo=UTC),
    suggested_end_at=datetime(2026, 7, 18, 10, tzinfo=UTC),
    rationale="May restore visible planned time for this interest.",
    confidence=EvidenceConfidence.HIGH,
    action=FocusSuggestionAction.REQUIRES_EXPLICIT_SCHEDULING,
  )

  complete = LLMFocusReview(
    areas=[area_review(FocusArea.EXERCISE)],
    next_adjustment="Protect the proposed blocks.",
    suggested_events=[
      suggestion.model_copy(
        update={"title": f"Weekend exercise session {index}"}
      )
      for index in range(7)
    ],
  )
  assert len(complete.suggested_events) == 7

  legacy = LLMFocusReview(
    areas=complete.areas,
    next_adjustment=complete.next_adjustment,
    suggested_events=complete.suggested_events[:5],
  )
  assert len(legacy.suggested_events) == 5

  partial = LLMFocusReview(
    areas=[area_review(FocusArea.EXERCISE)],
    next_adjustment="Protect the proposed block.",
    suggested_events=[suggestion] * 6,
  )
  assert len(partial.suggested_events) == 6


def test_trusted_focus_review_result_rejects_partial_batch() -> None:
  """Only complete legacy/current batches may cross the HTTP response."""

  suggestion = FocusEventSuggestion(
    focus_area=FocusArea.EXERCISE,
    title="Weekend exercise session",
    suggested_start_at=datetime(2026, 7, 18, 9, tzinfo=UTC),
    suggested_end_at=datetime(2026, 7, 18, 10, tzinfo=UTC),
    rationale="May restore visible planned time for this interest.",
    confidence=EvidenceConfidence.HIGH,
    action=FocusSuggestionAction.REQUIRES_EXPLICIT_SCHEDULING,
  )

  with pytest.raises(
    ValidationError, match="exactly five or seven or be empty"
  ):
    FocusReviewResult(
      areas=[area_review(FocusArea.EXERCISE)],
      next_adjustment="Protect the proposed block.",
      suggested_events=[suggestion],
      period=FocusReviewPeriod.DAY,
      recent_start_at=datetime(2026, 7, 18, 0, tzinfo=UTC),
      period_end_at=datetime(2026, 7, 18, 12, tzinfo=UTC),
      current_time=datetime(2026, 7, 18, 12, tzinfo=UTC),
      upcoming_end_at=datetime(2026, 7, 25, 0, tzinfo=UTC),
      tracking_started_at=datetime(2026, 7, 1, 0, tzinfo=UTC),
      history_coverage=HistoryCoverage.FULL,
      context_truncated=False,
    )


def test_provider_suggestion_draft_defers_semantic_validation() -> None:
  """One unsafe suggestion is withheld by policy, not provider parsing."""

  draft = LLMFocusEventSuggestion(
    focus_area=FocusArea.EXERCISE,
    title="Weekend exercise session",
    suggested_start_at=datetime(2026, 7, 18, 10, tzinfo=UTC),
    suggested_end_at=datetime(2026, 7, 18, 9, tzinfo=UTC),
    rationale="Because you skipped exercise, this proves completion.",
    confidence=EvidenceConfidence.HIGH,
    action=FocusSuggestionAction.REQUIRES_EXPLICIT_SCHEDULING,
  )

  assert draft.suggested_end_at < draft.suggested_start_at
  with pytest.raises(ValidationError):
    FocusEventSuggestion.model_validate(draft.model_dump())


def test_missing_review_count_defaults_to_legacy_five(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Backend-first rollout preserves the currently installed app contract."""

  payload = request_factory().model_dump()
  payload.pop("review_suggestion_count")

  request = AgentTurnRequest.model_validate(payload)

  assert request.review_suggestion_count == 5


def test_focus_event_suggestion_contract_requires_explicit_scheduling() -> None:
  """Review advice has no executable proposal ID and uses absolute times."""

  suggestion = FocusEventSuggestion(
    focus_area=FocusArea.EXERCISE,
    title="Evening exercise session",
    suggested_start_at=datetime(2026, 7, 16, 18, tzinfo=UTC),
    suggested_end_at=datetime(2026, 7, 16, 19, tzinfo=UTC),
    rationale="May restore visible planned time for this interest.",
    confidence=EvidenceConfidence.HIGH,
    action=FocusSuggestionAction.REQUIRES_EXPLICIT_SCHEDULING,
  )

  payload = suggestion.model_dump(mode="json")
  assert payload["action"] == "requires_explicit_scheduling"
  assert "proposal_id" not in payload

  with pytest.raises(ValidationError, match="timezone"):
    FocusEventSuggestion.model_validate(
      {
        **payload,
        "suggested_start_at": datetime(2026, 7, 16, 18),
      }
    )

  with pytest.raises(ValidationError, match="must be after"):
    FocusEventSuggestion.model_validate(
      {
        **payload,
        "suggested_end_at": suggestion.suggested_start_at,
      }
    )


def test_ordinary_chat_rejects_unrequested_calendar_context(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Calendar evidence is included only for planning or Focus Review."""

  with pytest.raises(ValidationError, match="calendar context requires"):
    request_factory(calendar_action_requested=False)


def test_turn_rejects_invalid_window_and_unknown_fields(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Turn contracts fail closed on temporal and contract drift."""

  request = request_factory()
  payload = request.model_dump()
  payload["planning_end"] = payload["planning_start"]
  with pytest.raises(ValidationError, match="after"):
    AgentTurnRequest.model_validate(payload)

  payload = request.model_dump()
  payload["planning_end"] = request.planning_start + timedelta(days=32)
  with pytest.raises(ValidationError, match="31 days"):
    AgentTurnRequest.model_validate(payload)

  payload = request.model_dump()
  payload["unexpected"] = "no"
  with pytest.raises(ValidationError, match="Extra inputs"):
    AgentTurnRequest.model_validate(payload)

  payload = request.model_dump()
  payload["tracking_started_at"] = datetime(2026, 7, 17, tzinfo=UTC)
  with pytest.raises(ValidationError, match="tracking_started_at"):
    AgentTurnRequest.model_validate(payload)

  payload = request.model_dump()
  payload["tracking_started_at"] = datetime(2026, 7, 1)
  with pytest.raises(ValidationError, match="timezone"):
    AgentTurnRequest.model_validate(payload)
