"""Agent turn audit persistence."""

from __future__ import annotations

from typing import Protocol
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.models.agent_turn_audit import AgentTurnAudit


class AgentTurnAuditWriter(Protocol):
  """Narrow persistence boundary used by the service."""

  async def create(
    self,
    *,
    request_id: UUID,
    device_id: UUID,
    provider: str,
    model: str,
    proposal_count: int,
    rejected_count: int,
  ) -> AgentTurnAudit:
    """Persist safe aggregate metadata for a completed turn."""


class AgentTurnRepository:
  """SQLAlchemy implementation of the audit writer."""

  def __init__(
    self,
    session_factory: async_sessionmaker[AsyncSession] | None = None,
  ) -> None:
    """Use an isolated transaction so audit failure cannot fail a turn."""

    if session_factory is None:
      from app.db.session import SessionFactory

      session_factory = SessionFactory
    self._session_factory = session_factory

  async def create(
    self,
    *,
    request_id: UUID,
    device_id: UUID,
    provider: str,
    model: str,
    proposal_count: int,
    rejected_count: int,
  ) -> AgentTurnAudit:
    """Commit metadata without storing model context."""

    audit = AgentTurnAudit(
      request_id=request_id,
      device_id=device_id,
      provider=provider,
      model=model,
      proposal_count=proposal_count,
      rejected_count=rejected_count,
    )
    async with self._session_factory() as session:
      try:
        session.add(audit)
        await session.commit()
      except Exception:
        await session.rollback()
        raise
    return audit


class NoOpAgentTurnAuditWriter:
  """Keep aggregate audit composition without persistent infrastructure."""

  async def create(
    self,
    *,
    request_id: UUID,
    device_id: UUID,
    provider: str,
    model: str,
    proposal_count: int,
    rejected_count: int,
  ) -> AgentTurnAudit:
    """Return transient metadata without opening a database session."""

    return AgentTurnAudit(
      request_id=request_id,
      device_id=device_id,
      provider=provider,
      model=model,
      proposal_count=proposal_count,
      rejected_count=rejected_count,
    )
