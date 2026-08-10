"""OpenAI Responses API implementation."""

import asyncio
from inspect import isawaitable
from typing import Any, cast

import openai
from pydantic import ValidationError

from app.core.exceptions import LLMAuthenticationError, LLMProviderError
from app.schemas.agent import LLMTurn


class OpenAIProvider:
  """Generate structured planning turns with the OpenAI Responses API."""

  def __init__(
    self,
    api_key: str,
    model: str,
    client: Any | None = None,
    *,
    timeout_seconds: float = 45,
    max_retries: int = 2,
  ) -> None:
    """Initialize a request-scoped OpenAI client."""

    self._model = model
    self._total_timeout_seconds = timeout_seconds
    self._client = client or openai.AsyncOpenAI(
      api_key=api_key,
      timeout=timeout_seconds,
      max_retries=max_retries,
    )

  @property
  def model(self) -> str:
    """Return the selected OpenAI model."""

    return self._model

  async def generate_turn(
    self,
    system_prompt: str,
    user_prompt: str,
  ) -> LLMTurn:
    """Use native Pydantic structured output through Responses."""

    try:
      async with asyncio.timeout(self._total_timeout_seconds):
        response = await self._client.responses.parse(
          model=self._model,
          store=False,
          input=[
            {"role": "developer", "content": system_prompt},
            {"role": "user", "content": user_prompt},
          ],
          text_format=LLMTurn,
        )
    except TimeoutError as error:
      raise LLMProviderError(
        "OpenAI is temporarily unavailable",
        failure_category="timeout",
      ) from error
    except openai.AuthenticationError as error:
      raise LLMAuthenticationError(
        "OpenAI rejected the configured credential"
      ) from error
    except openai.RateLimitError as error:
      raise LLMProviderError(
        "OpenAI is temporarily unavailable",
        failure_category="rate_limit",
      ) from error
    except openai.APITimeoutError as error:
      raise LLMProviderError(
        "OpenAI is temporarily unavailable",
        failure_category="timeout",
      ) from error
    except ValidationError as error:
      raise LLMProviderError(
        "OpenAI returned invalid structured output",
        failure_category="structured_validation",
      ) from error
    except openai.APIError as error:
      raise LLMProviderError(
        "OpenAI request failed",
        failure_category="upstream_api",
      ) from error

    parsed = cast(LLMTurn | None, response.output_parsed)
    if parsed is None:
      raise LLMProviderError(
        "OpenAI returned no structured output",
        failure_category="empty_output",
      )
    return parsed

  async def close(self) -> None:
    """Close the request-scoped SDK transport when supported."""

    close = getattr(self._client, "close", None)
    if close is not None:
      result = close()
      if isawaitable(result):
        await result
