"""Configuration safety tests."""

import pytest
from pydantic import SecretStr, ValidationError

from app.core.config import Settings


def test_production_requires_app_shared_secret() -> None:
  """A production model proxy must never start unauthenticated."""

  with pytest.raises(ValidationError, match="APP_SHARED_SECRET"):
    Settings(
      environment="production",
      app_shared_secret=None,
      openai_api_key=SecretStr("configured"),
    )

  settings = Settings(
    environment="production",
    app_shared_secret=SecretStr("configured"),
    openai_api_key=SecretStr("configured"),
  )

  assert settings.app_shared_secret is not None


def test_production_requires_openai_key_and_disables_byok() -> None:
  """Hosted production always uses the operator-managed OpenAI key."""

  with pytest.raises(ValidationError, match="OPENAI_API_KEY"):
    Settings(
      environment="production",
      app_shared_secret=SecretStr("configured"),
      openai_api_key=None,
    )

  with pytest.raises(ValidationError, match="ALLOW_BYOK"):
    Settings(
      environment="production",
      app_shared_secret=SecretStr("configured"),
      openai_api_key=SecretStr("configured"),
      allow_byok=True,
    )


def test_environment_rejects_unknown_values() -> None:
  """A misspelled deployment environment must fail instead of falling open."""

  with pytest.raises(ValidationError):
    Settings.model_validate({"environment": "prodution"})


def test_openai_model_and_transport_bounds_are_validated() -> None:
  """A blank model or unbounded provider transport fails at startup."""

  with pytest.raises(ValidationError, match="OPENAI_MODEL"):
    Settings(openai_model="   ")
  with pytest.raises(ValidationError):
    Settings(openai_timeout_seconds=0)
  with pytest.raises(ValidationError):
    Settings(openai_timeout_seconds=51)
  with pytest.raises(ValidationError):
    Settings(openai_max_retries=6)

  settings = Settings()
  assert settings.openai_timeout_seconds == 45
  assert settings.openai_max_retries == 2
  assert settings.audit_persistence_enabled is False


def test_default_proposal_limit_is_five() -> None:
  """A coach turn can return the full supported five safe blocks."""

  assert Settings().max_proposals == 5
