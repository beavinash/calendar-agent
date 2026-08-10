# Mark-1 Engineering Rules

These are the standalone engineering rules for this repository.

## Product boundary

Mark-1 is a privacy-conscious iOS planning coach. The backend may
reason over a minimized snapshot, but Apple Calendar remains authoritative and
all calendar writes execute on-device through EventKit.

- Never let an LLM write directly to EventKit, CalDAV, or a database.
- Calendar changes are typed proposals and must be validated on-device. Apply
  them only after per-write confirmation or an explicit, revocable standing
  authorization for the device's normal default writable Apple Calendar.
- After full Calendar permission, Day/Week/Month review, Today, planning
  context, and conflict checks may read the existing events visible across
  Apple Calendar. Calendar categories are planning groupings, never calendar
  names or identifiers. Do not create or require a specially named calendar.
- Only edit or delete events marked as agent-owned.
- Do not add RAG, embeddings, vector databases, LangChain, LlamaIndex, Chroma,
  Pinecone, or FAISS.
- Do not expose chain-of-thought. Show concise rationale and action summaries.
- Do not present professional advice or unsupported claims. The product is a
  planning aid.

## Development workflow

- Document behavior changes in the relevant source documentation and tests.
- TDD is required. Backend coverage must remain at or above 85%.
- Use Conventional Commit messages. Do not add AI co-author attribution.
- Never commit `.env`, API keys, Apple credentials, calendar contents, or
  sensitive notes.

## Backend

- Python 3.11+, FastAPI, Pydantic 2, async SQLAlchemy, PostgreSQL 16, Alembic.
- Use UV, never pip.
- Keep the API -> service -> repository -> model layering.
- Use two-space indentation, 80-character lines, complete type hints, Google
  style docstrings, Ruff, and mypy strict.
- Use UUID primary keys and timezone-aware UTC timestamps.
- Use nullable `deleted_at` timestamps for soft deletion of database records.
- Keep LLM providers pluggable. Provider keys come from server environment or
  a per-request BYOK header explicitly enabled by the operator. Never persist,
  echo, or log provider keys.
- Do not log request bodies, chat text, notes, event titles, locations,
  attendees, or sensitive data.

## iOS

- SwiftUI, MVVM, async/await, iOS 17+.
- Use two-space indentation and keep lines near 100 characters.
- Put secrets and the installation identifier in Keychain with device-only
  accessibility. Never put secrets in `UserDefaults`, source, plist, or
  xcconfig files.
- Wrap EventKit, networking, and secure storage behind protocols so tests can
  use fakes.
- Planning context sent to the backend is a minimized snapshot of existing
  Apple Calendar events. Event titles leave the device only for an explicit
  Day, Week, or Month category-review turn with title-sharing consent.
- Surface errors; never use `try?` on calendar writes or secret storage.

## Commands

```bash
make setup
make docker-up
make dev
make test
make lint
make format
make ios-build
make ios-test
```
