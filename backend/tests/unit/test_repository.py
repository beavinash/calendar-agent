"""Repository boundary tests."""

from unittest.mock import AsyncMock, MagicMock, Mock
from uuid import uuid4

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.repositories.agent_turn_repository import (
  AgentTurnRepository,
  NoOpAgentTurnAuditWriter,
)


@pytest.mark.asyncio
async def test_repository_writes_only_aggregate_metadata() -> None:
  """The database model has no fields for prompts, notes, or provider keys."""

  session = Mock(spec=AsyncSession)
  session.commit = AsyncMock()
  session.rollback = AsyncMock()
  context = MagicMock()
  context.__aenter__ = AsyncMock(return_value=session)
  context.__aexit__ = AsyncMock(return_value=None)
  session_factory = Mock(return_value=context)
  repository = AgentTurnRepository(session_factory)
  request_id = uuid4()
  device_id = uuid4()

  audit = await repository.create(
    request_id=request_id,
    device_id=device_id,
    provider="openai",
    model="gpt-test",
    proposal_count=2,
    rejected_count=1,
  )

  session.add.assert_called_once_with(audit)
  session.commit.assert_awaited_once()
  session.rollback.assert_not_awaited()
  assert audit.request_id == request_id
  assert audit.device_id == device_id
  assert not hasattr(audit, "prompt")
  assert not hasattr(audit, "api_key")


@pytest.mark.asyncio
async def test_repository_rolls_back_a_failed_audit_commit() -> None:
  """A failed isolated audit transaction returns the session to safety."""

  session = Mock(spec=AsyncSession)
  session.commit = AsyncMock(side_effect=RuntimeError("database down"))
  session.rollback = AsyncMock()
  context = MagicMock()
  context.__aenter__ = AsyncMock(return_value=session)
  context.__aexit__ = AsyncMock(return_value=None)
  repository = AgentTurnRepository(Mock(return_value=context))

  with pytest.raises(RuntimeError, match="database down"):
    await repository.create(
      request_id=uuid4(),
      device_id=uuid4(),
      provider="openai",
      model="gpt-test",
      proposal_count=1,
      rejected_count=0,
    )

  session.rollback.assert_awaited_once()


@pytest.mark.asyncio
async def test_noop_audit_writer_returns_metadata_without_a_database() -> None:
  """Stateless deployments retain the contract without opening a session."""

  request_id = uuid4()
  device_id = uuid4()
  audit = await NoOpAgentTurnAuditWriter().create(
    request_id=request_id,
    device_id=device_id,
    provider="openai",
    model="gpt-test",
    proposal_count=2,
    rejected_count=1,
  )

  assert audit.request_id == request_id
  assert audit.device_id == device_id
  assert audit.provider == "openai"
