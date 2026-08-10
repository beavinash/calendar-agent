"""FastAPI application entry point."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.router import router
from app.core.config import get_settings
from app.core.request_id import request_id_middleware

settings = get_settings()
app = FastAPI(
  title="Mark-1 API",
  version="0.1.0",
  docs_url="/docs" if settings.environment != "production" else None,
  redoc_url=None,
)
app.middleware("http")(request_id_middleware)
app.add_middleware(
  CORSMiddleware,
  allow_origins=settings.cors_origins,
  allow_credentials=False,
  allow_methods=["GET", "POST"],
  allow_headers=[
    "Content-Type",
    "X-AI-API-Key",
    "X-App-Secret",
    "X-Request-ID",
  ],
)
app.include_router(router, prefix=settings.api_v1_prefix)
