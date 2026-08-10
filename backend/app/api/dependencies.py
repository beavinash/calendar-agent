"""FastAPI dependency composition."""

from typing import Annotated

from fastapi import Depends

from app.core.config import Settings, get_settings
from app.core.llm.factory import LLMProviderFactory
from app.repositories.agent_turn_repository import (
  AgentTurnAuditWriter,
  AgentTurnRepository,
  NoOpAgentTurnAuditWriter,
)
from app.services.agent_service import AgentService


def get_agent_service(
  settings: Annotated[Settings, Depends(get_settings)],
) -> AgentService:
  """Compose one request-scoped agent service."""

  audit_writer: AgentTurnAuditWriter
  if settings.audit_persistence_enabled:
    audit_writer = AgentTurnRepository()
  else:
    audit_writer = NoOpAgentTurnAuditWriter()
  return AgentService(
    settings=settings,
    provider_factory=LLMProviderFactory(settings),
    audit_writer=audit_writer,
  )
