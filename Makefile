.PHONY: setup docker-up docker-down dev dev-lan test test-cov lint \
	format-check format migrate migrate-create docker-build docker-smoke ios-build ios-test \
	ios-release-build clean

DERIVED_DATA_PATH := $(CURDIR)/.derived-data
IOS_TEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro

setup:
	cd backend && uv sync --extra dev --extra test

docker-up:
	docker compose up -d postgres

docker-down:
	docker compose down

dev:
	cd backend && uv run uvicorn app.main:app --reload --host 127.0.0.1 --port 8000

dev-lan:
	cd backend && uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

test:
	cd backend && uv run pytest

test-cov:
	cd backend && uv run pytest --cov-report=html --cov-report=term-missing

lint:
	cd backend && uv run ruff check app tests
	cd backend && uv run mypy app tests

format-check:
	cd backend && uv run ruff format --check app tests

format:
	cd backend && uv run ruff format app tests
	cd backend && uv run ruff check --fix app tests

migrate:
	cd backend && uv run alembic upgrade head

migrate-create:
	cd backend && uv run alembic revision --autogenerate -m "$(MSG)"

docker-build:
	docker build -t calendar-agent-backend:local backend

docker-smoke: docker-build
	@set -eu; \
		container_id=$$(docker run --rm -d -e PORT=18765 \
			-e ENVIRONMENT=development \
			-p 127.0.0.1::18765 calendar-agent-backend:local); \
		trap 'docker stop "$$container_id" >/dev/null 2>&1 || true' EXIT INT TERM; \
		health_url="http://$$(docker port "$$container_id" 18765/tcp)/api/v1/health"; \
		attempt=0; \
		until curl --fail --silent --show-error \
			"$$health_url" >/dev/null; do \
			attempt=$$((attempt + 1)); \
			if [ "$$attempt" -ge 30 ]; then \
				docker logs "$$container_id"; \
				exit 1; \
			fi; \
			sleep 1; \
		done

ios-build:
	xcodebuild -project ios/CalendarAgent/CalendarAgent.xcodeproj \
		-scheme CalendarAgent -sdk iphonesimulator -configuration Debug \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		CODE_SIGNING_ALLOWED=NO build

ios-test:
	xcodebuild -project ios/CalendarAgent/CalendarAgent.xcodeproj \
		-scheme CalendarAgent -destination '$(IOS_TEST_DESTINATION)' \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		CODE_SIGNING_ALLOWED=NO test

ios-release-build:
	xcodebuild -project ios/CalendarAgent/CalendarAgent.xcodeproj \
		-scheme CalendarAgent -configuration Release \
		-destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		CODE_SIGNING_ALLOWED=NO build

clean:
	cd backend && rm -rf .pytest_cache .mypy_cache .ruff_cache htmlcov .coverage
	rm -rf $(DERIVED_DATA_PATH)
