"""API dependency composition tests."""

from pydantic import SecretStr

from app.api.dependencies import get_agent_service
from app.core.config import Settings
from app.repositories.agent_turn_repository import (
  AgentTurnRepository,
  NoOpAgentTurnAuditWriter,
)


def test_stateless_service_uses_noop_audit_writer() -> None:
  """The default personal deployment never requires PostgreSQL."""

  service = get_agent_service(Settings())

  assert isinstance(service._audit_writer, NoOpAgentTurnAuditWriter)


def test_explicit_audit_persistence_uses_database_repository() -> None:
  """Operators can opt back into the existing aggregate audit database."""

  settings = Settings(
    audit_persistence_enabled=True,
    database_url="sqlite+aiosqlite:///:memory:",
  )

  service = get_agent_service(settings)

  assert isinstance(service._audit_writer, AgentTurnRepository)


def test_production_service_is_stateless_by_default() -> None:
  """Production does not accidentally create an audit database dependency."""

  settings = Settings(
    environment="production",
    app_shared_secret=SecretStr("app-secret"),
    openai_api_key=SecretStr("openai-key"),
  )

  service = get_agent_service(settings)

  assert isinstance(service._audit_writer, NoOpAgentTurnAuditWriter)
