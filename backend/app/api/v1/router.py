"""Versioned API router."""

from fastapi import APIRouter

from app.api.v1.endpoints import agent, health, status

router = APIRouter()
router.include_router(health.router)
router.include_router(status.router)
router.include_router(agent.router)
