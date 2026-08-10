FROM python:3.11-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app
ENV ENVIRONMENT=production

COPY pyproject.toml uv.lock* ./
RUN uv sync --frozen --no-dev --no-install-project

COPY README.md ./
COPY alembic.ini ./
COPY alembic ./alembic
COPY app ./app
RUN uv sync --frozen --no-dev

EXPOSE 8000
CMD ["sh", "-c", "exec uv run uvicorn app.main:app --host 0.0.0.0 --port \"${PORT:-8000}\""]
