"""Prompt composition tests."""

from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path

from app.schemas.agent import (
  AgentTurnRequest,
  CompletionStatus,
  FocusReviewPeriod,
  MissedPatternContext,
  MissedPatternGroup,
  MissedPatternTrackingCoverage,
)
from app.services.prompt_builder import PromptBuilder


def test_prompt_builder_separates_instructions_and_untrusted_context(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Device/provider identifiers stay out while useful context remains."""

  prompt_file = tmp_path / "prompt.md"
  prompt_file.write_text("  durable instructions  ", encoding="utf-8")
  request = request_factory()
  builder = PromptBuilder(prompt_file)

  assert builder.system_prompt == "durable instructions"
  user_prompt = builder.build_user_prompt(
    request,
    max_block_minutes=180,
    max_proposals=4,
  )
  assert request.message in user_prompt
  assert str(request.device_id) not in user_prompt
  assert request.calendar[0].event_id not in user_prompt
  assert request.calendar[0].calendar_id not in user_prompt
  assert '"focus_area":"work"' in user_prompt
  assert '"provider"' not in user_prompt
  assert "180 minutes" in user_prompt
  assert "Maximum ordinary calendar proposals in this response: 4" in (
    user_prompt
  )
  assert "Maximum agent blocks per local day: 5" in user_prompt
  assert "untrusted user data" in user_prompt
  assert '"morning_end":"08:00:00"' in user_prompt
  assert '"evening_start":"17:30:00"' in user_prompt
  assert '"weekend_start":"06:00:00"' in user_prompt
  assert '"weekend_end":"23:00:00"' in user_prompt
  assert '"breakfast_start":"07:45:00"' in user_prompt
  assert "exactly 7 safe review suggestions or none" in user_prompt


def test_system_prompt_allows_five_blocks_inside_split_windows() -> None:
  """Durable model instructions match the deterministic policy."""

  prompt = PromptBuilder().system_prompt

  assert "absolute writable schema maximum is five" in prompt
  assert "`day_start` through `morning_end`" in prompt
  assert "`calendar_action_requested` is true" in prompt
  assert "`weekend_start` through `weekend_end`" in prompt
  assert "protected meal window" in prompt


def test_system_prompt_keeps_focus_review_evidence_honest() -> None:
  """Focus Review instructions cannot equate scheduling with completion."""

  prompt = PromptBuilder().system_prompt

  assert "`focus_review_requested` is true" in prompt
  assert "scheduled evidence, not proof of completion" in prompt
  assert '"not visible or' in prompt
  assert "underrepresented in this calendar window" in prompt
  assert "likely impact" in prompt
  assert "review-only turn" in prompt
  assert "no scheduled evidence" in prompt
  assert "exactly one entry for each focus area" in prompt
  assert "`selected_focus_areas`" in prompt
  assert "`unclear` for ambiguous" in prompt
  assert "inference cannot have higher than medium confidence" in prompt
  assert "They are not Apple Calendar" in prompt
  assert "`requires_explicit_scheduling`" in prompt
  assert "`review_suggestion_count` safe `suggested_events`" in prompt
  assert "empty list instead of a partial batch" in prompt
  assert "`review_calendar` between" in prompt
  assert "`upcoming_visibility` from the future `calendar`" in prompt
  assert "one-click confirmation" in prompt
  assert "explicit user input" in prompt
  assert "70% likely incomplete" in prompt
  assert "likely missed" in prompt
  assert "leave an ongoing unmarked event" in prompt
  assert "preserve an explicit" in prompt
  assert "never present that inference as confirmed fact" in prompt
  assert "must not be double-counted" in prompt


def test_prompt_includes_bounded_missed_pattern_counts_without_identifiers(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """The model receives ranked aggregates and server-derived 70% weights."""

  context = MissedPatternContext(
    source_review_period=FocusReviewPeriod.DAY,
    window_start_at=datetime(2026, 7, 10, 0, tzinfo=UTC),
    window_end_at=datetime(2026, 7, 16, 8, tzinfo=UTC),
    tracking_coverage=MissedPatternTrackingCoverage.FULL,
    evaluated_event_count=5,
    covered_evaluated_event_count=5,
    missed_event_count=5,
    inferred_unmarked_count=4,
    explicit_incomplete_count=1,
    omitted_group_count=0,
    groups=[
      MissedPatternGroup(
        rank=1,
        display_title="Study session",
        missed_count=5,
        inferred_unmarked_count=4,
        explicit_incomplete_count=1,
      )
    ],
  )
  request = request_factory(
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
  prompt_file = tmp_path / "prompt.md"
  prompt_file.write_text("Rules", encoding="utf-8")

  user_prompt = PromptBuilder(prompt_file).build_user_prompt(
    request,
    max_block_minutes=180,
    max_proposals=5,
  )

  assert '"display_title":"Study session"' in user_prompt
  assert '"inferred_unmarked_count":4' in user_prompt
  assert '"explicit_incomplete_count":1' in user_prompt
  assert '"estimated_incomplete_weight":3.8' in user_prompt
  assert '"event_id"' not in user_prompt
  assert '"calendar_id"' not in user_prompt


def test_review_prompt_adds_deterministic_completion_likelihoods(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """The model sees explicit outcomes and the 70% unmarked estimate."""

  base_event = request_factory().calendar[0]
  unmarked = base_event.model_copy(
    update={
      "start_at": datetime(2026, 7, 16, 5, tzinfo=UTC),
      "end_at": datetime(2026, 7, 16, 6, tzinfo=UTC),
      "completion_status": None,
    }
  )
  complete = base_event.model_copy(
    update={
      "start_at": datetime(2026, 7, 16, 6, tzinfo=UTC),
      "end_at": datetime(2026, 7, 16, 7, tzinfo=UTC),
      "completion_status": CompletionStatus.COMPLETE,
    }
  )
  ongoing = base_event.model_copy(
    update={
      "start_at": datetime(2026, 7, 16, 7, 30, tzinfo=UTC),
      "end_at": datetime(2026, 7, 16, 8, 30, tzinfo=UTC),
      "completion_status": None,
    }
  )
  request = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.DAY,
    focus_review_start=datetime(2026, 7, 16, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 16, 8, tzinfo=UTC),
    calendar=[],
    review_calendar=[unmarked, complete, ongoing],
  )
  prompt_file = tmp_path / "prompt.md"
  prompt_file.write_text("Rules", encoding="utf-8")

  user_prompt = PromptBuilder(prompt_file).build_user_prompt(
    request,
    max_block_minutes=180,
    max_proposals=5,
  )

  assert '"estimated_incomplete_probability":0.7' in user_prompt
  assert '"estimated_incomplete_probability":0.0' in user_prompt
  assert '"completion_evidence_basis":"inferred_unmarked_elapsed"' in (
    user_prompt
  )
  assert '"completion_evidence_basis":"explicit_complete"' in user_prompt
  assert '"completion_evidence_basis":"excluded_not_ended"' in user_prompt
