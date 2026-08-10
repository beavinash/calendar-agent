"""Authenticated hosted-backend status endpoint."""

from typing import Annotated

from fastapi import APIRouter, Depends

from app.core.config import Settings, get_settings
from app.core.security import require_app_secret
from app.schemas.agent import BackendStatusResponse

router = APIRouter(tags=["status"])


@router.get(
  "/status",
  response_model=BackendStatusResponse,
  dependencies=[Depends(require_app_secret)],
)
async def status(
  settings: Annotated[Settings, Depends(get_settings)],
) -> BackendStatusResponse:
  """Report safe configuration without contacting OpenAI or persistence."""

  return BackendStatusResponse(
    model=settings.openai_model,
    byok_enabled=settings.allow_byok,
    audit_persistence_enabled=settings.audit_persistence_enabled,
  )
