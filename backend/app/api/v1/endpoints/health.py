"""Health endpoint."""

from fastapi import APIRouter

from app.schemas.agent import HealthResponse

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
  """Return process liveness without touching providers or user data."""

  return HealthResponse()
