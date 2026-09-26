# Walkthrough — durable `/clear` fresh start

## 1. Delivery summary

The corrective fresh-start scope is complete. A confirmed `/clear` now persists
one all-history cutoff ending at reset time. Pre-reset Apple Calendar occurrences
cannot repopulate Today, Last Week, or Last Month missed analysis after refresh or
relaunch. Occurrences at or after reset remain eligible; Apple Calendar is unchanged.

Reviewed base: `1cfb67b`. Reviewed implementation head: `bfd9396`.

Scope: AC-010 and T014. The snapshot contains eight changed files, 98 insertions,
10 deletions, and no uncommitted implementation work.

## 2. Changes in the diff

| Changed file and diff line(s) | Observed change | Relevant task |
| --- | --- | --- |
| `PRD.md`, new 63-66, 97, 113, 135 | Defines the durable cutoff, AC-010, corrective base, and completion evidence. | T014 |
| `README.md`, new 71 | Documents the persistent post-clear cutoff. | T014 |
| `ios/CalendarAgent/CalendarAgent/Core/CoachCommand.swift`, new 21-28 | Resolves all reset scopes to half-open missed-analysis exclusions. | T014 |
| `ios/CalendarAgent/CalendarAgent/Core/MissedEventInsight.swift`, new 33-40 | Applies the all-history cutoff immediately in the insight cache. | T014 |
| `ios/CalendarAgent/CalendarAgent/Services/LocalCoachingHistoryResetService.swift`, new 32-41 | Persists the replacement all-history exclusion after clearing prior history. | T014 |
| `ios/CalendarAgent/CalendarAgentTests/ClearedAnalysisIntervalTests.swift`, new 41-59, 76-79, 86-88, 96-98 | Verifies the boundary and fresh-context restoration. | T014 |
| `ios/CalendarAgent/CalendarAgentTests/LocalCoachingHistoryResetServiceTests.swift`, new 372-379, 389-415 | Proves stale tracking state cannot restore pre-reset events while post-reset events remain eligible. | T014 |
| `ios/CalendarAgent/CalendarAgentTests/MissedEventInsightTests.swift`, new 144-149 | Verifies every scope installs its exclusion immediately. | T014 |

## 3. Verification evidence

Focused reset and Coach regressions:

```text
$ xcodebuild ... -only-testing:CalendarAgentTests/ClearedAnalysisIntervalTests -only-testing:CalendarAgentTests/MissedEventInsightTests -only-testing:CalendarAgentTests/LocalCoachingHistoryResetServiceTests -only-testing:CalendarAgentTests/CoachViewModelTests
Test Suite 'Selected tests' passed at 2026-09-25 18:00:20.291.
     Executed 57 tests, with 0 failures (0 unexpected) in 0.427 (0.443) seconds
** TEST SUCCEEDED **
Exit status: 0
```

Full iOS suite:

```text
$ make ios-test IOS_TEST_DESTINATION='platform=iOS Simulator,OS=26.5,name=DisciplineAgent Tests'
Test Suite 'All tests' passed at 2026-09-25 18:01:24.712.
     Executed 167 tests, with 0 failures (0 unexpected) in 0.728 (0.773) seconds
** TEST SUCCEEDED **
Exit status: 0
```

Backend regression suite:

```text
$ backend/.venv/bin/pytest backend/tests -q
........................................................................ [ 54%]
...........................................................              [100%]
Required test coverage of 85% reached. Total coverage: 93.22%
Exit status: 0
```

Static, formatting, and Release checks:

```text
$ backend/.venv/bin/ruff check backend/app backend/tests
All checks passed!
Exit status: 0

$ backend/.venv/bin/ruff format --check backend/app backend/tests
53 files already formatted
Exit status: 0

$ backend/.venv/bin/mypy backend/app backend/tests
backend/tests/unit/test_agent_service.py:191: error: Argument "suggested_events" to "LLMFocusReview" has incompatible type "list[LLMFocusEventSuggestion] | list[FocusEventSuggestion]"; expected "list[LLMFocusEventSuggestion]"  [arg-type]
Found 1 error in 1 file (checked 53 source files)
Exit status: 1

$ make ios-release-build
** BUILD SUCCEEDED **
Exit status: 0
```

Diff and marker audit:

```text
$ git diff --check
Exit status: 0

$ rg -n --hidden --no-ignore 'TODO|FIXME|HACK|@pytest\.mark\.skip' -- <all eight changed files>
No matches.
Exit status: 1 (ripgrep no-match status)
```

No dependency-audit command exists. No model evaluation ran because the change is
deterministic local state behavior.

## 4. Acceptance criteria

| Criterion | Status: met / unmet / unverified | Diff or execution evidence |
| --- | --- | --- |
| AC-010 — persist an all-history exclusion, exclude pre-reset occurrences after refresh/relaunch, permit post-reset occurrences | met | Service and cache changes plus fresh-context and stale-baseline regressions passed in both the 57-test focused and 167-test full suites. |

## 5. Limitations

- Repository-wide mypy fails in unchanged backend test
  `backend/tests/unit/test_agent_service.py:191`; no backend file is in this diff.
- No dependency vulnerability-audit command exists, so that scan was not run.
- One intermediate CoreSimulator launch reported `Busy`; restarting only the test
  simulator resolved it and both subsequent iOS suites passed.
- This was not manually exercised on a physical iPhone. Install a build containing
  `bfd9396` or later, then confirm `/clear` once to create the durable cutoff.
