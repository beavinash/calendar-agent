"""Async SQLAlchemy session lifecycle."""

from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import (
  AsyncSession,
  async_sessionmaker,
  create_async_engine,
)

from app.core.config import get_settings

settings = get_settings()
engine = create_async_engine(
  settings.database_url,
  pool_pre_ping=True,
)
SessionFactory = async_sessionmaker(
  bind=engine,
  class_=AsyncSession,
  expire_on_commit=False,
)


async def get_session() -> AsyncIterator[AsyncSession]:
  """Yield one transaction-scoped async session."""

  async with SessionFactory() as session:
    try:
      yield session
      await session.commit()
    except Exception:
      await session.rollback()
      raise
