# Walkthrough — local `/clear` fresh start

## 1. Delivery summary

The approved local-history reset scope is implemented. Mark-1 now recognizes
`/clear`, `/clear week`, and `/clear month` before consent or provider dispatch,
requires destructive confirmation, deletes only the documented local analysis
evidence, preserves Apple Calendar and safety records, excludes cleared periods
from later deterministic and AI-review evidence, and starts a fresh coach session
after success.

Reviewed base: `d3537a8a12518f067f02efa5e939b42e32e74495`

Reviewed implementation head: `c43eed4672009eb020c138bfa93bd78e94814a77`

Scope: iOS local state and Coach UI, related iOS tests, PRD, and README. The
reviewed snapshot contains 24 changed files, 1,822 insertions, 10 deletions, and
no uncommitted implementation work. This walkthrough was authored after that
snapshot was verified.

## 2. Changes in the diff

| Changed file and diff line(s) | Observed change | Relevant task |
| --- | --- | --- |
| `PRD.md`, new lines 1-128 | Records the approved behavior, acceptance criteria, and completed atomic backlog. | T001-T012 |
| `README.md`, new lines 63-93 | Documents all commands, exact local deletion boundary, preserved data, Apple Calendar non-mutation, cancellation, and provider-retention limits. | T012 |
| `ios/CalendarAgent/CalendarAgent/App/CalendarAgentApp.swift`, new lines 48-49 | Registers cleared-analysis intervals in the SwiftData schema. | T003 |
| `ios/CalendarAgent/CalendarAgent/Core/AnalysisEvidencePolicy.swift`, new lines 1-31 | Centralizes half-open cleared-interval filtering, including all-day occurrence assignment. | T007-T008 |
| `ios/CalendarAgent/CalendarAgent/Core/CoachCommand.swift`, new lines 1-226 | Adds exact command parsing, local-only dispatch, confirmation state, scoped disclosure, and deterministic feedback copy. | T001, T009, T011 |
| `ios/CalendarAgent/CalendarAgent/Core/CoachSessionController.swift`, new lines 43-48 | Adds explicit immediate session rotation after a confirmed reset. | T006 |
| `ios/CalendarAgent/CalendarAgent/Core/MissedEventInsight.swift`, new lines 209, 237-243, 461-466 | Removes cleared occurrences before deterministic missed-event aggregation. | T007 |
| `ios/CalendarAgent/CalendarAgent/Models/CalendarEventCompletion.swift`, new lines 13, 20, 26, 50, 84-86, 94 | Persists optional event occurrence timestamps for reliable scoped deletion. | T004 |
| `ios/CalendarAgent/CalendarAgent/Models/ClearedAnalysisInterval.swift`, new lines 1-32 | Persists exact cleared week/month intervals. | T003 |
| `ios/CalendarAgent/CalendarAgent/Services/AppSettings.swift`, new line 81 and lines 186-191 | Makes the tracking baseline externally read-only and adds a persisted restart operation. | T002 |
| `ios/CalendarAgent/CalendarAgent/Services/LocalCoachingHistoryResetCoordinator.swift`, new lines 1-42 | Freshly reads scoped EventKit occurrence keys and delegates only local deletion. | T005, T009 |
| `ios/CalendarAgent/CalendarAgent/Services/LocalCoachingHistoryResetService.swift`, new lines 1-176 | Implements transactional all/scoped deletion, rollback, interval persistence, preservation, and count-only logging. | T005 |
| `ios/CalendarAgent/CalendarAgent/ViewModels/CoachViewModel.swift`, new lines 60, 228-229, 286-294, 653-661 | Accepts cleared intervals, filters outbound review context, and clears transient generated state after reset. | T008, T010 |
| `ios/CalendarAgent/CalendarAgent/Views/Chat/CoachView.swift`, new lines 50-51, 60-61, 285-335, 575-576, 681-699, 713, 722-752 | Routes commands locally, presents accessible confirmation/feedback, confirms reset, rotates the session, and refreshes missed insight. | T009-T011 |
| `ios/CalendarAgent/CalendarAgent/Views/Progress/ProgressViewScreen.swift`, new line 290 | Stores occurrence time when saving completion evidence from Progress. | T004 |
| `ios/CalendarAgent/CalendarAgent/Views/Today/TodayView.swift`, new line 210 | Stores occurrence time when saving completion evidence from Today. | T004 |
| `ios/CalendarAgent/CalendarAgentTests/AppSettingsTests.swift`, new lines 46-68 | Verifies tracking-baseline restart survives settings recreation. | T002 |
| `ios/CalendarAgent/CalendarAgentTests/CalendarEventCompletionTests.swift`, new lines 94-115 | Verifies occurrence timestamps persist and update. | T004 |
| `ios/CalendarAgent/CalendarAgentTests/ClearedAnalysisIntervalTests.swift`, new lines 1-74 | Verifies previous completed week/month bounds, persistence, and time-zone behavior. | T003 |
| `ios/CalendarAgent/CalendarAgentTests/CoachCommandTests.swift`, new lines 1-149 | Verifies accepted/rejected syntax, local-only dispatch, no-op cancel, and honest scoped copy. | T001, T009, T011 |
| `ios/CalendarAgent/CalendarAgentTests/CoachSessionControllerTests.swift`, new lines 125-149 | Verifies explicit fresh-session rotation and stale background-transition cleanup. | T006 |
| `ios/CalendarAgent/CalendarAgentTests/CoachViewModelTests.swift`, new lines 184-212, 577-668, 1136-1189 | Verifies disabled-consent/provider bypass, cleared outbound context, and transient-state reset. | T008-T010 |
| `ios/CalendarAgent/CalendarAgentTests/LocalCoachingHistoryResetServiceTests.swift`, new lines 1-481 | Verifies all/scoped deletion, complete cancel preservation, legacy keys, idempotence, preserved safety data, and zero CalendarStore mutation calls. | T005, T009 |
| `ios/CalendarAgent/CalendarAgentTests/MissedEventInsightTests.swift`, new lines 86-120, 667-668, 676-677 | Verifies explicit and inferred misses inside cleared intervals are excluded while the half-open boundary remains eligible. | T007 |

## 3. Verification evidence

Full iOS suite, final committed implementation:

```text
$ make ios-test IOS_TEST_DESTINATION='platform=iOS Simulator,OS=26.5,name=DisciplineAgent Tests'
Test Suite 'CalendarAgentTests.xctest' passed at 2026-09-25 12:46:37.871.
     Executed 164 tests, with 0 failures (0 unexpected) in 0.796 (0.843) seconds
Test Suite 'All tests' passed at 2026-09-25 12:46:37.871.
     Executed 164 tests, with 0 failures (0 unexpected) in 0.796 (0.844) seconds
** TEST SUCCEEDED **
Exit status: 0
```

Full backend regression suite:

```text
$ make test
131 passed, 1 warning in 2.91s
Required test coverage of 85% reached. Total coverage: 91.57%
Exit status: 0
```

Static checks:

```text
$ make lint
All checks passed!
Success: no issues found in 53 source files
Exit status: 0
```

Formatting check:

```text
$ make format-check
53 files already formatted
Exit status: 0
```

Unsigned generic-device Release build:

```text
$ make ios-release-build
** BUILD SUCCEEDED **
Exit status: 0
```

Diff hygiene:

```text
$ git diff --check
Exit status: 0
```

Changed-file marker search:

```text
$ rg -n 'TODO|FIXME|HACK|@pytest\.mark\.skip' -- <all 24 changed files>
No matches.
Exit status: 1 (ripgrep no-match status)
```

No repository dependency-audit command exists in the Makefile or project
configuration. No model evaluation was run because the PRD identifies this as
deterministic local behavior with no AI-quality evaluation requirement.

## 4. Acceptance criteria

| Criterion | Status: met / unmet / unverified | Diff or execution evidence |
| --- | --- | --- |
| AC-001 — all three commands confirm locally without consent, persistence, or network | met | `CoachCommand.swift` new lines 31-112 and `CoachView.swift` new lines 681-699 route before `sendProviderMessage`; `CoachViewModelTests.swift:184` uses disabled consent and a fail-on-call provider client, then proves zero calls and zero chat records. |
| AC-002 — cancel changes no persisted or in-memory data | met | `LocalCoachingHistoryResetServiceTests.swift:144` seeds every resettable record category, records baseline/session, cancels, and proves all values unchanged; `CoachCommandTests.swift` also verifies confirmation state becomes empty. |
| AC-003 — `/clear` deletes all analysis data and advances baseline | met | Reset service new lines 13-94 and `LocalCoachingHistoryResetServiceTests.swift:332`; `AppSettingsTests.swift` new lines 46-68 verifies restoration. |
| AC-004 — week/month delete only the previous completed period and persist exclusion | met | Scope bounds in `CoachCommand.swift` new lines 3-20; mixed-date/legacy fixtures at `LocalCoachingHistoryResetServiceTests.swift:196` and month fixture at line 286; interval tests new lines 1-74. |
| AC-005 — notes, audits, safety links, preferences, credentials, and Apple Calendar are preserved | met | Preservation assertions are in reset-service tests new lines 196-384; the CalendarStore spy test at line 97 proves one fresh read and zero apply, automatic-apply, or undo calls. |
| AC-006 — cleared evidence is absent locally and from outbound AI context | met | `MissedEventInsightTests.swift:86` verifies deterministic filtering; `CoachViewModelTests.swift:577` captures the outbound request and verifies only uncleared events/groups remain. |
| AC-007 — accessible confirmation/success/error clearly preserve Apple Calendar | unverified | Copy assertions are at `CoachCommandTests.swift:79`; production identifiers exist at `CoachView.swift:306`, `:311`, and `:332`; all compile and pass the full suite. A hands-on Simulator/VoiceOver interaction was not performed, so the manual portion remains unverified. |
| AC-008 — public documentation describes boundaries | met | README new lines 63-93 documents exact deletions, preserved data, cancellation, Apple Calendar non-mutation, and provider limits; changed-file marker search found no markers. |

## 5. Limitations

- AC-007's manual Simulator/VoiceOver inspection was not performed. Automated
  copy assertions, accessibility identifiers, and build/test evidence are present,
  but a person should still exercise confirmation, success, and failure alerts on
  a Simulator or physical iPhone with VoiceOver.
- The repository has no dependency-audit command, so dependency vulnerability
  scanning was not run.
- Backend tests emit one third-party deprecation warning from
  `google/genai/types.py` under Python 3.14; all 131 tests still pass and this
  sprint does not modify that dependency.
- No TODO, FIXME, HACK, or pytest skip markers were found in changed files. No AI
  model evaluation applies to this deterministic local reset behavior.
