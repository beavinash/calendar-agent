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
- Events whose scheduled occurrence predates the new tracking baseline remain
  visible in Apple Calendar and local calendar views, but are excluded from later
  missed-pattern evidence and AI review snapshots. Old titles or schedules must
  not influence post-reset model recommendations.
- Successful reset starts a new coach session, removes in-memory review/proposal/
  warning state, refreshes missed-event insight, and announces completion.
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
Review scope: iOS local state, related tests, README, and safety documentation

- [x] T001 | P0 | depends: none | AC-001 | Add the three-command local parser; done when parser tests accept only `/clear`, `/clear week`, and `/clear month` after normalization.
  Evidence: focused parser tests passed 3/3 and related intent regressions passed 9/9 on the iOS 26.5 simulator; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [x] T002 | P0 | depends: none | AC-003 | Add a persisted tracking-baseline restart operation; done when a new AppSettings instance restores the confirmed all-history reset timestamp.
  Evidence: the new restart test failed before implementation, then all 11 AppSettings tests passed on the iOS 26.5 simulator; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [x] T003 | P0 | depends: none | AC-004, AC-006 | Add persisted cleared-analysis intervals; done when exact previous-week and previous-month bounds survive relaunch across time-zone-aware fixtures.
  Evidence: the new interval tests failed before implementation, then interval persistence, DST-safe bounds, parser, and review-period regressions passed 11/11 on the iOS 26.5 simulator; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [x] T004 | P0 | depends: none | AC-004 | Persist the calendar occurrence timestamp on new completion choices; done when completion-store tests retain the occurrence used for scoped deletion.
  Evidence: the new occurrence test failed before implementation, then completion persistence and event-identity regressions passed 12/12 on the iOS 26.5 simulator; both Today and Progress writes now supply the occurrence time; `git diff --check` is clean; no project Swift dependency-audit command exists.
- [ ] T005 | P0 | depends: T002, T003, T004 | AC-003, AC-004, AC-005 | Add the local coaching-history reset service; done when mixed-date SwiftData tests prove scoped deletion plus preservation without EventKit mutation.
- [ ] T006 | P1 | depends: none | AC-003 | Add an explicit fresh coach-session operation; done when tests prove immediate session rotation plus background-transition cleanup.
- [ ] T007 | P0 | depends: T003 | AC-006 | Exclude cleared periods from local missed evidence; done when deterministic fixtures count only uncleared event occurrences.
- [ ] T008 | P0 | depends: T003 | AC-006 | Exclude cleared periods from outbound review evidence; done when request capture contains no cleared event title or timing.
- [ ] T009 | P0 | depends: T001, T005, T006 | AC-001, AC-002, AC-003, AC-004 | Integrate scoped confirmation into coach submission; done when cancel is a no-op while each confirmed command invokes its matching local reset.
- [ ] T010 | P1 | depends: T007, T008, T009 | AC-007 | Refresh reset-dependent coach presentation; done when stale generated state disappears after successful deletion.
- [ ] T011 | P1 | depends: T009 | AC-007 | Surface accessible reset feedback; done when deterministic scoped success or failure copy is announced without a persistent chat row.
- [ ] T012 | P1 | depends: T010, T011 | AC-008 | Document local deletion boundaries; done when public documentation accurately distinguishes every command's deleted data from preserved data.

## 6. Open questions

None. The user approved the full reset and explicitly required truthful week/month
deletion. Saved notes, Apple Calendar events, settings, credentials, ownership
audits, and reschedule safety links remain preserved for every scope.
