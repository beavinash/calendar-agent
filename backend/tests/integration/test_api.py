"""FastAPI contract and sanitized-error tests."""

import logging
from collections.abc import AsyncIterator, Callable
from datetime import UTC, datetime

import httpx
import pytest
from fastapi import FastAPI
from pydantic import SecretStr

from app.api.dependencies import get_agent_service
from app.core.config import Settings, get_settings
from app.core.exceptions import (
  BYOKNotAllowedError,
  LLMAuthenticationError,
  LLMConfigurationError,
  LLMProviderError,
)
from app.main import app
from app.schemas.agent import (
  AgentTurnRequest,
  AgentTurnResponse,
  EvidenceConfidence,
  FocusArea,
  FocusEventSuggestion,
  FocusReviewPeriod,
  FocusReviewResult,
  FocusSuggestionAction,
  HistoryCoverage,
  LLMFocusAreaReview,
  ScheduleVisibility,
)


class FakeService:
  """Endpoint service fake."""

  def __init__(
    self,
    response: AgentTurnResponse | None = None,
    error: Exception | None = None,
  ) -> None:
    self.response = response
    self.error = error
    self.received_key: str | None = None

  async def create_turn(
    self,
    request: AgentTurnRequest,
    api_key_override: str | None,
  ) -> AgentTurnResponse:
    """Capture the key boundary and return/raise the fixture."""

    del request
    self.received_key = api_key_override
    if self.error is not None:
      raise self.error
    assert self.response is not None
    return self.response


@pytest.fixture
async def client() -> AsyncIterator[httpx.AsyncClient]:
  """Yield an in-process HTTP client."""

  transport = httpx.ASGITransport(app=app)
  async with httpx.AsyncClient(
    transport=transport,
    base_url="http://test",
  ) as value:
    yield value
  app.dependency_overrides.clear()


def response_fixture() -> AgentTurnResponse:
  """Return a minimal successful turn."""

  from uuid import UUID

  return AgentTurnResponse(
    request_id=UUID("22222222-2222-2222-2222-222222222222"),
    message="Do one thing well.",
    proposals=[],
    check_in_question=None,
    warnings=[],
    provider="openai",
    model="gpt-test",
  )


def override_service(application: FastAPI, service: FakeService) -> None:
  """Install one typed service dependency override."""

  application.dependency_overrides[get_agent_service] = lambda: service


@pytest.mark.asyncio
async def test_health_and_request_id(client: httpx.AsyncClient) -> None:
  """Health is public and every response carries a correlation ID."""

  response = await client.get(
    "/api/v1/health",
    headers={"x-request-id": "test-request-id"},
  )

  assert response.status_code == 200
  assert response.json() == {
    "status": "ok",
    "service": "calendar-agent",
  }
  assert response.headers["x-request-id"] == "test-request-id"


@pytest.mark.asyncio
async def test_status_requires_app_secret_and_reports_capabilities(
  client: httpx.AsyncClient,
) -> None:
  """Status verifies authentication without accepting personal context."""

  settings = Settings(
    environment="production",
    app_shared_secret=SecretStr("expected-app-secret"),
    openai_api_key=SecretStr("server-openai-key"),
    openai_model="operator-model",
    audit_persistence_enabled=False,
  )
  app.dependency_overrides[get_settings] = lambda: settings

  missing = await client.get("/api/v1/status")
  incorrect = await client.get(
    "/api/v1/status",
    headers={"x-app-secret": "incorrect"},
  )
  authenticated = await client.get(
    "/api/v1/status",
    headers={"x-app-secret": "expected-app-secret"},
  )

  assert missing.status_code == 401
  assert incorrect.status_code == 401
  assert authenticated.status_code == 200
  assert authenticated.json() == {
    "status": "ok",
    "service": "calendar-agent",
    "provider": "openai",
    "model": "operator-model",
    "byok_enabled": False,
    "audit_persistence_enabled": False,
  }
  assert "server-openai-key" not in authenticated.text
  assert "expected-app-secret" not in authenticated.text


@pytest.mark.asyncio
async def test_turn_contract_and_byok_header(
  client: httpx.AsyncClient,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A valid request maps the sensitive header only into the service call."""

  service = FakeService(response=response_fixture())
  override_service(app, service)
  response = await client.post(
    "/api/v1/agent/turn",
    json=request_factory().model_dump(mode="json"),
    headers={"x-ai-api-key": "runtime-secret"},
  )

  assert response.status_code == 200
  assert response.json()["message"] == "Do one thing well."
  assert service.received_key == "runtime-secret"
  assert "runtime-secret" not in response.text


@pytest.mark.asyncio
async def test_focus_review_period_and_suggestion_transport_contract(
  client: httpx.AsyncClient,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """The HTTP JSON contract matches the iOS Day/Week/Month review model."""

  current = datetime(2026, 7, 16, 8, tzinfo=UTC)
  suggestion = FocusEventSuggestion(
    focus_area=FocusArea.WORK,
    title="Project work",
    suggested_start_at=datetime(2026, 7, 16, 18, tzinfo=UTC),
    suggested_end_at=datetime(2026, 7, 16, 19, tzinfo=UTC),
    rationale="May restore visible planned time for this interest.",
    confidence=EvidenceConfidence.HIGH,
    action=FocusSuggestionAction.REQUIRES_EXPLICIT_SCHEDULING,
  )
  suggestions = [
    suggestion.model_copy(update={"title": f"Project work {index}"})
    for index in range(7)
  ]
  review = FocusReviewResult(
    areas=[
      LLMFocusAreaReview(
        focus_area=FocusArea.WORK,
        recent_visibility=ScheduleVisibility.NOT_VISIBLE,
        upcoming_visibility=ScheduleVisibility.NOT_VISIBLE,
        scheduled_evidence="No matching scheduled event is visible.",
        likely_impact="May slow this goal if the pattern continues.",
        confidence=EvidenceConfidence.HIGH,
      )
    ],
    next_adjustment="Protect one small work block.",
    suggested_events=suggestions,
    period=FocusReviewPeriod.DAY,
    recent_start_at=datetime(2026, 7, 16, 0, tzinfo=UTC),
    period_end_at=current,
    current_time=current,
    upcoming_end_at=datetime(2026, 7, 16, 22, tzinfo=UTC),
    tracking_started_at=datetime(2026, 7, 1, 0, tzinfo=UTC),
    history_coverage=HistoryCoverage.FULL,
    context_truncated=False,
  )
  service = FakeService(
    response=response_fixture().model_copy(update={"focus_review": review})
  )
  override_service(app, service)
  request = request_factory(
    calendar_action_requested=False,
    focus_review_requested=True,
    focus_review_period=FocusReviewPeriod.DAY,
    focus_review_start=datetime(2026, 7, 16, 0, tzinfo=UTC),
    focus_review_end=current,
    preferences={
      "timezone": "UTC",
      "selected_focus_areas": [FocusArea.WORK],
    },
  )

  response = await client.post(
    "/api/v1/agent/turn",
    json=request.model_dump(mode="json"),
  )

  assert response.status_code == 200
  payload = response.json()["focus_review"]
  assert payload["period"] == "day"
  assert payload["history_coverage"] == "full"
  assert len(payload["suggested_events"]) == 7
  assert payload["suggested_events"][0]["action"] == (
    "requires_explicit_scheduling"
  )
  assert "proposal_id" not in payload["suggested_events"][0]


@pytest.mark.asyncio
async def test_invalid_turn_is_rejected_before_service(
  client: httpx.AsyncClient,
) -> None:
  """Pydantic rejects malformed context at the transport boundary."""

  response = await client.post(
    "/api/v1/agent/turn",
    json={"message": "missing required context"},
  )
  assert response.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize(
  ("error", "expected_status"),
  [
    (BYOKNotAllowedError(), 403),
    (LLMConfigurationError(), 503),
    (LLMProviderError(), 502),
    (LLMAuthenticationError(), 502),
  ],
)
async def test_provider_errors_are_sanitized(
  client: httpx.AsyncClient,
  request_factory: Callable[..., AgentTurnRequest],
  error: Exception,
  expected_status: int,
) -> None:
  """Upstream details never cross the API boundary."""

  service = FakeService(error=error)
  override_service(app, service)
  response = await client.post(
    "/api/v1/agent/turn",
    json=request_factory().model_dump(mode="json"),
  )

  assert response.status_code == expected_status
  assert "secret" not in response.text.lower()


@pytest.mark.asyncio
async def test_provider_failure_log_has_safe_category_and_request_id(
  client: httpx.AsyncClient,
  request_factory: Callable[..., AgentTurnRequest],
  caplog: pytest.LogCaptureFixture,
) -> None:
  """Railway logs correlate provider failures without private response text."""

  service = FakeService(
    error=LLMProviderError(
      "private provider response",
      failure_category="structured_validation",
    )
  )
  override_service(app, service)

  with caplog.at_level(
    logging.WARNING,
    logger="app.api.v1.endpoints.agent",
  ):
    response = await client.post(
      "/api/v1/agent/turn",
      json=request_factory().model_dump(mode="json"),
      headers={"x-request-id": "review-regression-request"},
    )

  assert response.status_code == 502
  assert "review-regression-request" in caplog.text
  assert "category=structured_validation" in caplog.text
  assert "private provider response" not in caplog.text


@pytest.mark.asyncio
async def test_byok_auth_error_returns_unauthorized(
  client: httpx.AsyncClient,
  request_factory: Callable[..., AgentTurnRequest],
) -> None:
  """A rejected caller-supplied provider key maps to 401."""

  override_service(app, FakeService(error=LLMAuthenticationError()))
  response = await client.post(
    "/api/v1/agent/turn",
    json=request_factory().model_dump(mode="json"),
    headers={"x-ai-api-key": "bad-key"},
  )
  assert response.status_code == 401
