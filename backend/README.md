# Backend

The FastAPI backend turns minimized device context into typed, non-executing
calendar proposals. It uses PostgreSQL only for metadata-level operational
auditing and never stores prompts, event details, notes, or provider keys.

```bash
cp .env.example .env
uv sync --extra dev --extra test
uv run alembic upgrade head
uv run uvicorn app.main:app --reload
```

OpenAPI is available at `http://localhost:8000/docs` in development.
