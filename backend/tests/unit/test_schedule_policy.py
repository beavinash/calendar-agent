"""Deterministic schedule policy tests."""

from collections.abc import Callable
from datetime import UTC, datetime

from app.core.config import Settings
from app.schemas.agent import (
  AgentTurnRequest,
  CalendarPreferences,
  EvidenceConfidence,
  FocusArea,
  FocusEventSuggestion,
  FocusReviewPeriod,
  FocusSuggestionAction,
  LLMCalendarProposal,
  LLMFocusEventSuggestion,
  LLMTurn,
)
from app.services.schedule_policy import SchedulePolicy


def proposal(
  start_hour: int,
  end_hour: int,
  *,
  start_minute: int = 0,
  end_minute: int = 0,
  day: int = 16,
  focus_area: FocusArea = FocusArea.WORK,
) -> LLMCalendarProposal:
  """Build a deterministic proposal."""

  return LLMCalendarProposal(
    title="Deep work",
    start_at=datetime(
      2026,
      7,
      day,
      start_hour,
      start_minute,
      tzinfo=UTC,
    ),
    end_at=datetime(
      2026,
      7,
      day,
      end_hour,
      end_minute,
      tzinfo=UTC,
    ),
    focus_area=focus_area,
    rationale="Protected focus time.",
    notes="One concrete outcome.",
    reminder_minutes=10,
  )


def turn(*proposals: LLMCalendarProposal) -> LLMTurn:
  """Build a provider response."""

  return LLMTurn(
    message="Keep the day realistic.",
    proposals=list(proposals),
    check_in_question=None,
  )


def review_suggestion(
  start_hour: int,
  end_hour: int,
  *,
  start_minute: int = 0,
  end_minute: int = 0,
  day: int = 18,
  index: int = 0,
) -> FocusEventSuggestion:
  """Build one read-only review suggestion."""

  return FocusEventSuggestion(
    focus_area=FocusArea.WORK,
    title=f"Project work {index}",
    suggested_start_at=datetime(
      2026,
      7,
      day,
      start_hour,
      start_minute,
      tzinfo=UTC,
    ),
    suggested_end_at=datetime(
      2026,
      7,
      day,
      end_hour,
      end_minute,
      tzinfo=UTC,
    ),
    rationale="May restore visible planned time for this interest.",
    confidence=EvidenceConfidence.HIGH,
    action=FocusSuggestionAction.REQUIRES_EXPLICIT_SCHEDULING,
  )


def review_request(
  request_factory: Callable[..., AgentTurnRequest],
  **overrides: object,
) -> AgentTurnRequest:
  """Build a last-month review with a future weekend planning horizon."""

  values: dict[str, object] = {
    "calendar_action_requested": False,
    "focus_review_requested": True,
    "review_suggestion_count": 7,
    "focus_review_period": FocusReviewPeriod.MONTH,
    "focus_review_start": datetime(2026, 6, 1, tzinfo=UTC),
    "focus_review_end": datetime(2026, 7, 1, tzinfo=UTC),
    "planning_start": datetime(2026, 7, 18, 6, tzinfo=UTC),
    "planning_end": datetime(2026, 7, 25, 0, tzinfo=UTC),
    "calendar": [],
    "review_calendar": [],
    "preferences": {
      "timezone": "UTC",
      "selected_focus_areas": [FocusArea.WORK],
    },
  }
  values.update(overrides)
  return request_factory(**values)


def test_accepts_safe_non_conflicting_evening_block(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A valid evening proposal reaches the calendar execution boundary."""

  result = SchedulePolicy(Settings()).validate(
    turn(proposal(18, 19)),
    request_factory(),
  )

  assert len(result.proposals) == 1
  assert result.proposals[0].title == "Deep work"
  assert result.warnings == []


def test_rejects_provider_proposals_without_trusted_calendar_intent(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A hallucinated proposal cannot become an automatic calendar write."""

  result = SchedulePolicy(Settings()).validate(
    turn(proposal(18, 19)),
    request_factory(calendar_action_requested=False, calendar=[]),
  )

  assert result.proposals == []
  assert result.warnings == [
    "Unexpected calendar proposals were removed because this chat turn did "
    "not request scheduling."
  ]


def test_accepts_exact_morning_and_evening_boundaries(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Weekday blocks may touch meal-safe morning and evening boundaries."""

  request = request_factory(
    current_time=datetime(2026, 7, 16, 5, tzinfo=UTC),
    planning_start=datetime(2026, 7, 16, 5, 30, tzinfo=UTC),
    calendar=[],
    preferences=CalendarPreferences(
      timezone="UTC",
      minimum_break_minutes=0,
      max_daily_blocks=5,
    ),
  )

  result = SchedulePolicy(Settings()).validate(
    turn(
      proposal(6, 7, start_minute=30, end_minute=45),
      proposal(17, 18, start_minute=30, end_minute=30),
    ),
    request,
  )

  assert len(result.proposals) == 2
  assert result.warnings == []
  assert result.warnings == []


def test_rejects_core_hours_and_window_crossings(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Every block must fit wholly inside one allowed scheduling window."""

  request = request_factory(
    current_time=datetime(2026, 7, 16, 5, tzinfo=UTC),
    planning_start=datetime(2026, 7, 16, 6, tzinfo=UTC),
    calendar=[],
  )
  result = SchedulePolicy(Settings()).validate(
    turn(
      proposal(7, 8, start_minute=30, end_minute=30),
      proposal(10, 11),
      proposal(17, 18),
    ),
    request,
  )

  assert result.proposals == []
  assert result.warnings == [
    "A proposed block outside the allowed scheduling windows was removed."
  ]


def test_removes_conflicts_and_overlapping_drafts(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Existing events and previously accepted drafts reserve buffered time."""

  result = SchedulePolicy(Settings()).validate(
    turn(proposal(20, 21), proposal(18, 19), proposal(18, 19)),
    request_factory(),
  )

  assert len(result.proposals) == 1
  assert "calendar" in result.warnings[0]
  assert any("Overlapping" in value for value in result.warnings)


def test_removes_past_window_duration_and_focus_violations(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Core proposal bounds do not depend on model prompt compliance."""

  request = request_factory(
    preferences=CalendarPreferences(
      timezone="UTC",
      selected_focus_areas=[FocusArea.WORK],
    )
  )
  proposals = [
    proposal(7, 8),
    LLMCalendarProposal(
      title="Too short",
      start_at=datetime(2026, 7, 16, 17, 30, tzinfo=UTC),
      end_at=datetime(2026, 7, 16, 17, 40, tzinfo=UTC),
      focus_area=FocusArea.WORK,
      rationale="Invalid",
      notes="",
      reminder_minutes=0,
    ),
    proposal(18, 22),
    proposal(21, 23),
    proposal(18, 19, focus_area=FocusArea.EXERCISE),
  ]

  result = SchedulePolicy(Settings(max_block_minutes=180)).validate(
    turn(*proposals),
    request,
  )

  assert result.proposals == []
  combined = " ".join(result.warnings)
  assert "past" in combined
  assert "short" in combined
  assert "long" in combined
  assert "planning window" in combined
  assert "disabled focus" in combined


def test_removes_naive_cross_day_and_outside_allowed_windows(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Local-day constraints remain deterministic across provider output."""

  naive = LLMCalendarProposal(
    title="Naive",
    start_at=datetime(2026, 7, 16, 18),
    end_at=datetime(2026, 7, 16, 19),
    focus_area=FocusArea.WORK,
    rationale="Invalid",
    notes="",
    reminder_minutes=0,
  )
  cross_day = LLMCalendarProposal(
    title="Cross day",
    start_at=datetime(2026, 7, 16, 22, tzinfo=UTC),
    end_at=datetime(2026, 7, 17, 1, tzinfo=UTC),
    focus_area=FocusArea.WORK,
    rationale="Invalid",
    notes="",
    reminder_minutes=0,
  )
  request = request_factory(
    planning_end=datetime(2026, 7, 17, 8, tzinfo=UTC),
  )

  result = SchedulePolicy(Settings()).validate(
    turn(naive, cross_day, proposal(10, 11)),
    request,
  )

  assert result.proposals == []
  combined = " ".join(result.warnings)
  assert "timezone" in combined
  assert "crossing" in combined
  assert "scheduling windows" in combined


def test_invalid_timezone_horizon_and_daily_limit(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Global constraints short-circuit or cap provider drafts safely."""

  invalid_zone = request_factory(
    preferences=CalendarPreferences(timezone="Not/A_Real_Zone")
  )
  result = SchedulePolicy(Settings()).validate(
    turn(proposal(18, 19)),
    invalid_zone,
  )
  assert result.proposals == []
  assert "timezone" in result.warnings[0]

  path_zone = request_factory(
    preferences=CalendarPreferences(timezone="/etc/passwd")
  )
  result = SchedulePolicy(Settings()).validate(
    turn(proposal(18, 19)),
    path_zone,
  )
  assert result.proposals == []
  assert "timezone" in result.warnings[0]

  long_window = request_factory(
    planning_end=datetime(2026, 7, 31, 8, tzinfo=UTC)
  )
  result = SchedulePolicy(Settings(planning_horizon_days=14)).validate(
    turn(proposal(18, 19)),
    long_window,
  )
  assert result.proposals == []
  assert "horizon" in result.warnings[0]

  request = request_factory(
    calendar=[],
    preferences=CalendarPreferences(
      timezone="UTC",
      minimum_break_minutes=0,
      max_daily_blocks=1,
    ),
  )
  result = SchedulePolicy(Settings()).validate(
    turn(proposal(18, 19), proposal(20, 21), proposal(21, 22)),
    request,
  )
  assert len(result.proposals) == 1
  assert result.warnings == [
    "Extra proposed blocks were removed by the daily limit."
  ]


def test_accepts_five_safe_blocks_when_daily_limit_is_five(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Five is a ceiling, and all five can pass when the day has room."""

  request = request_factory(
    current_time=datetime(2026, 7, 16, 5, tzinfo=UTC),
    planning_start=datetime(2026, 7, 16, 5, 30, tzinfo=UTC),
    calendar=[],
    preferences=CalendarPreferences(
      timezone="UTC",
      minimum_break_minutes=0,
      max_daily_blocks=5,
    ),
  )
  result = SchedulePolicy(Settings()).validate(
    turn(
      proposal(6, 6, end_minute=30),
      proposal(6, 7, start_minute=30),
      proposal(7, 7, end_minute=30),
      proposal(17, 18, start_minute=30),
      proposal(18, 18, end_minute=30),
    ),
    request,
  )

  assert len(result.proposals) == 5
  assert result.warnings == []


def test_response_limit_remains_independent_of_daily_limit(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """An operator response cap can be lower than the user's daily ceiling."""

  request = request_factory(
    calendar=[],
    preferences=CalendarPreferences(
      timezone="UTC",
      minimum_break_minutes=0,
      max_daily_blocks=5,
    ),
  )
  result = SchedulePolicy(Settings(max_proposals=2)).validate(
    turn(proposal(18, 19), proposal(20, 21), proposal(21, 22)),
    request,
  )

  assert len(result.proposals) == 2
  assert result.warnings == [
    "Extra proposed blocks were removed by the response limit."
  ]


def test_break_buffer_blocks_adjacent_event(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """The configured transition buffer protects event boundaries."""

  result = SchedulePolicy(Settings()).validate(
    turn(proposal(19, 19, start_minute=30, end_minute=55)),
    request_factory(),
  )
  assert result.proposals == []
  assert "conflicting" in result.warnings[0]


def test_daily_limit_is_enforced_per_local_date(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A two-day plan can include one block on each day."""

  request = request_factory(
    calendar=[],
    planning_end=datetime(2026, 7, 17, 22, tzinfo=UTC),
    preferences=CalendarPreferences(
      timezone="UTC",
      minimum_break_minutes=0,
      max_daily_blocks=1,
    ),
  )

  result = SchedulePolicy(Settings()).validate(
    turn(
      proposal(18, 19),
      proposal(20, 21),
      proposal(18, 19, day=17),
    ),
    request,
  )

  assert len(result.proposals) == 2
  assert result.proposals[1].start_at.day == 17
  assert result.warnings == [
    "Extra proposed blocks were removed by the daily limit."
  ]


def test_daily_limit_counts_existing_agent_blocks(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """An existing app-labelled block consumes the local daily ceiling."""

  request = request_factory(
    preferences=CalendarPreferences(
      timezone="UTC",
      minimum_break_minutes=0,
      max_daily_blocks=1,
    )
  )

  result = SchedulePolicy(Settings()).validate(
    turn(proposal(18, 19)),
    request,
  )

  assert result.proposals == []
  assert result.warnings == [
    "Extra proposed blocks were removed by the daily limit."
  ]


def test_split_windows_are_evaluated_in_configured_timezone(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """UTC instants are compared against Los Angeles wall-clock windows."""

  request = request_factory(
    current_time=datetime(2026, 7, 16, 16, tzinfo=UTC),
    planning_start=datetime(2026, 7, 16, 16, tzinfo=UTC),
    planning_end=datetime(2026, 7, 17, 4, tzinfo=UTC),
    calendar=[],
    preferences=CalendarPreferences(
      timezone="America/Los_Angeles",
      minimum_break_minutes=0,
    ),
  )
  local_midday = LLMCalendarProposal(
    title="Local midday",
    start_at=datetime(2026, 7, 16, 17, tzinfo=UTC),
    end_at=datetime(2026, 7, 16, 18, tzinfo=UTC),
    focus_area=FocusArea.WORK,
    rationale="Should be filtered.",
    notes="",
    reminder_minutes=0,
  )
  local_evening = LLMCalendarProposal(
    title="Local evening",
    start_at=datetime(2026, 7, 17, 0, 30, tzinfo=UTC),
    end_at=datetime(2026, 7, 17, 1, 30, tzinfo=UTC),
    focus_area=FocusArea.WORK,
    rationale="Fits the evening window.",
    notes="",
    reminder_minutes=0,
  )

  result = SchedulePolicy(Settings()).validate(
    turn(local_midday, local_evening),
    request,
  )

  assert [item.title for item in result.proposals] == ["Local evening"]
  assert "scheduling windows" in result.warnings[0]


def test_accepts_exactly_seven_safe_weekend_review_suggestions(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Weekend suggestions may use the full day when each is 60–120 minutes."""

  suggestions = [
    review_suggestion(6, 7, index=1),
    review_suggestion(8, 9, start_minute=15, end_minute=15, index=2),
    review_suggestion(10, 11, index=3),
    review_suggestion(12, 13, index=4),
    review_suggestion(14, 16, index=5),
    review_suggestion(6, 7, day=19, index=6),
    review_suggestion(9, 10, day=19, index=7),
  ]

  result = SchedulePolicy(Settings()).validate_review_suggestions(
    suggestions,
    review_request(request_factory),
  )

  assert len(result.suggestions) == 7
  assert result.warnings == []


def test_partial_provider_review_batch_is_withheld_all_or_zero(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A partial model draft preserves the review without unsafe actions."""

  suggestions = [
    review_suggestion(6, 7, index=1),
    review_suggestion(8, 9, start_minute=15, end_minute=15, index=2),
    review_suggestion(10, 11, index=3),
    review_suggestion(12, 13, index=4),
    review_suggestion(14, 16, index=5),
    review_suggestion(6, 7, day=19, index=6),
  ]

  result = SchedulePolicy(Settings()).validate_review_suggestions(
    suggestions,
    review_request(request_factory),
  )

  assert result.suggestions == []
  assert result.warnings == [
    "All seven suggestions were withheld because one or more could not be "
    "scheduled safely."
  ]


def test_semantically_invalid_provider_suggestion_withholds_batch(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Provider wording and interval drafts are revalidated by policy."""

  unsafe = LLMFocusEventSuggestion(
    focus_area=FocusArea.WORK,
    title="Unsafe work claim",
    suggested_start_at=datetime(2026, 7, 19, 9, tzinfo=UTC),
    suggested_end_at=datetime(2026, 7, 19, 10, tzinfo=UTC),
    rationale="Because you skipped this, it proves the work was completed.",
    confidence=EvidenceConfidence.HIGH,
    action=FocusSuggestionAction.REQUIRES_EXPLICIT_SCHEDULING,
  )
  safe = [
    review_suggestion(6, 7, index=1),
    review_suggestion(8, 9, start_minute=15, end_minute=15, index=2),
    review_suggestion(10, 11, index=3),
    review_suggestion(12, 13, index=4),
    review_suggestion(14, 16, index=5),
    review_suggestion(6, 7, day=19, index=6),
  ]

  result = SchedulePolicy(Settings()).validate_review_suggestions(
    [unsafe, *safe],
    review_request(request_factory),
  )

  assert result.suggestions == []
  assert result.warnings == [
    "All seven suggestions were withheld because one or more could not be "
    "scheduled safely."
  ]


def test_legacy_client_accepts_exactly_five_safe_review_suggestions(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """The absent capability's legacy value remains a safe five-item batch."""

  suggestions = [
    review_suggestion(6, 7, index=1),
    review_suggestion(9, 10, index=2),
    review_suggestion(12, 13, index=3),
    review_suggestion(14, 15, index=4),
    review_suggestion(16, 17, index=5),
  ]
  request = review_request(request_factory, review_suggestion_count=5)

  result = SchedulePolicy(Settings()).validate_review_suggestions(
    suggestions,
    request,
  )

  assert len(result.suggestions) == 5
  assert result.warnings == []


def test_review_suggestion_batch_is_removed_for_invalid_weekend_duration(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """One duration violation removes the complete one-click batch."""

  valid = [
    review_suggestion(6, 7, index=1),
    review_suggestion(9, 10, index=2),
    review_suggestion(12, 13, index=3),
    review_suggestion(14, 15, index=4),
    review_suggestion(16, 17, index=5),
    review_suggestion(6, 7, day=19, index=6),
  ]
  too_short = review_suggestion(9, 9, end_minute=59, day=19, index=7)
  too_long = review_suggestion(9, 11, end_minute=1, day=19, index=7)
  policy = SchedulePolicy(Settings())

  for invalid in (too_short, too_long):
    result = policy.validate_review_suggestions(
      [*valid, invalid],
      review_request(request_factory),
    )
    assert result.suggestions == []
    assert result.warnings == [
      "All seven suggestions were withheld because one or more could not be "
      "scheduled safely."
    ]


def test_review_suggestion_batch_avoids_meals_and_future_calendar(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Meal protection and freshly supplied future events fail the whole batch."""

  meal_suggestions = [
    review_suggestion(6, 7, index=1),
    review_suggestion(9, 10, index=2),
    review_suggestion(11, 12, start_minute=30, index=3),
    review_suggestion(14, 15, index=4),
    review_suggestion(16, 17, index=5),
  ]
  meal_result = SchedulePolicy(Settings()).validate_review_suggestions(
    meal_suggestions,
    review_request(request_factory),
  )
  assert meal_result.suggestions == []

  future_event = (
    request_factory()
    .calendar[0]
    .model_copy(
      update={
        "start_at": datetime(2026, 7, 18, 9, tzinfo=UTC),
        "end_at": datetime(2026, 7, 18, 10, tzinfo=UTC),
      }
    )
  )
  safe_times = [
    review_suggestion(6, 7, index=1),
    review_suggestion(9, 10, index=2),
    review_suggestion(12, 13, index=3),
    review_suggestion(14, 15, index=4),
    review_suggestion(16, 17, index=5),
  ]
  conflict_result = SchedulePolicy(Settings()).validate_review_suggestions(
    safe_times,
    review_request(request_factory, calendar=[future_event]),
  )
  assert conflict_result.suggestions == []


def test_weekday_proposals_keep_split_windows_and_protect_dinner(
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """The broader weekend window does not weaken weekday or meal boundaries."""

  result = SchedulePolicy(Settings()).validate(
    turn(proposal(12, 13), proposal(19, 20)),
    request_factory(calendar=[]),
  )

  assert result.proposals == []
  assert any("scheduling windows" in warning for warning in result.warnings)
  assert any("protected meal" in warning for warning in result.warnings)
