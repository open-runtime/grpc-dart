# PR #41 Fact-Check Addendum (Post-Branch Updates)

This addendum corrects stale statements in historical `pr_reviews/pr_41` artifacts after subsequent branch updates. Historical phase files are intentionally preserved; this document is the correction layer.

## 1) "Should-fix" items now implemented

The three "should-fix" items listed as still-open in `phase_6_final_review.md` and `phase_5_agent_14_blocker_judge.md` are now implemented in source:

1. **Duplicated connection cleanup extracted**  
   - Implemented as `ConnectionServer._cleanupConnection()` in `lib/src/server/server.dart`.
   - Used by both `serveConnection(...).onError` and `serveConnection(...).onDone`.

2. **Silent subscription-cancel timeout now logs diagnostics**  
   - `ConnectionServer.shutdownActiveConnections()` Step 1 now logs timeout via `logGrpcEvent(...)` with event `subscription_cancel_timeout` in `lib/src/server/server.dart`.

3. **Hardcoded shutdown timeout literals extracted to named constants**  
   - `ConnectionServer._incomingSubscriptionCancelTimeout`
   - `ConnectionServer._responseCancelTimeout`
   - `ConnectionServer._finishConnectionDeadline`
   - `ConnectionServer._terminateConnectionTimeout`  
   - All defined in `lib/src/server/server.dart`.

## 2) Keepalive corrections (defaults, values, resets)

The following claims are inaccurate/stale and are corrected here:

- **`phase_3_agent_9_contextualizer.md` states Dart default `maxBadPings` is 3; that is incorrect.**  
  Source of truth: `ServerKeepAliveOptions.maxBadPings = 2` in `lib/src/server/server_keepalive.dart`.

- **Default min interval is 5 minutes.**  
  Source of truth: `ServerKeepAliveOptions.minIntervalBetweenPingsWithoutData` default in `lib/src/server/server_keepalive.dart`.

- **`5ms` thresholds in tests are test overrides, not runtime defaults.**  
  Source of truth: `initServer(...)` override in `test/server_keepalive_manager_test.dart`.

- **Ping-strike reset on data frames is implemented.**  
  This corrects stale "no reset on data frames" wording in `phase_6_final_review.md` and `phase_5_agent_15_suggestions.md` (I4).  
  Source of truth: `ServerKeepAlive._onDataReceived()` in `lib/src/server/server_keepalive.dart` resets:
  - `_badPings = 0`
  - `_timeOfLastReceivedPing = null`
  - `_tooManyBadPingsTriggered = false`

- **Data-reset behavior is covered by tests.**  
  Source of truth: `test/server_keepalive_manager_test.dart`:
  - `Sending many pings with data doesn\`t kill connection`
  - `tooManyBadPings callback can be retried after data reset`

## 3) Security finding count normalization (phase inconsistency fix)

Security counts were reported with different scopes across phase docs:

- `phase_2_agent_6_security_auditor.md` enumerates **SEC-1..SEC-10** (10 IDs total).
- Later rollups (for example `phase_6_final_review.md`) report **5 security findings** (the narrowed core set: SEC-1..SEC-5).
- `phase_2_agent_6_security_auditor.md` summary table line for MEDIUM shows `3`, but lists four IDs (`SEC-2`, `SEC-3`, `SEC-4`, `SEC-5`); corrected count is **4**.

Correct normalization:

- **All SEC IDs scope:** 10 total  
  - HIGH: 1 (`SEC-1`)  
  - MEDIUM: 4 (`SEC-2`, `SEC-3`, `SEC-4`, `SEC-5`)  
  - LOW: 4 (`SEC-6`, `SEC-7`, `SEC-8`, `SEC-10`)  
  - INFORMATIONAL: 1 (`SEC-9`)

- **Core actionable rollup scope:** 5 (`SEC-1`..`SEC-5`)

When comparing phase artifacts, treat these as scope differences, not contradictory raw counts.
