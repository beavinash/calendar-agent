"""Migration configuration tests."""

from app.db.migrations import escape_alembic_url


def test_database_url_escapes_config_interpolation() -> None:
  """URL-encoded database passwords remain valid in Alembic config."""

  url = "postgresql+asyncpg://user:p%40ss@localhost/database"

  assert escape_alembic_url(url) == (
    "postgresql+asyncpg://user:p%%40ss@localhost/database"
  )
