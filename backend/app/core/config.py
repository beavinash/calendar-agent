"""Application settings."""

from functools import lru_cache
from typing import Literal, Self

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
  """Environment-backed application configuration."""

  model_config = SettingsConfigDict(
    env_file=".env",
    env_file_encoding="utf-8",
    case_sensitive=False,
    extra="ignore",
  )

  environment: Literal["development", "test", "production"] = "development"
  api_v1_prefix: str = "/api/v1"
  database_url: str = (
    "postgresql+asyncpg://calendar_agent:calendar_agent@"
    "localhost:5434/calendar_agent"
  )
  cors_origins: list[str] = Field(default_factory=lambda: ["http://localhost"])

  openai_api_key: SecretStr | None = None
  openai_model: str = Field(
    default="gpt-5.6-luna",
    min_length=1,
    max_length=80,
  )
  openai_timeout_seconds: float = Field(default=45, gt=0, le=50)
  openai_max_retries: int = Field(default=2, ge=0, le=5)
  gemini_api_key: SecretStr | None = None
  gemini_model: str = "gemini-3.5-flash"

  app_shared_secret: SecretStr | None = None
  allow_byok: bool = False
  audit_persistence_enabled: bool = False

  max_proposals: int = Field(default=5, ge=1, le=5)
  planning_horizon_days: int = Field(default=14, ge=1, le=31)
  max_block_minutes: int = Field(default=240, ge=30, le=480)

  @field_validator("openai_model")
  @classmethod
  def validate_openai_model(cls, value: str) -> str:
    """Reject an empty operator model after trimming whitespace."""

    normalized = value.strip()
    if not normalized:
      raise ValueError("OPENAI_MODEL must not be empty")
    return normalized

  @model_validator(mode="after")
  def require_production_authentication(self) -> Self:
    """Refuse a production model proxy without an app credential."""

    if self.environment.lower() != "production":
      return self
    if self.app_shared_secret is None or not (
      self.app_shared_secret.get_secret_value().strip()
    ):
      raise ValueError("APP_SHARED_SECRET is required in production")
    if self.openai_api_key is None or not (
      self.openai_api_key.get_secret_value().strip()
    ):
      raise ValueError("OPENAI_API_KEY is required in production")
    if self.allow_byok:
      raise ValueError("ALLOW_BYOK must be false in production")
    return self


@lru_cache
def get_settings() -> Settings:
  """Return the cached settings instance."""

  return Settings()
