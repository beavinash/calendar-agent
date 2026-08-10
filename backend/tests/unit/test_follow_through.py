"""Deterministic completion-likelihood tests."""

from datetime import UTC, datetime, timedelta

import pytest

from app.schemas.agent import CalendarEventSnapshot, CompletionStatus
from app.services.follow_through import (
  UNMARKED_INCOMPLETE_PROBABILITY,
  CompletionEvidenceBasis,
  estimate_follow_through,
)


def event_ending_at(
  end_at: datetime,
  *,
  status: CompletionStatus | None = None,
) -> CalendarEventSnapshot:
  """Build one event ending an hour after it starts."""

  return CalendarEventSnapshot(
    event_id="event-1",
    calendar_id="calendar-1",
    start_at=end_at - timedelta(hours=1),
    end_at=end_at,
    completion_status=status,
  )


@pytest.mark.parametrize(
  ("status", "probability", "basis"),
  [
    (
      CompletionStatus.COMPLETE,
      0.0,
      CompletionEvidenceBasis.EXPLICIT_COMPLETE,
    ),
    (
      None,
      0.7,
      CompletionEvidenceBasis.INFERRED_UNMARKED_ELAPSED,
    ),
    (
      CompletionStatus.INCOMPLETE,
      1.0,
      CompletionEvidenceBasis.EXPLICIT_INCOMPLETE,
    ),
  ],
)
def test_elapsed_event_uses_zero_seventy_or_one_hundred_percent(
  status: CompletionStatus | None,
  probability: float,
  basis: CompletionEvidenceBasis,
) -> None:
  """Elapsed events follow the configured strict coaching rule."""

  current_time = datetime(2026, 7, 23, 12, tzinfo=UTC)
  estimate = estimate_follow_through(
    event_ending_at(current_time, status=status),
    current_time,
    datetime(2026, 7, 1, tzinfo=UTC),
  )

  assert estimate.incomplete_probability == probability
  assert estimate.basis == basis
  assert UNMARKED_INCOMPLETE_PROBABILITY == 0.7


@pytest.mark.parametrize(
  "end_at",
  [
    datetime(2026, 7, 23, 12, 1, tzinfo=UTC),
    datetime(2026, 7, 24, 12, tzinfo=UTC),
  ],
)
def test_ongoing_or_future_event_is_excluded(
  end_at: datetime,
) -> None:
  """An event must end before it can become a likely miss."""

  estimate = estimate_follow_through(
    event_ending_at(end_at),
    datetime(2026, 7, 23, 12, tzinfo=UTC),
    datetime(2026, 7, 1, tzinfo=UTC),
  )

  assert estimate.incomplete_probability is None
  assert estimate.basis == CompletionEvidenceBasis.EXCLUDED_NOT_ENDED


@pytest.mark.parametrize(
  ("status", "probability", "basis"),
  [
    (
      CompletionStatus.COMPLETE,
      0.0,
      CompletionEvidenceBasis.EXPLICIT_COMPLETE,
    ),
    (
      CompletionStatus.INCOMPLETE,
      1.0,
      CompletionEvidenceBasis.EXPLICIT_INCOMPLETE,
    ),
  ],
)
def test_started_event_uses_explicit_status_before_scheduled_end(
  status: CompletionStatus,
  probability: float,
  basis: CompletionEvidenceBasis,
) -> None:
  """A deliberate tap remains authoritative when work finishes early."""

  current_time = datetime(2026, 7, 23, 12, tzinfo=UTC)
  event = CalendarEventSnapshot(
    event_id="event-1",
    calendar_id="calendar-1",
    start_at=current_time - timedelta(minutes=30),
    end_at=current_time + timedelta(minutes=30),
    completion_status=status,
  )

  estimate = estimate_follow_through(
    event,
    current_time,
    datetime(2026, 7, 1, tzinfo=UTC),
  )

  assert estimate.incomplete_probability == probability
  assert estimate.basis == basis


def test_future_event_is_excluded_even_if_it_has_an_explicit_status() -> None:
  """A status cannot make a not-yet-started calendar event historical."""

  current_time = datetime(2026, 7, 23, 12, tzinfo=UTC)
  event = CalendarEventSnapshot(
    event_id="event-1",
    calendar_id="calendar-1",
    start_at=current_time + timedelta(minutes=30),
    end_at=current_time + timedelta(minutes=60),
    completion_status=CompletionStatus.COMPLETE,
  )

  estimate = estimate_follow_through(
    event,
    current_time,
    datetime(2026, 7, 1, tzinfo=UTC),
  )

  assert estimate.incomplete_probability is None
  assert estimate.basis == CompletionEvidenceBasis.EXCLUDED_NOT_ENDED


def test_pre_tracking_unmarked_event_is_not_penalized() -> None:
  """The user cannot confirm events that ended before the app existed."""

  event = event_ending_at(datetime(2026, 6, 30, 12, tzinfo=UTC))
  estimate = estimate_follow_through(
    event,
    datetime(2026, 7, 23, 12, tzinfo=UTC),
    datetime(2026, 7, 1, tzinfo=UTC),
  )

  assert estimate.incomplete_probability is None
  assert estimate.basis == CompletionEvidenceBasis.EXCLUDED_BEFORE_TRACKING


def test_explicit_pre_tracking_status_remains_authoritative() -> None:
  """If explicit historical input exists, preserve it regardless of date."""

  event = event_ending_at(
    datetime(2026, 6, 30, 12, tzinfo=UTC),
    status=CompletionStatus.INCOMPLETE,
  )
  estimate = estimate_follow_through(
    event,
    datetime(2026, 7, 23, 12, tzinfo=UTC),
    datetime(2026, 7, 1, tzinfo=UTC),
  )

  assert estimate.incomplete_probability == 1.0
  assert estimate.basis == CompletionEvidenceBasis.EXPLICIT_INCOMPLETE
