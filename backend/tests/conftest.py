"""Shared deterministic fixtures."""

from collections.abc import Callable
from datetime import UTC, datetime, time
from uuid import UUID

import pytest

from app.schemas.agent import (
  AgentTurnRequest,
  CalendarEventSnapshot,
  CalendarPreferences,
  FocusArea,
)


@pytest.fixture
def now() -> datetime:
  """Return a fixed absolute clock value."""

  return datetime(2026, 7, 16, 8, 0, tzinfo=UTC)


@pytest.fixture
def request_factory(
  now: datetime,
) -> Callable[..., AgentTurnRequest]:
  """Build a valid request with selective overrides."""

  def build(**overrides: object) -> AgentTurnRequest:
    values: dict[str, object] = {
      "device_id": UUID("11111111-1111-1111-1111-111111111111"),
      "message": "Plan a focused and sustainable day.",
      "calendar_action_requested": True,
      "review_suggestion_count": 7,
      "provider": "openai",
      "current_time": now,
      "tracking_started_at": datetime(2026, 7, 1, 0, tzinfo=UTC),
      "planning_start": datetime(2026, 7, 16, 8, 30, tzinfo=UTC),
      "planning_end": datetime(2026, 7, 16, 22, 0, tzinfo=UTC),
      "preferences": CalendarPreferences(
        timezone="UTC",
        day_start=time(6, 0),
        morning_end=time(8, 0),
        evening_start=time(17, 30),
        day_end=time(23, 0),
        minimum_break_minutes=10,
        max_daily_blocks=5,
        selected_focus_areas=list(FocusArea),
      ),
      "calendar": [
        CalendarEventSnapshot(
          event_id="busy-1",
          calendar_id="calendar-1",
          start_at=datetime(2026, 7, 16, 20, 0, tzinfo=UTC),
          end_at=datetime(2026, 7, 16, 21, 0, tzinfo=UTC),
          focus_area=FocusArea.WORK,
        )
      ],
    }
    values.update(overrides)
    return AgentTurnRequest.model_validate(values)

  return build
