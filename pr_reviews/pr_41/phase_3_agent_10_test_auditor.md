# Phase 3 -- Agent 10: Test Auditor

## Scope

Audited 30 changed test files across the PR (`git diff --name-only main...HEAD -- test/`), mapped each Phase 2 production finding to its test coverage, and evaluated test quality against the CLAUDE.md timing/synchronization rules.

---

## Coverage Matrix

### Handler Fixes (handler.dart)

| Production Fix | Test File | Test Name | Covers Race? | Verdict |
|---|---|---|---|---|
| `_trailersSent` guard (double-trailer prevention) | `handler_regression_test.dart` | H5: cancel after normal completion calls terminate at most once | YES -- verifies `sentTrailers.hasLength(1)` after cancel post-completion | PASS |
| `_streamTerminated` guard (double RST_STREAM) | `handler_regression_test.dart` | H5: cancel after normal completion calls terminate at most once | YES -- `terminateCount <= 1` assertion | PASS |
| `_addErrorAndClose` helper (addError-then-close atomicity) | `handler_hardening_test.dart` | _addErrorAndClose when addError throws on pre-closed stream | YES -- uses custom service that intercepts `addError` to throw, then verifies `handlerExited` completer fires within 2s | PASS |
| `_onTimedOut` terminates stream + cancels subscription (REG-3) | `handler_regression_test.dart` | C1: timeout sends deadline-exceeded trailers with endStream | PARTIAL -- verifies trailers and status code, but does not verify `_incomingSubscription.cancel()` or RST_STREAM was sent (TrackingServerStream records `terminate()` but test doesn't assert it) | WEAK |
| `_onDoneError` terminates stream (REG-4) | `handler_regression_test.dart` | C2: unexpected close sends unavailable with endStream | PARTIAL -- verifies status and trailer count, does not assert `wasTerminated == true` | WEAK |
| `_applyInterceptors` preserves GrpcError (REG-9) | `handler_regression_test.dart` | H3: 4 tests for unauthenticated/permissionDenied/internal/async | YES -- directly tests status code preservation with 4 variants | PASS |
| `cancel()` closes `_requests` (REG-5) | `handler_hardening_test.dart` | Server.shutdown() unblocks bidi handler stuck in await-for | YES -- creates a blocking bidi handler, calls shutdown, verifies handler exits via completer | PASS |
| `sendTrailers` sets `isCanceled = true` (REG-6) | `production_regression_test.dart` | shutdown with active streaming handlers settles and empties map | YES -- verifies `server.handlers.values.every((list) => list.isEmpty)` after shutdown | PASS |
| `_onResponseError` closes `_requests` (REG-7) | `handler_hardening_test.dart` | response error during streaming closes handler without crash | PARTIAL -- tested indirectly via error-throwing service; no direct test that verifies `_requests` was closed specifically by `_onResponseError` | WEAK |
| `outgoingMessages.done.whenComplete` (REG-8) | None | N/A | NO -- no test specifically triggers outgoing stream error completion to verify cancel() fires | GAP |
| `_onDataIdle` try-catch wrapper | `handler_hardening_test.dart` | Multiple adversarial state machine tests | INDIRECT -- the broader harness tests cover scenarios where _onDataIdle might throw, but no test directly triggers an exception inside _onDataIdle's try-catch body | WEAK |
| BUG-6: `onDataReceived?.add(null)` can throw when controller closed | `connection_server_error_cleanup_test.dart` | onError on incomingStreams cleans up connection state | INDIRECT -- tests that the keepalive controller is cleaned up on error, but does not directly test the guard that prevents `add(null)` from crashing when the controller is already closed | WEAK |

### Server Fixes (server.dart)

| Production Fix | Test File | Test Name | Covers Race? | Verdict |
|---|---|---|---|---|
| `shutdownActiveConnections` 4-step sequence | `rst_stream_stress_test.dart` | 50 concurrent server-streaming RPCs terminate on server.shutdown() alone | YES -- 50 concurrent streams must settle without channel.shutdown(), proving RST_STREAM flush yield works | PASS |
| RST_STREAM flush yield (Step 3) | `rst_stream_stress_test.dart` | 50 streams + 20 bidi + 30 mixed | YES -- truncation count >= 5 proves RST_STREAM propagated | PASS |
| BUG-1: `forceTerminate()` uses `.timeout()` | None | N/A | NO -- no test creates an event-loop-saturated scenario where `forceTerminate()` is exercised and the inner `.timeout()` is tested | GAP |
| BUG-2: `connection.finish()` synchronous throw | None | N/A | NO -- no test uses a mock connection whose `finish()` throws synchronously | GAP |
| `onError` cleanup mirrors `onDone` (H4) | `connection_server_error_cleanup_test.dart` | 3 tests: baseline onDone, non-Error, Error cleanup | YES -- directly injects errors into `incomingStreams` and verifies `handlers` map is cleaned up | PASS |
| `_keepAliveControllers` cleanup on shutdown | `production_regression_test.dart` | shutdown with active streaming handlers settles | INDIRECT -- shutdown completes within 10s (proving VM doesn't hang), but does not explicitly verify controller closure | WEAK |
| `_incomingSubscriptions` cancellation (Step 1) | `shutdown_propagation_test.dart` | shutdown with 50 active streams empties handler map | INDIRECT -- handler map drains, proving subscriptions were cancelled, but Step 1 specifically is not isolated | WEAK |
| `_connectionSockets` socket.destroy in forceTerminate | None | N/A | NO -- no test reaches the forceTerminate path and verifies socket destruction | GAP |

### Client Fixes (http2_connection.dart)

| Production Fix | Test File | Test Name | Covers Race? | Verdict |
|---|---|---|---|---|
| `_connectionGeneration` stale callback guard | `connection_lifecycle_test.dart` | stale socket.done callback does not abandon new connection | YES -- reconnects and verifies readyCount >= 2, proving stale callback didn't kill new connection | PASS |
| `makeRequest` throws `GrpcError.unavailable` (REG-10) | `connection_lifecycle_test.dart` + `production_regression_test.dart` | makeRequest on null connection throws GrpcError.unavailable | YES -- directly asserts exception type, status code, and message | PASS |
| SETTINGS frame wait (REG-11) | `connection_lifecycle_test.dart` | rapid reconnection cycles are stable | INDIRECT -- 5 reconnection cycles succeed, proving SETTINGS handshake works, but no test verifies the 100ms timeout fallback specifically | WEAK |
| `shutdown()`/`terminate()` call `_transportConnector.shutdown()` (REG-12) | `connection_lifecycle_test.dart` | shutdown/terminate clean up all resources | YES -- verifies shutdown state reached and further calls fail | PASS |
| Dispatch loop async yield (REG-13) | `dispatch_requeue_test.dart` | 10 concurrent RPCs on fresh channel + 50 pending calls | PARTIAL -- tests that concurrent RPCs converge correctly, but does not test the mid-dispatch GOAWAY scenario that triggers re-queue with backoff | WEAK |
| `_frameReceivedSubscription` cancellation in `_disconnect` | None | N/A | NO -- no test verifies that `_frameReceivedSubscription` is properly cancelled | GAP |

### Keepalive Fixes (server_keepalive.dart)

| Production Fix | Test File | Test Name | Covers Race? | Verdict |
|---|---|---|---|---|
| REG-1: Comparison inversion (`>` to `<`) | `server_keepalive_manager_test.dart` | Sending too many pings without data kills connection | YES -- sends rapid pings (elapsed ~0 < 5ms threshold); with old `>` comparison, elapsed 0 > 5ms = false, so test WOULD FAIL without fix | PASS |
| Stopwatch reset on every ping | `server_keepalive_manager_test.dart` | Same test + data reset test | YES -- FakeAsync environment means elapsed is exactly 0; without reset, accumulated elapsed would bypass the threshold | PASS |
| `_tooManyBadPingsTriggered` idempotency flag | `production_regression_test.dart` | tooManyBadPings callback fires only once under ping flood | YES -- sends 20+ pings, verifies callback count == 1 | PASS |
| `_onPingReceived` catchError wrapper | None | N/A | NO -- no test triggers an exception inside `_onPingReceived` to verify the catchError handler | GAP |

### Named Pipe Fixes

| Production Fix | Test File | Test Name | Covers Race? | Verdict |
|---|---|---|---|---|
| SEC-1: NULL SECURITY_ATTRIBUTES | None | N/A | NO -- no test verifies access control on named pipes | GAP (design issue, not regression test gap) |
| SEC-2: No pipe name validation | None | N/A | NO -- no test injects malicious pipe names | GAP (design issue) |
| Isolate shutdown race (kill + dummy client) | `named_pipe_adversarial_test.dart` | Multiple shutdown race tests | YES -- platform-gated; exercises Isolate.immediate kill pattern | PASS (Windows only) |

### Transport Sink Guards (http2_transport.dart, call.dart)

| Production Fix | Test File | Test Name | Covers Race? | Verdict |
|---|---|---|---|---|
| Transport listen callback guards (try-catch on add/addError/close) | `transport_guard_test.dart` | 10 test scenarios across bidi, server-stream, large payload, concurrent errors | YES -- each test uses `expectHardcoreRpcSettlement` to verify no crashes during shutdown-under-load | PASS |

---

## Test Quality Issues

### [TAUDIT-1] `handler_regression_test.dart` Uses Extensive `Future.delayed` for Synchronization

**File:** `test/handler_regression_test.dart`
**Issue:** 13 occurrences of `Future.delayed` with non-zero durations (50ms, 100ms) used as synchronization barriers in nearly every test. Examples:
- Line 240: `await Future.delayed(const Duration(milliseconds: 100))` -- waiting for timeout to fire
- Line 317: `await Future.delayed(const Duration(milliseconds: 100))` -- waiting for stream close
- Line 378, 401, 424, 448: `await Future.delayed(const Duration(milliseconds: 50-100))` -- waiting for interceptor error processing

**Risk:** This is a CLAUDE.md Rule 1 violation ("Never use arbitrary `Future.delayed(...)` as synchronization"). On slow CI runners, these delays may be insufficient. On fast runners, they waste test time. The `TrackingServerStream` and `TrackingHarness` infrastructure COULD provide Completer-based signals for when trailers are sent or when the handler completes, eliminating the need for timed waits.

**Mitigation factor:** These are unit-level harness tests (not integration tests), the delays are generous relative to the operations (50-100ms for microsecond operations), and the harness controls all inputs synchronously. Flake risk is LOW but the pattern sets a bad precedent.

### [TAUDIT-2] `race_condition_test.dart` Normalizes Timeout as Success

**File:** `test/race_condition_test.dart:280-283`
**Issue:** The "Reproduce exact 'Cannot add event after closing' scenario" test uses:
```dart
final result = await errorCompleter.future.timeout(
  Duration(milliseconds: 100),
  onTimeout: () => 'Did not reproduce the exact error',
);
```
This normalizes a timeout into a non-failure string, which is then asserted against.

**Risk:** This is a CLAUDE.md Rule 4 edge case ("Never treat timeout as success"). The logic IS correct -- timeout means the error was NOT reproduced (which is the desired outcome). But the pattern inverts the usual timeout semantics: normally timeout = bad, here timeout = good. A reader scanning for Rule 4 violations would flag this. If the fix regressed and the error appeared AFTER the 100ms window, the test would still pass.

**Mitigation factor:** The 100ms window is for a synchronous error path that would fire within microseconds if triggered. The risk of a 100ms+ delayed regression is extremely low.

### [TAUDIT-3] `transport_guard_test.dart` Uses `Future.delayed` as Flow Control Barrier

**File:** `test/transport_guard_test.dart`, lines 74, 131, 200, 276, 349, 404, 522
**Issue:** 8 occurrences of `Future.delayed(Duration(milliseconds: 1-100))` used to wait for data to be "in flight" before triggering shutdown. Most notably:
- Line 200: `await Future.delayed(const Duration(milliseconds: 50))` -- "Wait for first response on all 10 streams"
- Line 276: `await Future.delayed(const Duration(milliseconds: 50))` -- "Wait for first bidi response"

These could be replaced with per-stream `firstItemCompleter` patterns (as used in `rst_stream_stress_test.dart` lines 97-101).

**Risk:** CLAUDE.md Rule 1 violation. On a heavily loaded CI runner, 50ms may not be enough for all 10/20 streams to receive their first item. The test could race past the delay and shut down before any streams are active, making the shutdown-under-load scenario vacuous.

**Mitigation factor:** The `rst_stream_stress_test.dart` file covering the same shutdown scenario DOES use proper `firstItemCompleter` barriers, providing overlapping coverage with correct synchronization.

### [TAUDIT-4] `connection_lifecycle_test.dart` Uses `Future.delayed` for Connection Aging

**File:** `test/connection_lifecycle_test.dart`, lines 70, 118, 469, 531, 579, 937, 1016
**Issue:** 7 occurrences of `Future.delayed` with non-zero durations to wait for `connectionTimeout` to expire, triggering reconnection. Example:
```dart
await Future.delayed(const Duration(milliseconds: 300));  // wait for connection to age out
```
The connection aging is driven by `_connectionLifeTimer` which is a real timer, so there's no deterministic signal to await.

**Risk:** CLAUDE.md Rule 1 partial violation. Unlike arbitrary synchronization delays, these are config-derived waits (e.g., connectionTimeout=200ms, wait 300ms). The test comments note this ("Wait for connection to age out"). The risk is that under high CI load, the timer may fire late, and the 1.5x margin may not be enough.

**Mitigation factor:** The tests use soft assertions (`greaterThanOrEqualTo`) that accommodate timer jitter, and the multipliers are generous (1.5-3x). These are inherently timer-dependent tests; there is no readiness signal to poll for connection aging.

### [TAUDIT-5] `connection_server_error_cleanup_test.dart` Uses `Future.delayed(Duration.zero)` for Microtask Flushing

**File:** `test/connection_server_error_cleanup_test.dart`, 9 occurrences of `Future.delayed(Duration.zero)`
**Issue:** Uses zero-duration delays to flush microtasks. Example:
```dart
await Future.delayed(Duration.zero);  // Allow microtasks to flush
```

**Risk:** Zero-duration delays are NOT Rule 1 violations (they are equivalent to `await Future.value()` for microtask scheduling). However, some occurrences use non-zero delays (e.g., 50ms, 100ms) which ARE Rule 1 violations when used as synchronization. There are also 9 usages total which suggests the test could benefit from a flush helper.

**Mitigation factor:** Zero-duration delays are the standard Dart pattern for microtask flushing and are explicitly approved in the MEMORY.md timing notes.

### [TAUDIT-6] Assertions Could Be Tighter in `race_condition_test.dart` Stress Test

**File:** `test/race_condition_test.dart:230`
**Issue:** The stress test assertion is:
```dart
expect(futures.length, equals(10));
```
This only verifies that 10 futures were created, not that they completed successfully or that the race condition was actually exercised. The test relies solely on the absence of an unhandled exception to prove correctness.

**Risk:** If the fix regressed but the server swallowed the exception silently (e.g., via a try-catch), the test would still pass. The test should assert on `harness.capturedErrors` for each iteration to verify no "Cannot add event after closing" errors were captured.

### [TAUDIT-7] No Test Exercises the `forceTerminate()` Path End-to-End (BUG-1)

**File:** `lib/src/server/server.dart:364`
**Issue:** BUG-1 identified that `forceTerminate()` uses `.timeout()` on `connection.terminate()`, which contradicts the documented rationale for using Completer+Timer. No test creates an event-loop-saturated scenario where:
1. The 5-second Timer fires `forceTerminate()`
2. `connection.terminate()` blocks/hangs
3. The `.timeout(2s)` must fire under load

**Risk:** The entire Completer+Timer pattern in `_finishConnection` is untested at the unit level. The integration tests (rst_stream_stress_test, shutdown_propagation_test) exercise the happy path where `finish()` or `terminate()` complete within their deadlines. The adversarial path (saturated event loop) is only theoretically covered.

---

## Coverage Gaps

### Critical Gaps

1. **BUG-1 (`forceTerminate` uses `.timeout()`):** No test exercises the Timer-fires-but-terminate-hangs path. This is the exact scenario documented as the reason for using Completer+Timer in the first place. Risk: shutdown could hang in production under extreme load.

2. **REG-8 (`outgoingMessages.done.whenComplete` vs `.then`):** No test triggers error completion of the outgoing message stream. The fix changes `.then((_) { cancel(); })` to `.whenComplete(() { cancel(); })`, meaning cancel() now fires on error completion. Without a test, this change could regress silently.

3. **Dispatch loop mid-GOAWAY re-queue (REG-13 adversarial path):** The dispatch_requeue_test.dart tests normal dispatch convergence but not the mid-dispatch state change that triggers the re-queue+backoff logic. A server that sends GOAWAY after accepting the first stream but before all pending calls are dispatched would exercise this path.

### Moderate Gaps

4. **`_onTimedOut` stream termination (REG-3):** `handler_regression_test.dart` C1 group verifies trailers but does not assert that `terminate()` was called on the stream. The `TrackingServerStream` infrastructure tracks `terminateCount` but the assertion is missing.

5. **`_onDoneError` stream termination (REG-4):** Same issue as above -- C2 group verifies trailers but does not assert `wasTerminated == true`.

6. **BUG-6 (`onDataReceived?.add(null)` guard):** The `_onDataIdle` try-catch wrapper protects against this, but no test directly closes the keepalive controller and then triggers a data arrival to verify the guard prevents the crash.

7. **`_onPingReceived` catchError handler:** No test triggers an exception inside the keepalive ping processing to verify the error is caught and logged rather than crashing the server.

### Design-Level Gaps (Not Regression Risks)

8. **SEC-1 (NULL SECURITY_ATTRIBUTES):** No test verifies pipe access control. This is a design gap, not a regression test gap -- the null pointer was present before the PR.

9. **SEC-2 (pipe name validation):** No test injects malicious pipe names. Same caveat as SEC-1.

---

## Summary

### Strengths

The test suite is **extensive** -- 30 changed test files with ~84 new/modified test functions covering handler hardening, shutdown propagation, transport guards, keepalive fixes, dispatch requeue, connection lifecycle, and production regressions. The most critical fixes have strong coverage:

- **Keepalive comparison inversion (REG-1):** FakeAsync unit test WOULD FAIL without the fix. This is the gold standard for regression testing.
- **RST_STREAM flush yield:** 50-stream stress test with completer-based readiness barriers. Well-designed.
- **`_addErrorAndClose` atomicity:** Custom service that makes `addError` throw, then verifies the handler still exits. Directly tests the failure mode.
- **`cancel()` closing `_requests`:** End-to-end test with a blocking bidi handler that must exit on shutdown. Would hang without the fix.
- **Connection generation tracking:** Integration test that forces reconnection and verifies stale callbacks are ignored.
- **GrpcError preservation in interceptors (REG-9, H3):** 4 variant tests covering sync/async, different status codes.
- **`_tooManyBadPingsTriggered` idempotency:** Direct unit test with 20-ping flood.

### Weaknesses

1. **Rule 1 (Future.delayed) violations:** ~97 occurrences of `Future.delayed` across test files. While many are zero-duration (acceptable) or config-derived (unavoidable for timer tests), approximately 20-30 are arbitrary non-zero delays used for synchronization where Completer-based barriers would be more deterministic.

2. **Handler regression tests lack terminate assertions:** The `TrackingServerStream` infrastructure records `terminateCount` but C1 and C2 tests don't assert on it, leaving the RST_STREAM fix for `_onTimedOut` and `_onDoneError` only indirectly covered via trailer assertions.

3. **No adversarial tests for the Completer+Timer shutdown pattern (BUG-1, BUG-2):** The entire `_finishConnection` method is only integration-tested. No unit test with a mock connection that hangs or throws synchronously.

4. **`outgoingMessages.done.whenComplete` (REG-8) has zero coverage:** This is a one-character change (`.then` to `.whenComplete`) that could regress with no test catching it.

### Overall Verdict

The test suite is **above average for a gRPC transport library** and covers the highest-risk production fixes effectively. The 4 critical gaps (BUG-1 forceTerminate, REG-8 whenComplete, REG-13 mid-GOAWAY dispatch, and the C1/C2 terminate assertions) are real but bounded: 3 of 4 have overlapping integration coverage that would likely catch regressions, albeit indirectly and non-deterministically. The `whenComplete` gap (REG-8) is the most concerning because it has zero overlapping coverage and a regression would silently leak handlers on outgoing stream errors.

**Recommendation:** Address the 4 critical gaps before merge. The `Future.delayed` violations (TAUDIT-1, -3, -4) are stylistic issues that can be cleaned up in a follow-up -- they do not block merge.
