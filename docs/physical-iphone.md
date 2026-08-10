# Run Mark-1 on a physical iPhone

The physical iPhone build can be used away from the development Mac on Wi-Fi
or cellular. Apple Calendar reading, local history, completion choices,
conflict checks, and confirmed EventKit writes happen on the phone. AI coach
turns require the persistent Railway HTTPS service described in
[deployment.md](deployment.md).

"Anywhere" does not mean autonomous background execution or offline OpenAI.
When the network is unavailable, the app must keep local Calendar data usable,
show a clear AI connection error, and recover after connectivity returns.

## Feasibility and chosen design

Running on a physical iPhone from any network is possible. Running the current
OpenAI coach safely with no backend at all is not the supported design because
an API key shipped to the app is a recoverable bearer secret with direct cost
exposure. Apple Calendar itself does not need a backend: EventKit continues to
read, validate, and write only on the phone.

| Approach | What works | Why it is or is not used |
| --- | --- | --- |
| Direct OpenAI call from iOS | No service to operate | Rejected for this build: it puts a billable provider credential on the phone and removes server-enforced model and BYOK policy. |
| Backend on the development Mac | Useful for simulator and short device tests | Not an anywhere/anytime service: the Mac, network route, and process must stay awake and reachable. LAN addresses and temporary tunnels are not durable production endpoints. |
| Stateless persistent HTTPS backend | Keeps the OpenAI key and fixed model off-device; works over Wi-Fi and cellular | Chosen. It requires a small hosted service, but no hosted database or calendar integration. |

The backend is therefore a narrow OpenAI gateway, not the source of truth for
the app. If Railway is temporarily unavailable, existing Calendar data and
local progress remain on the iPhone; only new AI analysis is unavailable.

## Before connecting the phone

1. Deploy and verify the hosted backend.
2. Have its placeholder-shaped URL ready:
   `https://<your-railway-domain>/api/v1`.
3. Have `APP_SHARED_SECRET` available in a password manager. Do not store the
   OpenAI key on the phone.
4. In Xcode, open
   `ios/CalendarAgent/CalendarAgent.xcodeproj` and allow package/index
   preparation to finish.
5. In the CalendarAgent target's **Signing & Capabilities** tab, choose your
   Apple development team, keep automatic signing enabled, and replace the
   checked-in `com.example.calendaragent` identifier with a globally unique
   bundle identifier owned by that team.

Do not commit signing certificates, provisioning profiles, Apple credentials,
or a personal app secret.

## Prepare and install

1. Connect the unlocked iPhone to the Mac and trust the computer if prompted.
2. Enable Developer Mode on the iPhone if Xcode requests it, then complete the
   required device restart and confirmation.
3. Select the physical iPhone as the run destination for the
   `CalendarAgent` scheme.
4. Build and run from Xcode. Resolve signing errors in **Signing &
   Capabilities**; never work around them by embedding credentials in source.
5. Launch the app on the phone once while attached, then disconnect it and
   confirm it launches independently.

For command-line diagnosis, first copy the device identifier from Xcode's
**Devices and Simulators** window, then run:

```bash
xcodebuild \
  -project ios/CalendarAgent/CalendarAgent.xcodeproj \
  -scheme CalendarAgent \
  -configuration Debug \
  -destination 'platform=iOS,id=<device-udid>' \
  -allowProvisioningUpdates \
  build
```

This validates a signed build but Xcode remains the supported installation and
debugging interface. Direct development signing is for development. If the app
must remain conveniently installable without periodic Xcode work, choose a
deliberate TestFlight or App Store distribution workflow and complete the
corresponding Apple review, privacy, signing, and provisioning requirements.
Apple's free Personal Team provisioning profiles expire after seven days, so
that setup requires rebuilding and reinstalling the app periodically. See
[Apple's account overview](https://developer.apple.com/help/account/basics/about-your-developer-account).

## Connect the hosted backend

1. Tap the top-left gear, then open
   **Advanced settings > Hosted AI Backend**.
2. Enter the Railway URL in **Backend HTTPS URL**. The app normalizes an
   entered public HTTPS host/path to its `/api/v1` base path. Do not use
   `localhost`, `127.0.0.1`, a LAN-only Mac address, or plain HTTP on a
   physical device.
3. Enter only the **Deployment app secret**, then tap **Save app secret**. It
   is stored with device-only Keychain accessibility.
4. Tap **Verify secure connection**.
5. Confirm the success message is **Connected securely to the OpenAI
   backend.** The Provider row must read **OpenAI · server managed**, the Model
   row must show the server-selected model instead of **Configured by
   backend**, and Audit storage must read **Stateless** for this deployment.
6. In **AI Data Sharing**, enable
   **I consent to sending selected context**. AI requests are intentionally
   blocked until this explicit consent is enabled.
7. Optionally enable **Evening accountability prompts**.

The hosted app must not offer or send a provider API key. Provider and model
selection are fixed on the server so a modified client cannot select a more
expensive model with the deployment's OpenAI key.

If connection verification fails:

- **Invalid URL:** enter an absolute public `https://` Railway URL. The app
  supplies the canonical `/api/v1` path.
- **Cannot reach server:** verify cellular/Wi-Fi access, the Railway deployment,
  domain, and public health endpoint.
- **Unauthorized:** replace the iPhone's stored app secret with the current
  Railway value.
- **Provider unavailable:** inspect the request ID when shown, Railway service
  health, sanitized logs, OpenAI project status, usage limit, and billing
  state.
- **Wrong provider/model:** correct Railway variables; the phone must not
  override them.

## Grant Apple Calendar access

1. In app Settings, tap **Grant full Calendar access**.
2. Approve full access in the iOS permission sheet.
3. Confirm Settings reports **Full access** and identifies the normal default
   writable calendar for new events.

No second Apple Account, dedicated calendar, or invitation flow is required.
If access is denied or later revoked, open the app's page in iOS Settings,
restore full Calendar access, and foreground the app to refresh.

## Real-device acceptance

Complete these checks with non-sensitive test events before relying on the
app. Record pass/fail and the app/backend commit, but never record event titles
or credentials.

### Calendar authority and progress

- Launch and foreground refresh show the latest non-holiday Apple Calendar
  events.
- Today shows all current-day events without an artificial item cap.
- Complete and Incomplete persist and immediately update the selected row.
- An Incomplete timed event can be copied into the first safe slot later today,
  or tomorrow only when today has no fit.
- Repeating that copy action does not create a duplicate.
- Editing an event time in Apple Calendar appears after foreground refresh.
- Revoking Calendar access blocks analysis/writes clearly; restoring access
  recovers without creating a separate calendar.

### Review and scheduling safety

- Analyze Today, Last Week, and Last Month over realistic test data.
- A review is useful even with no events or partial first-use history.
- Suggestions remain inert until the one explicit confirmation button is
  tapped.
- A valid confirmed batch adds exactly seven conflict-free events to the
  current default writable Apple Calendar.
- A new conflict introduced in Apple Calendar before confirmation causes the
  app to fail safely instead of overwriting or double-booking.
- External Calendar edits remain authoritative.

### Network and authentication

- Verify the backend and run a review over Wi-Fi.
- Disable Wi-Fi and repeat over cellular.
- Enable airplane mode: local Calendar data remains available and the AI turn
  shows a useful error.
- Disable airplane mode and confirm the next request recovers without
  reinstalling or clearing local state.
- Store an intentionally wrong app secret and confirm a distinct
  authentication failure, then restore the correct value.
- Rotate the Railway app secret and confirm the old value stops working.

## Logs for diagnosis

Use Xcode's device console while reproducing a failure. Share only request IDs,
HTTP status, error domain/code, counts, and validation rule names. Never share
or screenshot chat text, Calendar titles, notes, locations, attendees, raw
identifiers, headers, request bodies, the backend URL if private, or secrets.
