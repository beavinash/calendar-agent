# Production acceptance and rollback checklist

Use this checklist for the stateless personal Railway/OpenAI deployment and a
signed physical-iPhone build. The automated portion is required before every
hosted release. The credential- and device-dependent portions must be run by
the operator.

## Automated acceptance

Run from the repository root:

```bash
git status --short
git diff --check

make setup
make test
make lint
make format-check
make docker-smoke
make ios-build

xcrun simctl list devices available
make ios-test \
  IOS_TEST_DESTINATION='platform=iOS Simulator,id=<available-simulator-udid>'

make ios-release-build
```

Confirm:

- backend coverage remains at least 85%;
- Ruff check, Ruff format check, and mypy strict pass;
- simulator tests and unsigned generic-device Release build pass;
- the backend Docker image builds;
- `git diff --check` is clean;
- no `.env`, provider key, app secret, Apple credential, Calendar content, or
  personal note is tracked.

`make format-check` and `make ios-release-build` do not reformat source or
change signing configuration. They can create ignored caches, build products,
or DerivedData.

## Pre-deployment

- [ ] Record the candidate Git commit and the current known-good Railway
      deployment.
- [ ] Review the diff for calendar-write boundary changes.
- [ ] Confirm EventKit remains the only Calendar writer.
- [ ] Confirm Railway Root Directory is `/backend` and Config File Path is
      `/backend/railway.json`.
- [ ] Confirm `ENVIRONMENT=production`.
- [ ] Confirm `ALLOW_BYOK=false`.
- [ ] Confirm `AUDIT_PERSISTENCE_ENABLED=false` and `CORS_ORIGINS=[]`.
- [ ] Confirm `OPENAI_API_KEY`, `OPENAI_MODEL`, and `APP_SHARED_SECRET` are set
      in Railway and absent from Git/Xcode files.
- [ ] Confirm no `DATABASE_URL` or Railway PostgreSQL service is attached to
      the stateless personal deployment.
- [ ] Confirm OpenAI project usage limits and billing alerts.
- [ ] Confirm the Release/hosted app uses a public HTTPS `/api/v1` endpoint,
      never phone loopback.

## Hosted-backend acceptance

- [ ] Railway reports a healthy deployment.
- [ ] `GET /api/v1/health` returns HTTP 200 over HTTPS.
- [ ] Missing app credentials receive HTTP 401.
- [ ] Incorrect app credentials receive HTTP 401.
- [ ] Authenticated `GET /api/v1/status` reports service status, provider
      `openai`, the configured model, BYOK disabled, and audit persistence
      disabled.
- [ ] Status returns neither provider nor app secrets.
- [ ] One authenticated coach turn succeeds with a request ID.
- [ ] Provider timeout, rate-limit, and upstream failures return sanitized
      errors with no secret or user content.
- [ ] Railway proxy and application logs contain no headers, bodies, chat
      text, Calendar titles, event details, notes, or secrets.
- [ ] Restarting or replacing the container does not require a database and
      the service becomes healthy again.

## Physical-iPhone acceptance

- [ ] Signing team and bundle identifier belong to the operator.
- [ ] The signed app installs and launches after disconnecting from the Mac.
- [ ] Hosted backend URL and app secret verify successfully.
- [ ] Verification reports the server-selected OpenAI model.
- [ ] Full Calendar access can be granted, revoked, restored, and refreshed.
- [ ] Today, Last Week, and Last Month work over Wi-Fi and cellular.
- [ ] Airplane mode gives a useful error and requests recover afterward.
- [ ] A wrong or rotated app secret gives a distinct authentication failure.
- [ ] Complete/Incomplete and conflict-free Incomplete carryover work on real
      test events without duplication.
- [ ] Seven suggestions remain inert until one explicit confirmation, then add
      exactly seven safe events.
- [ ] A last-moment Calendar conflict fails closed.
- [ ] External Apple Calendar edits appear after foreground refresh.

Use [physical-iphone.md](physical-iphone.md) for the full procedure.

## Release decision

Release only when all applicable automated, hosted, and phone checks pass.
Record:

- Git commit;
- Railway deployment identifier;
- app build/version;
- test date and pass/fail summary;
- request IDs for failures, without request content.

Do not record credentials, user text, Calendar data, or OpenAI payloads.

## Rollback triggers

Roll back when any of these occurs:

- the service cannot become or remain healthy;
- authentication accepts a missing/wrong secret or rejects the correct one;
- secrets or sensitive request content appear in logs or responses;
- the server uses a client-selected provider/model;
- Calendar context exceeds the documented consent boundary;
- confirmed proposals bypass live on-device validation;
- the app creates incorrect, conflicting, duplicate, or untracked Calendar
  events;
- provider failures are not sanitized or cause repeated uncontrolled spend.

## Backend rollback

1. Disable the affected Railway deployment or redeploy the recorded
   known-good deployment.
2. Wait for `/api/v1/health` to return HTTP 200.
3. Repeat missing, wrong, and correct credential checks.
4. Repeat authenticated status and one minimal coach turn.
5. Inspect logs for sensitive content.
6. If exposure is possible, rotate the app secret and OpenAI key using
   [deployment.md](deployment.md).

The stateless backend has no user database to restore. Never delete or rewrite
Apple Calendar events during a backend rollback.

## iPhone rollback

1. Stop distributing the affected build.
2. Reinstall or redistribute the last known-good signed build without changing
   its bundle identifier when preserving the app container is required.
3. Re-enter the hosted URL or app secret only if the rollback requires it.
4. Repeat backend verification, Calendar permission, foreground refresh, and
   one safe test-event flow.
5. Inspect Apple Calendar directly. Remove only incorrect events that the user
   recognizes or that carry the agent ownership marker; never bulk-delete
   arbitrary events.

Reinstalling an app can remove local SwiftData and Keychain state depending on
the installation path. Do not use uninstall/reinstall as the first rollback
step when local Complete/Incomplete history must be preserved.
