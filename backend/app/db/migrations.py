"""Small migration configuration helpers."""


def escape_alembic_url(url: str) -> str:
  """Escape ConfigParser interpolation characters in a database URL."""

  return url.replace("%", "%%")
