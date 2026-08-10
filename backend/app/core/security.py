"""Small API authentication boundary."""

import secrets
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status

from app.core.config import Settings, get_settings


def require_app_secret(
  settings: Annotated[Settings, Depends(get_settings)],
  x_app_secret: Annotated[str | None, Header()] = None,
) -> None:
  """Validate the optional deployment-wide shared secret.

  Local development may leave the server secret unset. Any network-exposed
  deployment should set it or replace this dependency with user authentication.
  """

  configured = settings.app_shared_secret
  if configured is None:
    return

  provided = x_app_secret or ""
  if not secrets.compare_digest(configured.get_secret_value(), provided):
    raise HTTPException(
      status_code=status.HTTP_401_UNAUTHORIZED,
      detail="Invalid app credential",
    )
