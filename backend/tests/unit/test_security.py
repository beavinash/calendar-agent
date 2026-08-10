"""Shared-secret boundary tests."""

import pytest
from fastapi import HTTPException
from pydantic import SecretStr

from app.core.config import Settings
from app.core.security import require_app_secret


def test_unset_secret_allows_local_development() -> None:
  """An unset secret keeps the documented local workflow frictionless."""

  require_app_secret(Settings(), None)


def test_configured_secret_uses_exact_constant_time_comparison() -> None:
  """A configured deployment secret rejects missing and incorrect values."""

  settings = Settings(app_shared_secret=SecretStr("expected"))
  with pytest.raises(HTTPException) as missing:
    require_app_secret(settings, None)
  assert missing.value.status_code == 401

  with pytest.raises(HTTPException) as incorrect:
    require_app_secret(settings, "wrong")
  assert incorrect.value.status_code == 401

  require_app_secret(settings, "expected")
