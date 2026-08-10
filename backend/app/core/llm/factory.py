"""Request-safe LLM provider selection."""

from pydantic import SecretStr

from app.core.config import Settings
from app.core.exceptions import BYOKNotAllowedError, LLMConfigurationError
from app.core.llm.base import LLMProvider
from app.core.llm.gemini_provider import GeminiProvider
from app.core.llm.openai_provider import OpenAIProvider


class LLMProviderFactory:
  """Create providers without process-global API-key configuration."""

  def __init__(self, settings: Settings) -> None:
    """Store immutable selection settings."""

    self._settings = settings

  def create(
    self,
    provider_name: str,
    requested_model: str | None,
    api_key_override: str | None,
  ) -> LLMProvider:
    """Create one provider using an environment or explicitly allowed key."""

    if api_key_override and not self._settings.allow_byok:
      raise BYOKNotAllowedError("Runtime provider keys are disabled")

    if self._settings.environment.lower() == "production":
      key = self._resolve_key(
        None,
        self._settings.openai_api_key,
        "OPENAI_API_KEY",
      )
      return OpenAIProvider(
        api_key=key,
        model=self._settings.openai_model,
        timeout_seconds=self._settings.openai_timeout_seconds,
        max_retries=self._settings.openai_max_retries,
      )

    if provider_name == "openai":
      model = requested_model or self._settings.openai_model
      key = self._resolve_key(
        api_key_override,
        self._settings.openai_api_key,
        "OPENAI_API_KEY",
      )
      return OpenAIProvider(
        api_key=key,
        model=model,
        timeout_seconds=self._settings.openai_timeout_seconds,
        max_retries=self._settings.openai_max_retries,
      )

    if provider_name == "gemini":
      model = requested_model or self._settings.gemini_model
      key = self._resolve_key(
        api_key_override,
        self._settings.gemini_api_key,
        "GEMINI_API_KEY",
      )
      return GeminiProvider(api_key=key, model=model)

    raise LLMConfigurationError("Unsupported model provider")

  @staticmethod
  def _resolve_key(
    override: str | None,
    configured: SecretStr | None,
    variable_name: str,
  ) -> str:
    """Resolve a secret without logging or retaining the caller value."""

    if override:
      return override
    if configured is not None:
      value = configured.get_secret_value()
      if value:
        return value
    raise LLMConfigurationError(f"{variable_name} is not configured")
