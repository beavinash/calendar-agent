# Security and Privacy

Calendar entries in Work, Study, Exercise, Appointments, and Errands, along
with chat and note data, are sensitive. The system follows data minimization
by default.

## Provider and deployment keys

The supported hosted iPhone build uses `OPENAI_API_KEY` only in Railway. The
iOS binary, plist, xcconfig, settings storage, and Keychain contain no OpenAI
key. Production fixes the provider to OpenAI and the model to `OPENAI_MODEL`,
requires `ALLOW_BYOK=false`, and ignores client provider/model selection.

The iPhone stores a separate `APP_SHARED_SECRET` with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and sends it only over HTTPS.
This credential protects one personal deployment; it is not suitable as a
multi-user identity system. Public distribution requires accounts,
per-user/device authorization, revocation, abuse controls, and a separate
security design.

The OpenAI adapter disables provider application-state storage with
`store=false`. Provider safety/abuse retention can still apply unless the
OpenAI project has the appropriate controls. This remains a third-party AI
disclosure: the app requires explicit consent and sends only the bounded
context for that request.

Development-only provider pluggability does not weaken hosted mode. Production
startup fails when the OpenAI key, fixed model, or app secret is missing, or
when BYOK is enabled.

## Calendar data

- Full EventKit access is required to read events; iOS does not provide a
  read-only EventKit authorization tier.
- After permission, the app can read events visible across Apple Calendar. It
  does not require a dedicated calendar or treat a calendar category as a
  calendar name.
- Planning context includes only the minimum start/end, all-day state, and
  opaque identifiers needed to find safe time.
- An explicit Today, Last Week, or Last Month review may include event titles,
  times, and the user's Complete/Incomplete choice for the selected period.
  Locations, notes, attendees, account details, raw EventKit identifiers, and
  credentials are omitted.
- That explicit review also includes a bounded ranked missed-pattern summary.
  The summary contains display titles and aggregate counts, never occurrence
  timestamps or Calendar identifiers. Scheduling-only turns remain
  title-free.
- Model context is sent only after explicit third-party AI consent.
- The current visible workflow sends no notes to the model.
- The model never receives iCloud credentials or direct Calendar access.

## Calendar writes

- Requesting a review never writes to Calendar.
- A valid review returns exactly seven suggestions or none. Only the explicit
  **Add 7 to Apple Calendar** confirmation authorizes that exact batch.
- Proposals are untrusted input, even when schema-valid.
- Backend and device both check count, time bounds, duration, protected meal
  windows, and overlaps. iOS refreshes EventKit immediately before applying.
- Each write resolves the device's normal default writable calendar; there is
  no dedicated calendar, calendar-name rule, or fallback chosen by the model.
- Created events carry a marker and local audit record.
- Undo refuses to remove unmarked events.

Complete/Incomplete records are stored locally against privacy-safe event
keys, without duplicating event titles or times. Apple Calendar remains the
authoritative source for event content; edits made there replace stale display
data on the next app launch or foreground refresh.

## Operational controls

- Use the stateless Railway deployment in [deployment.md](deployment.md).
- Require `APP_SHARED_SECRET`, `OPENAI_API_KEY`, a non-empty fixed
  `OPENAI_MODEL`, `ALLOW_BYOK=false`, and HTTPS in production.
- Keep `AUDIT_PERSISTENCE_ENABLED=false` and do not attach PostgreSQL for the
  supported personal deployment.
- Use `CORS_ORIGINS=[]` for the native-only service.
- Configure bounded provider timeouts/retries, OpenAI usage limits, billing
  alerts, and Railway health checks.
- Rotate provider/app secrets and never commit `.env`, credentials, or a real
  hosted domain if it is intended to remain private.
- Logs contain request IDs and aggregate metadata only.
- Provide consent, authorization-revocation, and data-deletion controls before
  public distribution.

The deployment secret is a bearer credential. If it may have leaked, rotate it
immediately and confirm the old value receives HTTP 401. If the OpenAI key may
have leaked, replace it in Railway, verify one turn, revoke the old key, and
inspect usage. See [production-checklist.md](production-checklist.md).

Before App Store submission, complete Apple's privacy disclosures and obtain
explicit consent before sharing personal data with a third-party AI provider:
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
