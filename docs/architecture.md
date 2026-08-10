# Architecture

## Boundaries

The backend is a coach and planner, not a calendar service. After the user
grants permission, the iOS app reads a bounded EventKit snapshot from the
events visible in Apple Calendar. It sends only the context needed for the
requested Today, Last Week, Last Month, or planning action. The iOS app owns Calendar
permission, policy, and execution.

```text
iOS views -> view models -> CalendarStore / HTTPClient / SwiftData
                              |              |
                              |              v
                              |      HTTPS FastAPI endpoint
                              |              v
                              |        AgentService
                              |         /        \
                              |     OpenAI    No-op audit
                              v
                    EventKit / Apple Calendar
```

The supported personal Railway deployment is stateless and injects a no-op
audit writer. Optional PostgreSQL auditing remains available for a deliberately
configured deployment; it stores request ID, device UUID, provider/model,
proposal count, and timestamps only. It deliberately does not store chat,
notes, calendar titles, sensitive context, or provider keys.

## Hosted personal topology

The production iPhone calls one persistent Railway HTTPS service. It sends a
deployment credential from device-only Keychain, never an OpenAI key. Railway
holds `OPENAI_API_KEY`, fixes the OpenAI model from its environment, disables
BYOK, and calls the Responses API with structured output and `store=false`.
Production ignores client provider/model selection.

The public health endpoint reports process liveness. The authenticated status
endpoint verifies the app credential and reports only service status, fixed
provider/model, BYOK state, and audit-persistence state. Neither endpoint sends
calendar or chat context to OpenAI.

## App surface and lifecycle

The visible tab bar contains only **Mark-1** and **Progress**. Notes-related
code remains available for future work but is not exposed in the current UI or
included in coach requests. Mark-1's visible chat session gets a new identifier
after the app has spent five minutes in the background. SwiftData-backed
structured state is not deleted by that presentation reset.

On launch and every transition to the foreground, iOS asks EventKit for a
fresh view of the events visible in Apple Calendar. Today and Progress render
live event title, time, and calendar data. A privacy-safe local key joins each
event to its SwiftData Complete/Incomplete record; completion storage does not
duplicate the event title or time.

## Calendar categories and reviews

Work, Study, Exercise, Appointments, and Errands are neutral categories in the
coaching model. They are not names or identifiers of Apple calendars.
**Today** spans local midnight through the request time; **Last Week** and
**Last Month** are the immediately preceding completed local periods. A
registered tracking-start date distinguishes full, partial, and
before-tracking history.

Each review compares the events in that period with the selected calendar
categories. Review context may include event titles and times plus a bounded
ranked aggregation of likely missed patterns, but excludes locations,
attendees, event notes, raw EventKit identifiers, account details, and
credentials. Planning-only turns receive title-free availability.

A past calendar event is scheduled evidence only. A local Complete/Incomplete
choice is explicit completion evidence and is included in the bounded review
snapshot. The response reports represented and underrepresented categories,
conditional impact, confidence, and exactly seven safe suggestions or none.
Requesting the review cannot authorize an EventKit write.

The current app declares a seven-suggestion capability in each request. For a
safe backend-first rollout, an older app that omits that field retains its
legacy five-suggestion response and confirmation contract.

## Scheduling contract

The review result is inert until the user taps **Add 7 to Apple Calendar**.
That single confirmation applies the exact seven-item batch without another
model call. Each item contains a calendar category, title, start/end instants,
rationale, optional notes, and reminder offset. iOS refreshes EventKit and
repeats validation against live conflicts, weekday/weekend windows, duration,
and protected meal times before writing.

Events are saved to the device's normal default writable calendar. The
destination is resolved again at write time; no dedicated or specially named
calendar is required. Later user edits in Apple Calendar are authoritative and
are reflected by the next foreground refresh.

Edits and deletion of arbitrary user events are outside the MVP. Undo is
limited to events containing the agent ownership marker.

## Persistence

- Apple Calendar: authoritative calendar events.
- SwiftData: session-scoped chat history, check-ins, pending proposals, local
  Complete/Incomplete records, and local event audit. Notes code remains but is
  outside the current visible flow.
- PostgreSQL: optional privacy-minimized operational audit; disabled in the
  supported stateless personal deployment.
- Keychain: installation UUID and hosted deployment app secret. The production
  iPhone stores no provider key.

Direct context passing is intentional. There is no RAG or embedding index.
