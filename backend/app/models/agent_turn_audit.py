"""Privacy-minimized operational audit model."""

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import DateTime, Integer, String, Uuid, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class AgentTurnAudit(Base):
  """Store aggregate turn metadata without user context or provider keys."""

  __tablename__ = "agent_turn_audits"

  id: Mapped[UUID] = mapped_column(
    Uuid(as_uuid=True),
    primary_key=True,
    default=uuid4,
  )
  request_id: Mapped[UUID] = mapped_column(
    Uuid(as_uuid=True),
    unique=True,
    nullable=False,
    index=True,
  )
  device_id: Mapped[UUID] = mapped_column(
    Uuid(as_uuid=True),
    nullable=False,
    index=True,
  )
  provider: Mapped[str] = mapped_column(String(20), nullable=False)
  model: Mapped[str] = mapped_column(String(80), nullable=False)
  proposal_count: Mapped[int] = mapped_column(Integer, nullable=False)
  rejected_count: Mapped[int] = mapped_column(Integer, nullable=False)
  created_at: Mapped[datetime] = mapped_column(
    DateTime(timezone=True),
    server_default=func.now(),
    nullable=False,
  )
  deleted_at: Mapped[datetime | None] = mapped_column(
    DateTime(timezone=True),
    nullable=True,
  )
