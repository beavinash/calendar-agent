"""Agent turn endpoint."""

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, status
from starlette.requests import Request

from app.api.dependencies import get_agent_service
from app.core.exceptions import (
  BYOKNotAllowedError,
  InvalidPlanningRequestError,
  LLMAuthenticationError,
  LLMConfigurationError,
  LLMProviderError,
)
from app.core.security import require_app_secret
from app.schemas.agent import AgentTurnRequest, AgentTurnResponse
from app.services.agent_service import AgentService

router = APIRouter(prefix="/agent", tags=["agent"])
logger = logging.getLogger(__name__)


@router.post(
  "/turn",
  response_model=AgentTurnResponse,
  dependencies=[Depends(require_app_secret)],
)
async def create_agent_turn(
  payload: AgentTurnRequest,
  http_request: Request,
  service: Annotated[AgentService, Depends(get_agent_service)],
  x_ai_api_key: Annotated[
    str | None,
    Header(max_length=512),
  ] = None,
) -> AgentTurnResponse:
  """Return coaching and calendar proposals without executing them."""

  try:
    return await service.create_turn(payload, x_ai_api_key)
  except BYOKNotAllowedError as error:
    raise HTTPException(
      status_code=status.HTTP_403_FORBIDDEN,
      detail="Runtime provider keys are disabled",
    ) from error
  except InvalidPlanningRequestError as error:
    raise HTTPException(
      status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
      detail=str(error),
    ) from error
  except LLMAuthenticationError as error:
    logger.warning(
      "Agent provider request failed; request_id=%s category=%s",
      http_request.state.request_id,
      error.failure_category,
    )
    status_code = (
      status.HTTP_401_UNAUTHORIZED
      if x_ai_api_key
      else status.HTTP_502_BAD_GATEWAY
    )
    raise HTTPException(
      status_code=status_code,
      detail="The model provider rejected its credential",
    ) from error
  except LLMConfigurationError as error:
    raise HTTPException(
      status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
      detail="The requested model provider is not configured",
    ) from error
  except LLMProviderError as error:
    logger.warning(
      "Agent provider request failed; request_id=%s category=%s",
      http_request.state.request_id,
      error.failure_category,
    )
    raise HTTPException(
      status_code=status.HTTP_502_BAD_GATEWAY,
      detail="The model provider request failed",
    ) from error
