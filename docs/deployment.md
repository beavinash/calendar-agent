# Stateless Railway and OpenAI deployment

This is the supported hosted deployment for the personal iPhone build. Railway
runs the FastAPI container continuously and terminates public HTTPS. The iPhone
keeps Apple Calendar access and every EventKit write; the service receives only
the minimized context authorized for a coach turn and calls OpenAI with a
server-managed key.

This deployment is intentionally stateless. Do not add Railway PostgreSQL for
the personal build. Losing or replacing the container cannot remove Apple
Calendar events, completion choices, or other on-device state.

## Security boundary

```text
Physical iPhone
  EventKit / SwiftData / Keychain
       |
       | HTTPS + X-App-Secret
       v
Railway FastAPI service
       |
       | server-managed OPENAI_API_KEY
       v
OpenAI Responses API (structured output, store=false)
```

The iPhone never stores or sends `OPENAI_API_KEY`. In production, the backend
uses only the operator-configured OpenAI model and rejects BYOK. The deployment
credential in `X-App-Secret` protects this one-person service from casual
public use; it is not an account system and must not be reused elsewhere.

## Prerequisites

- a Git repository containing this project that Railway can access
- a Railway account with access to that repository
- an OpenAI project key created for this service
- OpenAI usage limits and billing alerts appropriate for a personal app
- a generated app secret of at least 32 random bytes

Generate the app secret locally without committing it or pasting its output
into chat:

```bash
openssl rand -base64 48
```

Store the output directly in Railway and later in the app's Keychain-backed
field. Do not put it in a tracked file, Xcode build setting, screenshot, or
support log.

## Create the Railway service

1. In Railway, create a project from the Git repository.
2. Create one service and set its **Root Directory** to `/backend`.
3. In the service settings, set **Config File Path** explicitly to
   `/backend/railway.json`. Railway does not resolve the config file relative
   to the service Root Directory automatically. The config builds the
   `Dockerfile` in that service root (`backend/Dockerfile` in this repository)
   and uses `/api/v1/health` for the public health check.
4. Do not add a PostgreSQL service. Audit persistence is disabled for this
   stateless personal deployment.
5. Add the variables below. Mark both secrets as sensitive in Railway.
6. Deploy, then generate one Railway public domain. Use only the resulting
   `https://*.up.railway.app` URL. The service's
   `*.railway.internal` name is private and cannot be reached from an iPhone.

Railway injects `PORT`; do not set or hard-code it yourself. If a public
domain asks for a target port, use the actual listening port reported by the
deployment rather than guessing `8000` or `8080`.

| Variable | Required value |
| --- | --- |
| `ENVIRONMENT` | `production` |
| `OPENAI_API_KEY` | The dedicated OpenAI project key; secret |
| `OPENAI_MODEL` | One operator-approved model supported by this backend |
| `APP_SHARED_SECRET` | The generated random deployment credential; secret |
| `ALLOW_BYOK` | `false` |
| `AUDIT_PERSISTENCE_ENABLED` | `false` |
| `CORS_ORIGINS` | `[]` |

Do not define `DATABASE_URL` for this stateless deployment. Keep all optional
provider keys unset. Production startup is expected to fail closed when a
required secret is missing, the model is empty, or BYOK is enabled. Set
`OPENAI_MODEL` explicitly so deployment behavior does not depend on a code
default.

The Docker image itself defaults to `ENVIRONMENT=production`, so omitting the
Railway variable cannot silently expose an unauthenticated development
service. Keep the explicit Railway value as a visible deployment assertion;
an unknown or misspelled environment value also fails validation.

## Smoke test

Set only the non-secret service origin in your shell. In the iPhone app, the
backend URL field normalizes an entered public HTTPS host/path to the service's
`/api/v1` base path.

```bash
export CALENDAR_API_ORIGIN="https://<your-railway-domain>"
curl --fail-with-body \
  "$CALENDAR_API_ORIGIN/api/v1/health"
```

Expected: HTTP 200 with service liveness only. Health is public and does not
test OpenAI credentials. A `404 Not Found` response at the bare domain root
is expected because the API is mounted under `/api/v1`.

The protected status endpoint is `GET /api/v1/status`. Without
`X-App-Secret`, it must return HTTP 401:

```bash
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "$CALENDAR_API_ORIGIN/api/v1/status")" = "401"
```

A deliberately incorrect placeholder credential must also return HTTP 401:

```bash
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H 'X-App-Secret: intentionally-wrong' \
  "$CALENDAR_API_ORIGIN/api/v1/status")" = "401"
```

Next, open **Settings > Advanced settings > Hosted AI Backend**, enter the
Railway HTTPS URL in **Backend HTTPS URL**, save the matching **Deployment app
secret**, and tap **Verify secure connection**. The authenticated check sends
only `X-App-Secret`, with no chat or Calendar content. The response must have
this shape, with the configured model substituted:

```json
{
  "status": "ok",
  "service": "calendar-agent",
  "provider": "openai",
  "model": "<approved-openai-model>",
  "byok_enabled": false,
  "audit_persistence_enabled": false
}
```

Before accepting the deployment, also verify:

- a missing or deliberately incorrect app secret is rejected with HTTP 401;
- the correct secret passes the authenticated connection check;
- one minimal coach turn succeeds;
- the response contains a request ID on a provider or network failure;
- Railway access/application logs contain no headers, bodies, chat text,
  calendar titles, event details, or secrets.

Do not paste a secret directly into a reusable `curl` command: shell history,
debug tracing, and process inspection can expose it. The app's Keychain-backed
connection test is the normal authenticated smoke test.

If audit persistence is deliberately enabled later, set
`AUDIT_PERSISTENCE_ENABLED=true`, configure `DATABASE_URL`, provision
PostgreSQL, and run Alembic migrations before accepting traffic. That is a
different deployment mode and is not required for this personal iPhone app.

## Operations

### Deploy an update

1. Complete the automated checks in
   [production-checklist.md](production-checklist.md).
2. Record the current successful Railway deployment and Git commit.
3. Deploy the new commit.
4. Repeat health, authentication, status, log-redaction, and one-turn checks.
5. Complete the physical-iPhone checks affected by the change.

Deploy the backend before installing an app version that adds request fields.
The review-count capability is backward-compatible: an older app that omits
it continues receiving five suggestions, while the current app requests seven.

### Rotate the app secret

1. Generate a new random secret.
2. Replace `APP_SHARED_SECRET` in Railway and wait for a healthy deployment.
3. Replace the stored app secret on the iPhone.
4. Verify the backend connection.
5. Confirm the old secret now receives HTTP 401.

There is a short interruption between steps 2 and 3 because this personal
deployment supports one active app secret.

### Rotate the OpenAI key

1. Create a replacement key in the same restricted OpenAI project.
2. Replace `OPENAI_API_KEY` in Railway and wait for a healthy deployment.
3. Verify status and one coach turn from the iPhone.
4. Revoke the old key and inspect OpenAI usage for unexpected activity.

Never copy the OpenAI key to the iPhone during rotation.

### Roll back

Use Railway's deployment history to redeploy the last known-good commit, then
repeat the smoke tests. A backend rollback cannot undo or delete Apple Calendar
events because calendar execution never leaves the device. Follow the complete
procedure in [production-checklist.md](production-checklist.md).
