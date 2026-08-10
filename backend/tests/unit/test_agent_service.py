"""Agent orchestration tests."""

from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest
from pydantic import SecretStr

from app.core.config import Settings
from app.core.exceptions import InvalidPlanningRequestError
from app.core.llm.base import LLMProvider
from app.models.agent_turn_audit import AgentTurnAudit
from app.schemas.agent import (
  AgentTurnRequest,
  CompletionStatus,
  EvidenceConfidence,
  FocusArea,
  FocusEventSuggestion,
  FocusReviewPeriod,
  FocusSuggestionAction,
  HistoryCoverage,
  LLMCalendarProposal,
  LLMFocusAreaReview,
  LLMFocusReview,
  LLMTurn,
  ScheduleVisibility,
)
from app.services.agent_service import AgentService, _title_focus_areas
from app.services.prompt_builder import PromptBuilder


class FakeProvider:
  """Deterministic provider."""

  def __init__(self, result: LLMTurn) -> None:
    self._result = result
    self.system_prompt = ""
    self.user_prompt = ""
    self.closed = False

  @property
  def model(self) -> str:
    """Return a deterministic model ID."""

    return "model-test"

  async def generate_turn(
    self,
    system_prompt: str,
    user_prompt: str,
  ) -> LLMTurn:
    """Capture prompts and return the fixture."""

    self.system_prompt = system_prompt
    self.user_prompt = user_prompt
    return self._result

  async def close(self) -> None:
    """Record request-scoped transport cleanup."""

    self.closed = True


@pytest.mark.parametrize(
  ("title", "expected"),
  [
    ("Project work", FocusArea.WORK),
    ("Study session", FocusArea.STUDY),
    ("Morning exercise", FocusArea.EXERCISE),
    ("Dentist appointment", FocusArea.APPOINTMENTS),
    ("Grocery run", FocusArea.ERRANDS),
  ],
)
def test_neutral_title_classifier(title: str, expected: FocusArea) -> None:
  """Each public category has a conservative deterministic title signal."""

  assert _title_focus_areas(title) == {expected}


class FakeFactory:
  """Capture provider selection arguments."""

  def __init__(self, provider: LLMProvider) -> None:
    self.provider = provider
    self.arguments: tuple[str, str | None, str | None] | None = None

  def create(
    self,
    provider_name: str,
    requested_model: str | None,
    api_key_override: str | None,
  ) -> LLMProvider:
    """Return the injected provider."""

    self.arguments = (
      provider_name,
      requested_model,
      api_key_override,
    )
    return self.provider


class FakeAuditWriter:
  """Capture aggregate metadata without a database."""

  def __init__(self, fail: bool = False) -> None:
    self.fail = fail
    self.values: dict[str, Any] | None = None

  async def create(self, **values: Any) -> AgentTurnAudit:
    """Store arguments or simulate an unavailable audit database."""

    if self.fail:
      raise RuntimeError("database unavailable")
    self.values = values
    return AgentTurnAudit(**values)


def provider_turn() -> LLMTurn:
  """Return one safe and one conflicting proposal."""

  return LLMTurn(
    message="Choose one clear win.",
    proposals=[
      LLMCalendarProposal(
        title="Project work",
        start_at=datetime(2026, 7, 16, 18, tzinfo=UTC),
        end_at=datetime(2026, 7, 16, 19, tzinfo=UTC),
        focus_area=FocusArea.WORK,
        rationale="Move the project forward.",
        notes="Define the next result.",
        reminder_minutes=10,
      ),
      LLMCalendarProposal(
        title="Conflict",
        start_at=datetime(2026, 7, 16, 20, tzinfo=UTC),
        end_at=datetime(2026, 7, 16, 21, tzinfo=UTC),
        focus_area=FocusArea.WORK,
        rationale="This should be filtered.",
        notes="",
        reminder_minutes=0,
      ),
    ],
    check_in_question="What will done look like?",
  )


def focus_suggestion(
  focus_area: FocusArea,
  start: datetime,
  end: datetime,
  *,
  title: str = "Protected interest block",
) -> FocusEventSuggestion:
  """Build typed read-only calendar advice."""

  return FocusEventSuggestion(
    focus_area=focus_area,
    title=title,
    suggested_start_at=start,
    suggested_end_at=end,
    rationale="May restore visible planned time for this interest.",
    confidence=EvidenceConfidence.HIGH,
    action=FocusSuggestionAction.REQUIRES_EXPLICIT_SCHEDULING,
  )


def provider_focus_review(
  *,
  focus_areas: list[FocusArea] | None = None,
  suggestions: list[FocusEventSuggestion] | None = None,
) -> LLMFocusReview:
  """Return a complete, honest provider review fixture."""

  selected = list(FocusArea) if focus_areas is None else focus_areas
  return LLMFocusReview(
    areas=[
      LLMFocusAreaReview(
        focus_area=area,
        recent_visibility=ScheduleVisibility.NOT_VISIBLE,
        upcoming_visibility=ScheduleVisibility.NOT_VISIBLE,
        scheduled_evidence="No matching scheduled event is visible.",
        likely_impact="May slow this goal if the pattern continues.",
        confidence=EvidenceConfidence.HIGH,
      )
      for area in selected
    ],
    next_adjustment="Protect one small block for the least visible goal.",
    suggested_events=[] if suggestions is None else suggestions,
  )


def provider_review_turn(
  *,
  proposals: bool = True,
  review: LLMFocusReview | None = None,
) -> LLMTurn:
  """Return a provider turn containing the typed interest review."""

  base = provider_turn()
  return base.model_copy(
    update={
      "proposals": base.proposals if proposals else [],
      "focus_review": provider_focus_review() if review is None else review,
    }
  )


@pytest.mark.asyncio
async def test_service_orchestrates_provider_policy_and_audit(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Only validated proposals and aggregate metadata leave the service."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("System rules", encoding="utf-8")
  provider = FakeProvider(provider_turn())
  factory = FakeFactory(provider)
  audit = FakeAuditWriter()
  service = AgentService(
    settings=Settings(),
    provider_factory=factory,
    audit_writer=audit,
    prompt_builder=PromptBuilder(prompt_path),
  )

  response = await service.create_turn(
    request_factory(model="requested-model"),
    api_key_override="runtime-key",
  )

  assert response.message == "Choose one clear win."
  assert len(response.proposals) == 1
  assert response.model == "model-test"
  assert response.provider == "openai"
  assert factory.arguments == (
    "openai",
    "requested-model",
    "runtime-key",
  )
  assert provider.system_prompt == "System rules"
  assert "CONTEXT_JSON" in provider.user_prompt
  assert provider.closed is True
  assert audit.values is not None
  assert audit.values["proposal_count"] == 1
  assert audit.values["rejected_count"] == 1
  assert "message" not in audit.values


@pytest.mark.asyncio
async def test_production_metadata_reports_actual_openai_route(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Client provider metadata cannot mislabel the fixed production route."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("System rules", encoding="utf-8")
  factory = FakeFactory(FakeProvider(provider_turn()))
  audit = FakeAuditWriter()
  service = AgentService(
    settings=Settings(
      environment="production",
      app_shared_secret=SecretStr("app-secret"),
      openai_api_key=SecretStr("server-openai-key"),
      openai_model="operator-model",
    ),
    provider_factory=factory,
    audit_writer=audit,
    prompt_builder=PromptBuilder(prompt_path),
  )

  response = await service.create_turn(
    request_factory(provider="gemini", model="client-model"),
    api_key_override=None,
  )

  assert response.provider == "openai"
  assert audit.values is not None
  assert audit.values["provider"] == "openai"


@pytest.mark.asyncio
async def test_audit_failure_does_not_discard_safe_plan(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
  caplog: pytest.LogCaptureFixture,
) -> None:
  """Operational metadata failure is non-fatal and content is not logged."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(FakeProvider(provider_turn())),
    audit_writer=FakeAuditWriter(fail=True),
    prompt_builder=PromptBuilder(prompt_path),
  )

  response = await service.create_turn(request_factory(), None)

  assert len(response.proposals) == 1
  assert "audit write failed" in caplog.text
  assert "Choose one clear win" not in caplog.text


@pytest.mark.asyncio
async def test_invalid_request_is_rejected_before_provider_call(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Invalid request-wide bounds never spend a model request."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  provider = FakeProvider(provider_turn())
  factory = FakeFactory(provider)
  service = AgentService(
    settings=Settings(),
    provider_factory=factory,
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  invalid = request_factory(
    preferences={
      "timezone": "Not/A_Real_Zone",
      "selected_focus_areas": ["work"],
    }
  )

  with pytest.raises(InvalidPlanningRequestError, match="timezone is invalid"):
    await service.create_turn(invalid, None)

  assert factory.arguments is None
  assert provider.closed is False


@pytest.mark.asyncio
async def test_non_calendar_chat_skips_scheduling_preflight(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Chat-only turns do not depend on otherwise-unused schedule context."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  provider = FakeProvider(provider_turn())
  factory = FakeFactory(provider)
  service = AgentService(
    settings=Settings(),
    provider_factory=factory,
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  chat_request = request_factory(
    calendar_action_requested=False,
    calendar=[],
    preferences={
      "timezone": "Not/A_Real_Zone",
      "selected_focus_areas": ["work"],
    },
  )

  response = await service.create_turn(chat_request, None)

  assert response.message == "Choose one clear win."
  assert response.proposals == []
  assert factory.arguments is not None
  assert provider.closed is True


@pytest.mark.asyncio
async def test_focus_review_never_authorizes_provider_proposals(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Review context can inform coaching but cannot authorize writes."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  provider = FakeProvider(provider_review_turn())
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(provider),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  review = request_factory(
    message="Review how my interests appear in Apple Calendar.",
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    tracking_started_at=datetime(2026, 6, 1, 0, tzinfo=UTC),
  )

  response = await service.create_turn(review, None)

  assert response.message == (
    "Here is your calendar review. Eligible ended unmarked events since "
    "tracking began are treated as 70% likely incomplete in coaching insights."
  )
  assert response.proposals == []
  assert response.focus_review is not None
  assert len(response.focus_review.areas) == 5
  assert response.focus_review.completion_evidence == "not_provided"
  assert response.focus_review.period == FocusReviewPeriod.MONTH
  assert response.focus_review.period_end_at == datetime(
    2026, 7, 1, 0, tzinfo=UTC
  )
  assert response.focus_review.history_coverage == HistoryCoverage.FULL
  assert response.focus_review.suggested_events == []
  assert response.check_in_question == (
    "Which past scheduled blocks did you actually follow through on?"
  )
  work = next(
    area
    for area in response.focus_review.areas
    if area.focus_area == FocusArea.WORK
  )
  assert work.upcoming_visibility == ScheduleVisibility.VISIBLE
  assert response.warnings == [
    "Unexpected calendar proposals were removed because this chat turn did "
    "not request scheduling."
  ]


@pytest.mark.asyncio
async def test_truncated_review_downgrades_absence_to_unclear(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A capped phone snapshot cannot become a false missing-area claim."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(
      FakeProvider(provider_review_turn(proposals=False))
    ),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    tracking_started_at=datetime(2026, 6, 1, 0, tzinfo=UTC),
    review_calendar_context_truncated=True,
  )

  response = await service.create_turn(review, None)

  assert response.focus_review is not None
  assert response.focus_review.context_truncated is True
  assert all(
    area.recent_visibility == ScheduleVisibility.UNCLEAR
    for area in response.focus_review.areas
  )
  assert all(
    area.upcoming_visibility
    in {ScheduleVisibility.VISIBLE, ScheduleVisibility.NOT_VISIBLE}
    for area in response.focus_review.areas
  )
  assert all(
    area.confidence == EvidenceConfidence.LOW
    for area in response.focus_review.areas
  )
  assert any(
    "absence is shown as unclear" in item for item in response.warnings
  )


@pytest.mark.asyncio
async def test_ambiguous_title_cannot_become_visible_calendar_evidence(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A vague user-created title fails closed regardless of model output."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(
      FakeProvider(provider_review_turn(proposals=False))
    ),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  ambiguous_event = (
    request_factory()
    .calendar[0]
    .model_copy(
      update={
        "focus_area": None,
        "title": "Project",
        "start_at": datetime(2026, 6, 16, 20, tzinfo=UTC),
        "end_at": datetime(2026, 6, 16, 21, tzinfo=UTC),
      }
    )
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    tracking_started_at=datetime(2026, 6, 1, 0, tzinfo=UTC),
    calendar=[],
    review_calendar=[ambiguous_event],
  )

  response = await service.create_turn(review, None)

  assert response.focus_review is not None
  assert all(
    area.recent_visibility == ScheduleVisibility.UNCLEAR
    for area in response.focus_review.areas
  )
  assert all(
    area.confidence == EvidenceConfidence.LOW
    for area in response.focus_review.areas
  )
  assert all(
    area.likely_impact.startswith("Unknown")
    for area in response.focus_review.areas
  )
  assert response.focus_review.next_adjustment.startswith("Confirm ambiguous")


@pytest.mark.asyncio
async def test_unrelated_titles_are_ignored_across_multiple_calendars(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Normal Apple Calendar events do not obscure every missing interest."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(
      FakeProvider(provider_review_turn(proposals=False))
    ),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  base_event = (
    request_factory()
    .calendar[0]
    .model_copy(
      update={
        "start_at": datetime(2026, 6, 16, 20, tzinfo=UTC),
        "end_at": datetime(2026, 6, 16, 21, tzinfo=UTC),
      }
    )
  )
  study_event = base_event.model_copy(
    update={
      "event_id": "study-event",
      "calendar_id": "calendar-2",
      "focus_area": None,
      "title": "Study session",
    }
  )
  unrelated_event = base_event.model_copy(
    update={
      "event_id": "meeting-event",
      "calendar_id": "calendar-3",
      "focus_area": None,
      "title": "Lunch break",
    }
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    tracking_started_at=datetime(2026, 6, 1, 0, tzinfo=UTC),
    calendar=[],
    review_calendar=[base_event, study_event, unrelated_event],
  )

  response = await service.create_turn(review, None)

  assert response.focus_review is not None
  visible = {
    area.focus_area
    for area in response.focus_review.areas
    if area.recent_visibility == ScheduleVisibility.VISIBLE
  }
  assert visible == {
    FocusArea.WORK,
    FocusArea.STUDY,
  }
  assert all(
    area.recent_visibility == ScheduleVisibility.NOT_VISIBLE
    for area in response.focus_review.areas
    if area.focus_area not in visible
  )


@pytest.mark.asyncio
async def test_review_returns_only_safe_selected_interest_suggestions(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Seven safe suggestions remain separate from executable proposals."""

  selected = [FocusArea.WORK, FocusArea.EXERCISE]
  suggestions = [
    focus_suggestion(
      FocusArea.EXERCISE,
      datetime(2026, 7, 16, 17, 30, tzinfo=UTC),
      datetime(2026, 7, 16, 18, tzinfo=UTC),
      title="Exercise session 1",
    ),
    focus_suggestion(
      FocusArea.WORK,
      datetime(2026, 7, 16, 18, 10, tzinfo=UTC),
      datetime(2026, 7, 16, 18, 40, tzinfo=UTC),
      title="Work block 2",
    ),
    focus_suggestion(
      FocusArea.EXERCISE,
      datetime(2026, 7, 16, 19, 40, tzinfo=UTC),
      datetime(2026, 7, 16, 20, 10, tzinfo=UTC),
      title="Exercise session 3",
    ),
    focus_suggestion(
      FocusArea.WORK,
      datetime(2026, 7, 16, 20, 20, tzinfo=UTC),
      datetime(2026, 7, 16, 20, 50, tzinfo=UTC),
      title="Work block 4",
    ),
    focus_suggestion(
      FocusArea.EXERCISE,
      datetime(2026, 7, 16, 21, tzinfo=UTC),
      datetime(2026, 7, 16, 21, 30, tzinfo=UTC),
      title="Exercise session 5",
    ),
    focus_suggestion(
      FocusArea.WORK,
      datetime(2026, 7, 17, 18, tzinfo=UTC),
      datetime(2026, 7, 17, 18, 30, tzinfo=UTC),
      title="Work block 6",
    ),
    focus_suggestion(
      FocusArea.EXERCISE,
      datetime(2026, 7, 18, 18, tzinfo=UTC),
      datetime(2026, 7, 18, 19, tzinfo=UTC),
      title="Exercise session 7",
    ),
  ]
  provider_review = provider_focus_review(
    focus_areas=selected,
    suggestions=suggestions,
  )
  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(
      FakeProvider(
        provider_review_turn(proposals=False, review=provider_review)
      )
    ),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    tracking_started_at=datetime(2026, 6, 1, 0, tzinfo=UTC),
    planning_end=datetime(2026, 7, 23, 0, tzinfo=UTC),
    calendar=[],
    preferences={
      "timezone": "UTC",
      "selected_focus_areas": selected,
    },
  )

  response = await service.create_turn(review, None)

  assert response.proposals == []
  assert response.focus_review is not None
  assert [area.focus_area for area in response.focus_review.areas] == selected
  assert [
    suggestion.title for suggestion in response.focus_review.suggested_events
  ] == [
    "Exercise session 1",
    "Work block 2",
    "Exercise session 3",
    "Work block 4",
    "Exercise session 5",
    "Work block 6",
    "Exercise session 7",
  ]
  assert all(
    suggestion.action == FocusSuggestionAction.REQUIRES_EXPLICIT_SCHEDULING
    for suggestion in response.focus_review.suggested_events
  )
  assert response.warnings == []


@pytest.mark.asyncio
async def test_partial_provider_suggestions_preserve_review(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A six-item model draft degrades safely instead of raising a 502."""

  selected = [FocusArea.WORK, FocusArea.EXERCISE]
  draft = focus_suggestion(
    FocusArea.WORK,
    datetime(2026, 7, 18, 6, tzinfo=UTC),
    datetime(2026, 7, 18, 7, tzinfo=UTC),
  )
  provider = FakeProvider(
    provider_review_turn(
      proposals=False,
      review=provider_focus_review(
        focus_areas=selected,
        suggestions=[draft] * 6,
      ),
    )
  )
  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(provider),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  request = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, tzinfo=UTC),
    planning_start=datetime(2026, 7, 18, 6, tzinfo=UTC),
    planning_end=datetime(2026, 7, 25, 0, tzinfo=UTC),
    calendar=[],
    review_calendar=[],
    preferences={
      "timezone": "UTC",
      "selected_focus_areas": selected,
    },
  )

  response = await service.create_turn(request, None)

  assert response.focus_review is not None
  assert response.focus_review.suggested_events == []
  assert response.warnings == [
    "All seven suggestions were withheld because one or more could not be "
    "scheduled safely."
  ]
  assert provider.closed is True


@pytest.mark.asyncio
async def test_clear_title_keyword_is_bounded_medium_confidence_evidence(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A clear title can classify one area without making all areas visible."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(
      FakeProvider(provider_review_turn(proposals=False))
    ),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  titled_event = (
    request_factory()
    .calendar[0]
    .model_copy(
      update={
        "focus_area": None,
        "title": "Study session",
        "start_at": datetime(2026, 6, 16, 20, tzinfo=UTC),
        "end_at": datetime(2026, 6, 16, 21, tzinfo=UTC),
      }
    )
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    tracking_started_at=datetime(2026, 6, 1, 0, tzinfo=UTC),
    calendar=[],
    review_calendar=[titled_event],
  )

  response = await service.create_turn(review, None)

  assert response.focus_review is not None
  study = next(
    area
    for area in response.focus_review.areas
    if area.focus_area == FocusArea.STUDY
  )
  assert study.recent_visibility == ScheduleVisibility.VISIBLE
  assert study.confidence == EvidenceConfidence.MEDIUM
  assert all(
    area.recent_visibility == ScheduleVisibility.NOT_VISIBLE
    for area in response.focus_review.areas
    if area.focus_area != FocusArea.STUDY
  )


@pytest.mark.asyncio
async def test_review_validates_future_suggestion_horizon(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A review validates the horizon used by its future suggestions."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(planning_horizon_days=1),
    provider_factory=FakeFactory(
      FakeProvider(provider_review_turn(proposals=False))
    ),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, 0, tzinfo=UTC),
    planning_end=datetime(2026, 7, 18, 22, tzinfo=UTC),
  )

  with pytest.raises(InvalidPlanningRequestError, match="horizon"):
    await service.create_turn(review, None)


@pytest.mark.asyncio
async def test_review_reports_user_completion_and_partial_history(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Explicit follow-through survives without inventing unknown outcomes."""

  event = (
    request_factory()
    .calendar[0]
    .model_copy(
      update={
        "start_at": datetime(2026, 6, 20, 18, tzinfo=UTC),
        "end_at": datetime(2026, 6, 20, 19, tzinfo=UTC),
        "completion_status": CompletionStatus.COMPLETE,
      }
    )
  )
  provider_review = provider_focus_review(focus_areas=[FocusArea.WORK])
  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(
      FakeProvider(
        provider_review_turn(proposals=False, review=provider_review)
      )
    ),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, tzinfo=UTC),
    tracking_started_at=datetime(2026, 6, 15, tzinfo=UTC),
    calendar=[],
    review_calendar=[event],
    preferences={
      "timezone": "UTC",
      "selected_focus_areas": [FocusArea.WORK],
    },
  )

  response = await service.create_turn(review, None)

  assert response.focus_review is not None
  assert response.focus_review.history_coverage == HistoryCoverage.PARTIAL
  assert response.focus_review.completion_evidence == "user_input"
  assert response.focus_review.areas[0].recent_visibility == (
    ScheduleVisibility.VISIBLE
  )
  assert response.focus_review.areas[0].scheduled_evidence.startswith(
    "Tracking covers only part of this period."
  )
  assert "1 user-marked complete, 0 user-marked incomplete" in (
    response.focus_review.areas[0].scheduled_evidence
  )
  assert response.warnings == []


@pytest.mark.asyncio
async def test_review_weights_unmarked_elapsed_events_at_seventy_percent(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Review evidence is strict without presenting an estimate as a tap."""

  base_event = request_factory().calendar[0]
  unmarked = base_event.model_copy(
    update={
      "start_at": datetime(2026, 7, 16, 4, tzinfo=UTC),
      "end_at": datetime(2026, 7, 16, 5, tzinfo=UTC),
      "completion_status": None,
    }
  )
  complete = base_event.model_copy(
    update={
      "start_at": datetime(2026, 7, 16, 5, tzinfo=UTC),
      "end_at": datetime(2026, 7, 16, 6, tzinfo=UTC),
      "completion_status": CompletionStatus.COMPLETE,
    }
  )
  incomplete = base_event.model_copy(
    update={
      "start_at": datetime(2026, 7, 16, 6, tzinfo=UTC),
      "end_at": datetime(2026, 7, 16, 7, tzinfo=UTC),
      "completion_status": CompletionStatus.INCOMPLETE,
    }
  )
  ongoing = base_event.model_copy(
    update={
      "start_at": datetime(2026, 7, 16, 7, 30, tzinfo=UTC),
      "end_at": datetime(2026, 7, 16, 8, 30, tzinfo=UTC),
      "completion_status": None,
    }
  )
  provider_review = provider_focus_review(focus_areas=[FocusArea.WORK])
  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  provider = FakeProvider(
    provider_review_turn(proposals=False, review=provider_review)
  )
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(provider),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.DAY,
    focus_review_start=datetime(2026, 7, 16, 0, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 16, 8, tzinfo=UTC),
    tracking_started_at=datetime(2026, 7, 1, tzinfo=UTC),
    calendar=[],
    review_calendar=[unmarked, complete, incomplete, ongoing],
    preferences={
      "timezone": "UTC",
      "selected_focus_areas": [FocusArea.WORK],
    },
  )

  response = await service.create_turn(review, None)

  assert response.focus_review is not None
  evidence = response.focus_review.areas[0].scheduled_evidence
  assert (
    "1 user-marked complete, 1 user-marked incomplete, 1 unmarked ended"
    in evidence
  )
  assert "70% likely incomplete" in evidence
  assert "estimated incomplete weight 1.7" in evidence
  assert response.focus_review.completion_evidence == "user_input"
  assert "70% likely incomplete" in response.message
  assert '"completion_evidence_basis":"excluded_not_ended"' in (
    provider.user_prompt
  )


@pytest.mark.asyncio
async def test_review_before_tracking_keeps_empty_history_unclear(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """An empty pre-install month cannot become a discipline failure claim."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(
      FakeProvider(provider_review_turn(proposals=False))
    ),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  review = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.MONTH,
    focus_review_start=datetime(2026, 6, 1, tzinfo=UTC),
    focus_review_end=datetime(2026, 7, 1, tzinfo=UTC),
    tracking_started_at=datetime(2026, 7, 1, tzinfo=UTC),
    calendar=[],
    review_calendar=[],
  )

  response = await service.create_turn(review, None)

  assert response.focus_review is not None
  assert response.focus_review.history_coverage == (
    HistoryCoverage.BEFORE_TRACKING
  )
  assert all(
    area.recent_visibility == ScheduleVisibility.UNCLEAR
    for area in response.focus_review.areas
  )
  assert all(
    area.scheduled_evidence.startswith("This period is before tracking began.")
    for area in response.focus_review.areas
  )
  assert response.warnings == []


@pytest.mark.asyncio
async def test_non_review_discards_unexpected_structured_review(
  tmp_path: Path,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """Provider output cannot create a review without trusted review intent."""

  prompt_path = tmp_path / "prompt.md"
  prompt_path.write_text("Rules", encoding="utf-8")
  service = AgentService(
    settings=Settings(),
    provider_factory=FakeFactory(
      FakeProvider(provider_review_turn(proposals=False))
    ),
    audit_writer=FakeAuditWriter(),
    prompt_builder=PromptBuilder(prompt_path),
  )
  chat = request_factory(
    calendar_action_requested=False,
    calendar=[],
  )

  response = await service.create_turn(chat, None)

  assert response.focus_review is None
  assert response.warnings == [
    "An unexpected interest review was removed because this turn did not "
    "request one."
  ]
