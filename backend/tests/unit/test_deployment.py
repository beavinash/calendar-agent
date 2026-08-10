"""Container and Railway deployment contract tests."""

import json
from pathlib import Path


def test_docker_uses_platform_port_with_local_fallback() -> None:
  """The container is production-safe and honors Railway's injected port."""

  backend_root = Path(__file__).parents[2]
  dockerfile = (backend_root / "Dockerfile").read_text(encoding="utf-8")

  assert "ENV ENVIRONMENT=production" in dockerfile
  assert "${PORT:-8000}" in dockerfile


def test_docker_context_excludes_local_secrets_and_artifacts() -> None:
  """A remote Docker builder must not receive local secrets or caches."""

  backend_root = Path(__file__).parents[2]
  dockerignore = (backend_root / ".dockerignore").read_text(encoding="utf-8")

  assert ".env*" in dockerignore
  assert "!.env.example" in dockerignore
  assert ".venv/" in dockerignore
  assert "__pycache__/" in dockerignore
  assert ".pytest_cache/" in dockerignore
  assert ".mypy_cache/" in dockerignore
  assert ".ruff_cache/" in dockerignore


def test_railway_uses_dockerfile_and_public_health_endpoint() -> None:
  """Railway deployment metadata matches the FastAPI liveness route."""

  backend_root = Path(__file__).parents[2]
  config = json.loads(
    (backend_root / "railway.json").read_text(encoding="utf-8")
  )

  assert config["build"] == {
    "builder": "DOCKERFILE",
    "dockerfilePath": "Dockerfile",
  }
  assert config["deploy"]["healthcheckPath"] == "/api/v1/health"
