# PRD — Local `/clear` fresh start

Status: Approved
Approval evidence: user confirmed the build on 2026-09-25 and explicitly required `/clear week` plus `/clear month` to delete their respective data.
Authoritative backlog: this document section 5

## 1. Problem and users

Mark-1 currently has no command for intentionally starting analysis over. Deleting
only Complete/Incomplete rows would not create a fresh start because ended,
unmarked Apple Calendar events would immediately be inferred as likely incomplete.
The user needs one explicit command that resets local coaching evidence without
deleting or editing anything in Apple Calendar.

## 2. Goals and scope

- Goals: `/clear`, `/clear week`, and `/clear month` provide truthful, confirmed
  deletion for their documented local analysis scope.
- Must-have scope: intercept all three commands entirely on-device; show scoped
  destructive confirmation; clear matching local chat history, daily reflections,
  completion choices, and pending calendar drafts; persist excluded historical
  intervals; clear transient coaching results; report success or failure accessibly.
- Later: custom date-range deletion.
- Non-goals: deleting or editing Apple Calendar events; deleting saved notes;
  deleting calendar-write audits or incomplete-reschedule safety links; changing
  settings, notification preferences, credentials, calendars, or provider data;
  adding a backend endpoint or invoking an LLM.

## 3. Requirements and constraints

- The normalized commands `/clear`, `/clear week`, and `/clear month` trigger a
  reset. Matching is case-insensitive and ignores surrounding whitespace.
- `/clear` means all local Mark-1 analysis history. `/clear week` means the
  immediately previous completed local calendar week. `/clear month` means the
  immediately previous completed local calendar month.
- Other suffixed or natural-language forms perform no deletion and show valid
  command usage.
- The command is handled before AI-consent, backend-URL, credential, message
  persistence, or network checks. Neither the command nor reset data leaves the
  device.
- Before mutation, a system confirmation must explain every deleted category and
  explicitly state what remains unchanged.
- Confirmed all-history reset deletes every `ChatMessageRecord`, `CheckInRecord`,
  `CalendarEventCompletionRecord`, `PendingCalendarProposalRecord`, and prior
  cleared-interval marker.
- Confirmed week/month reset deletes `ChatMessageRecord` plus `CheckInRecord`
  values whose timestamps are inside the exact half-open period `[start, end)`.
  It deletes completion choices belonging to event occurrences in that period.
  Every scoped reset clears all pending proposals because their evidence provenance
  is not persisted.
- Completion records gain an optional occurrence timestamp for reliable future
  range deletion. Existing records without it are matched against freshly read
  EventKit occurrence keys for the target interval.
- Each scoped reset persists its cleared interval so live EventKit history cannot
  be inferred again or sent as model-review evidence.
- Confirmed reset preserves every `NoteRecord`, `CalendarAuditRecord`,
  `IncompleteEventRescheduleRecord`, EventKit event, app preference, notification
  preference, installation identity, and credential.
- The all-history reset advances the persisted tracking baseline only after
  SwiftData deletion succeeds. Scoped resets leave the original tracking baseline
  intact. Any deletion failure must leave reset metadata unchanged and show an
  error.
- The all-history reset must replace prior cleared-period markers with one durable
  half-open exclusion ending at the confirmed reset timestamp. This cutoff is the
  authoritative fresh-start boundary after refresh or relaunch, even if an older
  tracking baseline is restored temporarily.
- Events whose scheduled occurrence predates the new tracking baseline remain
  visible in Apple Calendar and local calendar views, but are excluded from later
  missed-pattern evidence and AI review snapshots. Old titles or schedules must
  not influence post-reset model recommendations.
- Successful reset starts a new coach session, removes in-memory review/proposal/
  warning state, immediately discards the cached "Likely missed during the past 7
  days", previous-week, and previous-month insight presentation, refreshes only
  still-eligible missed-event evidence, and announces completion. `/clear week`
  must leave the previous completed week empty; `/clear month` must leave the
  previous completed month empty; `/clear` must exclude all pre-reset occurrences.
- The reset service must never call EventKit mutation APIs or a hosted backend.
- Logs may contain counts and result categories only; they must not contain chat,
  note, event-title, credential, or calendar content.
- Confirmation states that `/clear` removes local Mark-1 history only. It does not
  promise deletion from model-provider or infrastructure retention systems.
- This is deterministic local software behavior; no AI-quality evaluation applies.

## 4. Acceptance criteria and validation

| ID | Observable acceptance criterion | How to verify |
| --- | --- | --- |
| AC-001 | `/clear`, `/clear week`, and `/clear month` open scoped confirmation without AI consent, message persistence, or a network request. | Parser unit tests plus an integration test with disabled consent and a failing-on-call HTTP fake. |
| AC-002 | Cancelling confirmation changes no persisted or in-memory data. | UI/state test comparing all record counts, tracking baseline, and session identifier before and after cancel. |
| AC-003 | Confirming `/clear` deletes all chat, reflection, completion, and pending-draft records, then advances the persisted tracking baseline. | In-memory SwiftData service tests plus AppSettings restoration assertions. |
| AC-004 | Confirming week/month deletion removes only records in the previous completed period, clears every pending draft, then persists that excluded interval. | Time-zone-aware bounds tests plus mixed-date SwiftData fixtures including legacy completion keys. |
| AC-005 | Reset preserves notes, audit records, reschedule safety links, preferences, credentials, and all Apple Calendar events. | Preservation assertions plus a fake Calendar store proving zero write/delete/undo calls. |
| AC-006 | Cleared intervals produce no deterministic missed evidence or outbound AI review context while uncleared events remain eligible. | Deterministic insight tests plus captured outbound request assertions. |
| AC-007 | Confirmation, success, and error states are accessible and clearly say Apple Calendar was not changed. | Copy assertions, accessibility identifiers, and manual simulator inspection. |
| AC-008 | Public documentation describes the local deletion boundary and preserved data. | Marker search and documentation review. |
| AC-009 | After a confirmed clear, the Coach screen cannot display stale pre-clear rows while refreshed evidence is loading; `/clear` excludes all earlier occurrences, `/clear week` leaves the previous completed week analysis empty, and `/clear month` leaves the previous completed month analysis empty. | State-policy regression tests for all three scopes plus focused Coach reset tests. |
| AC-010 | Confirming `/clear` persists one all-history exclusion through the reset timestamp, removes every pre-reset occurrence from Today/Last Week/Last Month missed analysis after refresh or relaunch, then permits post-reset occurrences. | SwiftData reset-service regression plus deterministic boundary tests using a deliberately stale tracking baseline. |

Validation commands:

- Focused iOS tests through `xcodebuild` for the new parser, reset service,
  settings, session, insight, and coach-flow cases.
- Full suite: `make ios-test` and `make test`.
- Static checks: `make lint` and `make format-check`.
- Dependency scan: use the repository's existing dependency audit if present;
  otherwise record that no project command exists.
- Release verification: `make ios-release-build`.

## 5. Sprint backlog

Sprint: local-clear-fresh-start
Review base: `d3537a8a12518f067f02efa5e939b42e32e74495`
Corrective review base: `1cfb67b` (pre-fix fresh-start verification)
Review scope: iOS local state, related tests, README, and safety documentation

- [x] T001 | P0 | depends: none | AC-001 | Add the three-command local parser; done when parser tests accept only `/clear`, `/clear week`, and `/clear month` after normalization.
  Evidence: focused parser tests passed 3/3 and related intent regressions passed 9/9 on the iOS 26.5 simulator; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [x] T002 | P0 | depends: none | AC-003 | Add a persisted tracking-baseline restart operation; done when a new AppSettings instance restores the confirmed all-history reset timestamp.
  Evidence: the new restart test failed before implementation, then all 11 AppSettings tests passed on the iOS 26.5 simulator; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [x] T003 | P0 | depends: none | AC-004, AC-006 | Add persisted cleared-analysis intervals; done when exact previous-week and previous-month bounds survive relaunch across time-zone-aware fixtures.
  Evidence: the new interval tests failed before implementation, then interval persistence, DST-safe bounds, parser, and review-period regressions passed 11/11 on the iOS 26.5 simulator; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [x] T004 | P0 | depends: none | AC-004 | Persist the calendar occurrence timestamp on new completion choices; done when completion-store tests retain the occurrence used for scoped deletion.
  Evidence: the new occurrence test failed before implementation, then completion persistence and event-identity regressions passed 12/12 on the iOS 26.5 simulator; both Today and Progress writes now supply the occurrence time; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [x] T005 | P0 | depends: T002, T003, T004 | AC-003, AC-004, AC-005 | Add the local coaching-history reset service; done when mixed-date SwiftData tests prove scoped deletion plus preservation without EventKit mutation.
  Evidence: the new service tests failed before implementation, then 21 reset/settings/interval/completion tests passed on the iOS 26.3.1 simulator; fixtures cover all-history, previous-week, previous-month, half-open boundaries, legacy keys, idempotence, and preservation of notes/audits/reschedule links; the service has no EventKit mutation dependency; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [x] T006 | P1 | depends: none | AC-003 | Add an explicit fresh coach-session operation; done when tests prove immediate session rotation plus background-transition cleanup.
  Evidence: the new fresh-session test failed before implementation, then all 7 session lifecycle tests passed on the dedicated iOS 26.5 test simulator; persistence and background-transition cleanup are asserted; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [x] T007 | P0 | depends: T003 | AC-006 | Exclude cleared periods from local missed evidence; verified by 26 focused iOS tests covering explicit, inferred, half-open-boundary, and persisted-interval behavior.
- [x] T008 | P0 | depends: T003 | AC-006 | Exclude cleared periods from outbound review evidence; verified by captured requests containing only uncleared review events and missed-pattern groups.
- [x] T009 | P0 | depends: T001, T005, T006 | AC-001, AC-002, AC-003, AC-004 | Integrate scoped confirmation into coach submission; verified by local-only routing, destructive confirmation with no-op cancel, fresh scoped EventKit reads, all three reset scopes, and fresh-session rotation across 14 focused tests.
- [x] T010 | P1 | depends: T007, T008, T009 | AC-007 | Refresh reset-dependent coach presentation; verified by focused tests clearing in-memory drafts, review output, warnings, and errors while rotating the session and rebuilding deterministic insight.
- [x] T011 | P1 | depends: T009 | AC-007 | Surface accessible reset feedback; verified by scope-specific deterministic copy, system-alert announcement, local-only routing, and six focused presentation/state tests without a chat-record path.
- [x] T012 | P1 | depends: T010, T011 | AC-008 | Document local deletion boundaries; verified by README coverage of every command, exact periods, deleted/preserved data, Apple Calendar non-mutation, cancellation, and provider-retention limits.
- [x] T013 | P0 | depends: T010 | Clear cached missed-event presentation before post-reset refresh; verified by cache-state regressions for every reset scope, exact week/month exclusion tests, the 26-test insight suite, and the 166-test iOS suite.
- [x] T014 | P0 | depends: T013 | Persist the all-history fresh-start exclusion; verified by a red-first reset regression, a half-open all-history boundary test, fresh-context SwiftData restoration, stale-baseline protection, and 57 related tests passing on the dedicated iOS 26.5 simulator.

## 6. Open questions

None. The user approved the full reset and explicitly required truthful week/month
deletion. Saved notes, Apple Calendar events, settings, credentials, ownership
audits, and reschedule safety links remain preserved for every scope.
