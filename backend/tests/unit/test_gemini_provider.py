"""Gemini Interactions adapter tests."""

from types import SimpleNamespace
from typing import Any

import pytest
from google.genai import errors as genai_errors

from app.core.exceptions import LLMAuthenticationError, LLMProviderError
from app.core.llm.gemini_provider import GeminiProvider


class FakeInteractions:
  """Synchronous interactions endpoint fake."""

  def __init__(self, output: str | None = None, error: Exception | None = None):
    self.output = output
    self.error = error
    self.kwargs: dict[str, Any] = {}

  def create(self, **kwargs: Any) -> SimpleNamespace:
    """Return output or raise the configured exception."""

    self.kwargs = kwargs
    if self.error is not None:
      raise self.error
    return SimpleNamespace(output_text=self.output)


class FakeGeminiClient:
  """Client shape required by the adapter."""

  def __init__(self, interactions: FakeInteractions) -> None:
    self.interactions = interactions


@pytest.mark.asyncio
async def test_gemini_uses_structured_interactions() -> None:
  """The adapter supplies JSON schema and validates the result."""

  endpoint = FakeInteractions(
    '{"message":"Plan","proposals":[],"check_in_question":null}'
  )
  provider = GeminiProvider(
    "key",
    "gemini-test",
    client=FakeGeminiClient(endpoint),
  )

  result = await provider.generate_turn("system", "user")

  assert result.message == "Plan"
  assert endpoint.kwargs["model"] == "gemini-test"
  assert endpoint.kwargs["store"] is False
  assert endpoint.kwargs["response_format"]["mime_type"] == ("application/json")
  assert endpoint.kwargs["system_instruction"] == "system"
  assert endpoint.kwargs["input"] == "user"
  schema_text = str(endpoint.kwargs["response_format"]["schema"])
  assert "minLength" not in schema_text
  assert "maxLength" not in schema_text
  assert "pattern" not in schema_text


@pytest.mark.asyncio
async def test_gemini_rejects_invalid_or_empty_output() -> None:
  """Malformed structured output never reaches scheduling policy."""

  invalid = GeminiProvider(
    "key",
    "model",
    client=FakeGeminiClient(FakeInteractions("not-json")),
  )
  with pytest.raises(LLMProviderError, match="invalid structured"):
    await invalid.generate_turn("system", "user")

  empty = GeminiProvider(
    "key",
    "model",
    client=FakeGeminiClient(FakeInteractions(None)),
  )
  with pytest.raises(LLMProviderError, match="no structured"):
    await empty.generate_turn("system", "user")


@pytest.mark.asyncio
async def test_gemini_maps_auth_and_generic_errors() -> None:
  """Provider errors are sanitized into stable application errors."""

  denied = GeminiProvider(
    "key",
    "model",
    client=FakeGeminiClient(
      FakeInteractions(
        error=genai_errors.ClientError(
          400,
          {
            "error": {
              "message": "secret detail",
              "details": [{"reason": "API_KEY_INVALID"}],
            }
          },
        )
      )
    ),
  )
  with pytest.raises(LLMAuthenticationError, match="credential"):
    await denied.generate_turn("system", "user")

  failed = GeminiProvider(
    "key",
    "model",
    client=FakeGeminiClient(FakeInteractions(error=RuntimeError("detail"))),
  )
  with pytest.raises(LLMProviderError, match="request failed"):
    await failed.generate_turn("system", "user")
