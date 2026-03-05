# PR #41 Review: fix/named-pipe-race-condition

## Review Action: APPROVE

---

## Executive Summary

This PR fixes documented production crashes (server "Cannot add event after closing" crash, hung `Server.shutdown()`, handler memory leak, inverted keepalive enforcement, stale connection callback race, null connection `ArgumentError`), introduces a Windows named pipe transport with a two-isolate architecture, and hardens the server/handler/client lifecycle with defense-in-depth shutdown synchronization. 500 tests pass, 0 fail. Zero accidental regressions were found among 22 intentional behavioral changes. Zero gRPC specification violations were identified. Zero anti-patterns were found in cross-implementation comparison against gRPC C++, Go, and Java.

No blockers. Three should-fix items recommended before or immediately after merge. Multiple follow-up suggestions documented below.

---

## Scope

| Metric | Value |
|--------|-------|
| Files changed | 57 |
| Lines | +21,738 / -1,130 |
| Commits | 73 |
| Production files | 16 |
| Test files | 30 (18 new, 12 modified) |
| CI/Config files | 11 |
| Tests passing | 500 (76 skipped -- all platform/infrastructure) |

Priority production files: `server.dart` (shutdown rewrite), `handler.dart` (handler lifecycle hardening), `named_pipe_server.dart` (two-isolate architecture), `http2_connection.dart` (dispatch/refresh fixes), `server_keepalive.dart` (keepalive comparison fix).

---

## What's Great

**Layered shutdown defenses with no single point of failure.** `shutdownActiveConnections()` at `server.dart:260-338` implements a four-step pipeline where every step has its own independent timeout and tolerates partial failure from the preceding step. The worst-case shutdown is 17 seconds (TCP) or 22 seconds (named pipe) -- bounded, versus the old code's unbounded shutdown that could hang forever on a server-streaming async* generator.

**`_finishConnection()` correctly avoids `Future.timeout()`.** At `server.dart:354-413`, the Completer+Timer pattern is immune to the original future's error behavior suppressing the timeout callback -- a Dart-specific adaptation that has no parallel in C++, Go, or Java gRPC. The doc comment explains exactly why.

**Measurement-driven design.** The deferred close pattern at `named_pipe_server.dart:655-683` cites a specific failure metric: "232/1000 item failures in tests." The keepalive fix references gRPC C++ `ping_abuse_policy.cc` line-by-line. The Step 1.5 keepalive controller cleanup was discovered via a 30-minute Windows CI hang. Each fix is traceable to a measured failure, not guesswork.

**Tests that prove their own necessity.** The keepalive test fails with the old inverted comparison (`0 > 5ms` evaluates to false). The bidi handler test hangs without the `cancel()` fix. The RST_STREAM stress test sees zero truncations without the Step 3 yield. The generation guard test catches stale `.done` callbacks abandoning new connections.

**Handler leak fix is the most performance-positive change.** The single line `isCanceled = true` in `sendTrailers()` at `handler.dart:506-511` eliminates unbounded memory growth from handlers that completed normally but were never cleaned from the `handlers` map. For long-lived connections processing thousands of RPCs, this is a significant improvement.

**Cross-implementation alignment.** Out of 16 design decisions evaluated against gRPC C++, Go, and Java, zero were classified as anti-patterns. 9 match standard gRPC practice, 4 are justified Dart-specific adaptations, 2 restore spec compliance, and 1 (two-isolate pipe server) is novel architecture forced by Dart's single-threaded event loop.

---

## Findings

### Blockers

**None.**

No finding meets the threshold of causing crashes, data loss, security vulnerabilities in the target deployment, or gRPC spec violations affecting interoperability.

### Should Fix (before or immediately after merge)

**SF-1: Extract duplicated connection cleanup into a shared method.**
`server.dart:185-218` -- the `onError` and `onDone` callbacks contain nearly identical 7-line cleanup blocks across five tracking maps. Adding a new map requires updating both blocks; forgetting one causes resource leaks under connection-error conditions. Extract into a `_cleanupConnection()` method that returns the `onDataReceivedController.close()` future so `onDone` can await it. Pure refactor, ~20 minutes.

**SF-2: Log the silent subscription-cancel timeout.**
`server.dart:284` -- the `.timeout(5s, onTimeout: () => <void>[])` callback silently discards timeouts. The companion handler cancel timeout at line 316-324 correctly logs diagnostics. Add a `logGrpcEvent` call matching that pattern. This is a CLAUDE.md Rule 4 violation ("Never treat timeout as success"). 5 lines.

**SF-3: Extract hardcoded timeout durations into named constants.**
Five timeout values (5s, 5s, 5s, 2s, 5s) are inline `Duration` literals across `server.dart`, `named_pipe_server.dart`, and `named_pipe_transport.dart`. Only `_settingsFrameTimeout` and `_deferredCloseTimeout` are named constants. Extracting into named static constants on `ConnectionServer` improves readability and makes the 17-second shutdown budget explicit.

### Top Suggestions (non-blocking, recommended for follow-up)

1. **Apply Completer+Timer to `forceTerminate()`** -- `server.dart:370-401` uses `connection.terminate().timeout(2s)` while the method's own doc comment explains why `.timeout()` is unreliable. Replace with the established Completer+Timer pattern for consistency. The `.timeout()` is defended by the raw socket `destroy()` fallback, so this is not a correctness risk today.

2. **Guard `connection.finish()` against synchronous throws** -- `server.dart:421-435`. If `finish()` throws synchronously, the Completer never completes until the 5s Timer fires. Wrap in try-catch with `forceTerminate()` fallback. The current http2 `finish()` does not throw synchronously, making this defensive coding.

3. **Use `??=` for `_responseCancelFuture` in `cancel()`** -- `handler.dart:600`. When `_onTimedOut` already cancelled the subscription, `cancel()` overwrites the in-progress cancel future with an immediately-resolving one. `_responseCancelFuture ??= ...` preserves the original (slower) future.

4. **Add terminate assertions to C1/C2 handler regression tests** -- `handler_regression_test.dart`. The `TrackingServerStream` infrastructure already records `terminateCount`; only the assertion lines are missing. Two lines per test group.

5. **Add a test for `outgoingMessages.done.whenComplete`** -- `handler.dart:145`. The `.then` to `.whenComplete` change has zero direct test coverage. A regression would silently leak handlers on outgoing stream errors. Every other handler lifecycle change has at least indirect coverage; this one has none.

6. **Snapshot handler list in Step 2** -- `server.dart:298-306`. The current code iterates `handlers[connection]` directly. While Dart's synchronous for loop prevents interleaving, adding `List.of()` matches the pattern used in `onError`/`onDone` and eliminates an inconsistency.

7. **Validate pipe handle in `_handleNewConnection`** -- `named_pipe_server.dart`. Guard against `hPipe == 0 || hPipe == INVALID_HANDLE_VALUE` before using the integer as a Win32 handle for ReadFile/WriteFile/CloseHandle. 4 lines of defense-in-depth.

---

## Architecture Assessment

The five subsystems (server lifecycle, handler lifecycle, client connection management, TCP transport, named pipe transport) interact through well-defined ownership boundaries with appropriate safety mechanisms at each interface.

**Shutdown cascade**: Steps 1-4 are strictly ordered with independent timeouts. No feedback loops exist between shutdown invocations. The `Completer.isCompleted` and `terminateCalled` guards in `_finishConnection()` prevent double-completion across three racing completion paths. Socket destruction in `whenComplete` provides the final safety net for TCP.

**Handler idempotency**: Six boolean/sentinel state fields (`_trailersSent`, `_streamTerminated`, `_isCanceledCompleter`, `_headersSent`, `_handleClosed`, `_isClosed`) form a complete idempotency layer. Every state transition goes through a check-then-set gate. Concurrent `cancel()` from shutdown and `onTerminated` from transport converge safely.

**Client reconnection**: The `_connectionGeneration` counter (incremented BEFORE `await`, not after) prevents stale `.done` callbacks from abandoning new connections. The batch re-queue pattern (`_pendingCalls.add(call)` instead of `dispatchCall(call)`) prevents N simultaneous zero-backoff reconnection attempts.

**Named pipe layering**: Win32 I/O -> Dart streams -> HTTP/2 framing. The deferred close path prevents data loss by letting HTTP/2 response frames drain before closing the incoming controller. Back-pressure limitations are inherited from upstream `package:http2`, not worsened by this PR.

Two emergent risks identified, both bounded by existing safety nets:
- `forceTerminate()` `.timeout()` inconsistency (MEDIUM) -- defended by raw socket `destroy()` fallback
- Single yield for RST_STREAM flush may be insufficient under extreme connection counts (LOW) -- caught by `_finishConnection` 5s deadline

---

## Cross-Implementation Validation

| Category | Count | Examples |
|----------|-------|---------|
| Standard gRPC practice | 9 | Shutdown cascade, ENHANCE_YOUR_CALM on ping abuse, GOAWAY before socket close |
| Novel Dart adaptations | 4 | Completer+Timer shutdown, dispatch loop yield, deferred pipe close, transport sink guards |
| Spec compliance restored | 2 | Keepalive comparison inversion, stopwatch reset on every ping |
| Novel architecture | 1 | Two-isolate named pipe server |
| Anti-patterns | 0 | -- |

Two pre-existing gaps (not introduced by this PR): no double-GOAWAY pattern in shutdown (limitation of `package:http2`), no ping-strike reset on data frames (Dart server is stricter than C++/Go).

---

## Test Coverage

84 new/modified test functions across 30 test files. The highest-risk production fixes all have strong, direct test coverage:

| Fix | Test | Mechanism |
|-----|------|-----------|
| Keepalive comparison inversion | `server_keepalive_manager_test.dart` | FakeAsync, would fail with old `>` operator |
| RST_STREAM flush yield | `rst_stream_stress_test.dart` | 50 concurrent streams, asserts truncation count >= 5 |
| `cancel()` closing `_requests` | `handler_hardening_test.dart` | Bidi handler stuck in await-for, would hang without fix |
| Connection generation guard | `connection_lifecycle_test.dart` | Forces reconnection, verifies stale callback is no-op |
| Handler memory leak | `handler_hardening_test.dart` | Verifies `isCanceled` is true after normal completion |
| `_addErrorAndClose` atomicity | `handler_regression_test.dart` | Tests error + close with separate try blocks |

4 coverage gaps identified (forceTerminate path, whenComplete change, mid-GOAWAY dispatch re-queue, C1/C2 terminate assertions); 3 of 4 have overlapping integration coverage.

---

## Risk Assessment

| Category | Count | Severity |
|----------|-------|----------|
| Bugs found | 6 | 0 critical, 2 medium, 4 low |
| Accidental regressions | 0 | -- |
| Security findings | 5 | All apply to new named pipe transport with no existing users |
| Spec violations | 0 | -- |
| Performance impact | Negligible | Zero steady-state overhead; handler leak fix is net positive |

The two medium-severity bugs (`forceTerminate` using `.timeout()`, no sync-throw guard on `finish()`) are both defended by the 5s Timer safety net and raw socket `destroy()` fallback. They are theoretical edge-of-edge cases with no reproduction path.

Security findings (NULL DACL, pipe name validation, unbounded instances, error message exposure, keepalive subscription cleanup) are hardening opportunities for a brand-new transport, not regressions. `PIPE_REJECT_REMOTE_CLIENTS` eliminates remote attack surface. The NULL DACL default is consistent with Node.js, Go, and .NET named pipe servers.

---

## Verdict

**APPROVE.** This PR fixes real production crashes, restores gRPC specification compliance for keepalive enforcement, introduces a correctly-layered named pipe transport, and does so with comprehensive test coverage and exceptional inline documentation. The three should-fix items are quality improvements totaling ~30-60 minutes of effort; they do not represent correctness risks. All other findings are maintenance, hardening, and edge-case concerns appropriate for follow-up work.
