"""Provider factory security tests."""

from typing import Any

import pytest
from pydantic import SecretStr

from app.core.config import Settings
from app.core.exceptions import BYOKNotAllowedError, LLMConfigurationError
from app.core.llm.factory import LLMProviderFactory
from app.core.llm.openai_provider import OpenAIProvider
from app.schemas.agent import LLMTurn


class FakeProvider:
  """Minimal provider returned by a monkeypatched constructor."""

  def __init__(self, model: str) -> None:
    self._model = model

  @property
  def model(self) -> str:
    """Return the fake model."""

    return self._model

  async def generate_turn(
    self,
    system_prompt: str,
    user_prompt: str,
  ) -> LLMTurn:
    """This factory test never generates."""

    raise AssertionError((system_prompt, user_prompt))

  async def close(self) -> None:
    """No-op transport cleanup for protocol compatibility."""


def test_factory_uses_server_openai_key_and_default_model() -> None:
  """Default mode creates a request-local client from environment settings."""

  settings = Settings(
    openai_api_key=SecretStr("server-openai-key"),
    openai_model="gpt-test",
  )
  provider = LLMProviderFactory(settings).create("openai", None, None)

  assert isinstance(provider, OpenAIProvider)
  assert provider.model == "gpt-test"


def test_production_forces_server_openai_provider_and_model(
  monkeypatch: pytest.MonkeyPatch,
) -> None:
  """Client provider/model selection cannot change production routing."""

  captured: dict[str, object] = {}

  def build_openai(
    api_key: str,
    model: str,
    *,
    timeout_seconds: float,
    max_retries: int,
  ) -> FakeProvider:
    captured.update(
      api_key=api_key,
      model=model,
      timeout_seconds=timeout_seconds,
      max_retries=max_retries,
    )
    return FakeProvider(model)

  monkeypatch.setattr(
    "app.core.llm.factory.OpenAIProvider",
    build_openai,
  )
  settings = Settings(
    environment="production",
    app_shared_secret=SecretStr("app-secret"),
    openai_api_key=SecretStr("server-openai-key"),
    openai_model="operator-model",
    openai_timeout_seconds=30,
    openai_max_retries=1,
  )

  provider = LLMProviderFactory(settings).create(
    "gemini",
    "client-selected-model",
    None,
  )

  assert provider.model == "operator-model"
  assert captured == {
    "api_key": "server-openai-key",
    "model": "operator-model",
    "timeout_seconds": 30,
    "max_retries": 1,
  }


def test_factory_allows_explicit_byok_and_gemini_override(
  monkeypatch: pytest.MonkeyPatch,
) -> None:
  """BYOK works only when enabled and uses the requested model."""

  captured: dict[str, str] = {}

  def build_gemini(api_key: str, model: str) -> FakeProvider:
    captured["key"] = api_key
    captured["model"] = model
    return FakeProvider(model)

  monkeypatch.setattr(
    "app.core.llm.factory.GeminiProvider",
    build_gemini,
  )
  settings = Settings(allow_byok=True)
  provider = LLMProviderFactory(settings).create(
    "gemini",
    "gemini-test",
    "runtime-key",
  )

  assert provider.model == "gemini-test"
  assert captured == {"key": "runtime-key", "model": "gemini-test"}


def test_factory_rejects_disabled_byok_missing_key_and_provider(
  monkeypatch: pytest.MonkeyPatch,
) -> None:
  """Credential and provider failures are explicit without echoing secrets."""

  monkeypatch.setenv("OPENAI_API_KEY", "")

  with pytest.raises(BYOKNotAllowedError):
    LLMProviderFactory(Settings()).create(
      "openai",
      None,
      "do-not-echo",
    )

  with pytest.raises(LLMConfigurationError, match="OPENAI_API_KEY"):
    LLMProviderFactory(Settings()).create("openai", None, None)

  with pytest.raises(LLMConfigurationError, match="Unsupported"):
    LLMProviderFactory(Settings()).create("unknown", None, None)


def test_resolve_key_accepts_secret_and_rejects_empty() -> None:
  """Key resolution handles Pydantic secret values directly."""

  assert (
    LLMProviderFactory._resolve_key(
      None,
      SecretStr("configured"),
      "KEY",
    )
    == "configured"
  )
  with pytest.raises(LLMConfigurationError, match="KEY"):
    LLMProviderFactory._resolve_key(None, SecretStr(""), "KEY")


def test_fake_provider_is_protocol_compatible() -> None:
  """Keep the typed test double honest."""

  provider: Any = FakeProvider("model")
  assert provider.model == "model"
