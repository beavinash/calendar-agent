"""Gemini Interactions API implementation."""

import asyncio
from typing import Any

from google.genai import errors as genai_errors
from pydantic import ValidationError

from app.core.exceptions import LLMAuthenticationError, LLMProviderError
from app.schemas.agent import LLMTurn


class GeminiProvider:
  """Generate structured turns with Google's stable Interactions API."""

  def __init__(
    self,
    api_key: str,
    model: str,
    client: Any | None = None,
  ) -> None:
    """Initialize a request-scoped Gemini client."""

    if client is None:
      from google import genai

      client = genai.Client(
        api_key=api_key,
        http_options={"api_version": "v1"},
      )
    self._client = client
    self._model = model

  @property
  def model(self) -> str:
    """Return the selected Gemini model."""

    return self._model

  async def generate_turn(
    self,
    system_prompt: str,
    user_prompt: str,
  ) -> LLMTurn:
    """Run the synchronous SDK call off the event loop and validate JSON."""

    try:
      output_text = await asyncio.to_thread(
        self._generate_sync,
        system_prompt,
        user_prompt,
      )
      return LLMTurn.model_validate_json(output_text)
    except ValidationError as error:
      raise LLMProviderError(
        "Gemini returned invalid structured output",
        failure_category="structured_validation",
      ) from error
    except genai_errors.ClientError as error:
      if error.code in (401, 403) or "API_KEY_INVALID" in str(error.details):
        raise LLMAuthenticationError(
          "Gemini rejected the configured credential"
        ) from error
      raise LLMProviderError(
        "Gemini request failed",
        failure_category="upstream_api",
      ) from error
    except LLMProviderError:
      raise
    except Exception as error:
      raise LLMProviderError(
        "Gemini request failed",
        failure_category="upstream_api",
      ) from error

  def _generate_sync(self, system_prompt: str, user_prompt: str) -> str:
    """Call the stable Gemini Interactions API."""

    interaction = self._client.interactions.create(
      model=self._model,
      store=False,
      system_instruction=system_prompt,
      input=user_prompt,
      response_format={
        "type": "text",
        "mime_type": "application/json",
        "schema": _gemini_schema(LLMTurn.model_json_schema()),
      },
    )
    output_text = getattr(interaction, "output_text", None)
    if not isinstance(output_text, str) or not output_text:
      raise LLMProviderError(
        "Gemini returned no structured output",
        failure_category="empty_output",
      )
    return output_text

  async def close(self) -> None:
    """Close the request-scoped SDK transport when supported."""

    close = getattr(self._client, "close", None)
    if close is not None:
      await asyncio.to_thread(close)


def _gemini_schema(value: Any) -> Any:
  """Remove unsupported JSON Schema string constraints for Gemini.

  Pydantic validates the complete contract again after generation, so removing
  provider-unsupported generation hints does not weaken the API boundary.
  """

  if isinstance(value, list):
    return [_gemini_schema(item) for item in value]
  if not isinstance(value, dict):
    return value

  result = {key: _gemini_schema(item) for key, item in value.items()}
  if result.get("type") == "string":
    result.pop("minLength", None)
    result.pop("maxLength", None)
    result.pop("pattern", None)
  return result
