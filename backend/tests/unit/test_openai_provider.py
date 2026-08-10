"""OpenAI Responses adapter tests."""

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest
from pydantic import ValidationError

from app.core.exceptions import LLMProviderError
from app.core.llm.openai_provider import OpenAIProvider
from app.schemas.agent import LLMTurn


class FakeResponses:
  """Capture structured parse arguments."""

  def __init__(
    self,
    parsed: LLMTurn | None,
    error: Exception | None = None,
  ) -> None:
    self.parsed = parsed
    self.error = error
    self.kwargs: dict[str, Any] = {}

  async def parse(self, **kwargs: Any) -> SimpleNamespace:
    """Return a response-like object."""

    self.kwargs = kwargs
    if self.error is not None:
      raise self.error
    return SimpleNamespace(output_parsed=self.parsed)


class FakeOpenAIClient:
  """Client shape required by the adapter."""

  def __init__(
    self,
    parsed: LLMTurn | None,
    error: Exception | None = None,
  ) -> None:
    self.responses = FakeResponses(parsed, error)


class SlowResponses:
  """Return valid output only after the configured total deadline."""

  def __init__(self, parsed: LLMTurn) -> None:
    self.parsed = parsed

  async def parse(self, **kwargs: Any) -> SimpleNamespace:
    """Simulate an SDK attempt that ignores its own transport timeout."""

    del kwargs
    await asyncio.sleep(0.05)
    return SimpleNamespace(output_parsed=self.parsed)


class SlowOpenAIClient:
  """Client shape for the total-deadline test."""

  def __init__(self, parsed: LLMTurn) -> None:
    self.responses = SlowResponses(parsed)


@pytest.mark.asyncio
async def test_openai_uses_responses_structured_parse() -> None:
  """The adapter uses provider-native Pydantic output."""

  expected = LLMTurn(
    message="Plan",
    proposals=[],
    check_in_question="Ready?",
  )
  client = FakeOpenAIClient(expected)
  provider = OpenAIProvider("key", "gpt-test", client=client)

  result = await provider.generate_turn("system", "user")

  assert result == expected
  assert client.responses.kwargs["model"] == "gpt-test"
  assert client.responses.kwargs["store"] is False
  assert client.responses.kwargs["text_format"] is LLMTurn
  messages = client.responses.kwargs["input"]
  assert messages[0]["role"] == "developer"
  assert messages[1]["role"] == "user"


@pytest.mark.asyncio
async def test_openai_rejects_missing_structured_output() -> None:
  """A syntactically successful but empty response fails closed."""

  provider = OpenAIProvider(
    "key",
    "gpt-test",
    client=FakeOpenAIClient(None),
  )
  with pytest.raises(LLMProviderError, match="no structured"):
    await provider.generate_turn("system", "user")


@pytest.mark.asyncio
async def test_openai_sanitizes_structured_validation_errors() -> None:
  """Provider parse failures never escape as raw validation details."""

  with pytest.raises(ValidationError) as captured:
    LLMTurn.model_validate({})
  provider = OpenAIProvider(
    "key",
    "gpt-test",
    client=FakeOpenAIClient(None, captured.value),
  )

  with pytest.raises(LLMProviderError, match="invalid structured"):
    await provider.generate_turn("system", "user")


@pytest.mark.asyncio
async def test_openai_enforces_one_total_deadline_across_sdk_retries() -> None:
  """The backend stops before the iPhone request timeout even with retries."""

  expected = LLMTurn(
    message="Too late",
    proposals=[],
    check_in_question=None,
  )
  provider = OpenAIProvider(
    "key",
    "gpt-test",
    client=SlowOpenAIClient(expected),
    timeout_seconds=0.001,
  )

  with pytest.raises(LLMProviderError, match="temporarily unavailable"):
    await provider.generate_turn("system", "user")


def test_openai_client_has_bounded_timeout_and_retries(
  monkeypatch: pytest.MonkeyPatch,
) -> None:
  """Provider construction applies the operator's transport bounds."""

  captured: dict[str, object] = {}

  def build_client(**values: object) -> FakeOpenAIClient:
    captured.update(values)
    return FakeOpenAIClient(None)

  monkeypatch.setattr("openai.AsyncOpenAI", build_client)

  OpenAIProvider(
    "server-key",
    "gpt-test",
    timeout_seconds=25,
    max_retries=1,
  )

  assert captured == {
    "api_key": "server-key",
    "timeout": 25,
    "max_retries": 1,
  }
