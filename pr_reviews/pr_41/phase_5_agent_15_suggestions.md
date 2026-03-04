# Phase 5 -- Agent 15: Suggestions Curator

**PR**: #41 `fix/named-pipe-race-condition` -> `main`
**Repository**: `open-runtime/grpc-dart`

All items below are **non-blocking**. They are compiled from Phase 2-4 findings across 10 agent reviews. Each suggestion includes what to change, why it matters, effort estimate, and which agent(s) flagged it.

---

## 1. Should Fix Soon

These items address real correctness concerns, inconsistencies, or maintainability hazards that should be resolved within this PR or immediately after merge.

---

### S1. Apply Completer+Timer to `forceTerminate()` inner `terminate().timeout(2s)`

**What to change**: In `lib/src/server/server.dart:370-401`, replace `connection.terminate().timeout(const Duration(seconds: 2))` inside `forceTerminate()` with the same Completer+Timer pattern used by the outer `_finishConnection()`. Use a 2-second Timer that fires a final socket-destroy fallback, mirroring the structure at lines 354-420.

**Why it matters**: The PR's own documentation (line 334-337) explains why `Future.timeout()` is unreliable under event-loop saturation. Yet `forceTerminate()` -- which runs precisely when the event loop IS saturated (the 5s Timer fired because `finish()` hung) -- uses the very pattern documented as unreliable. If `terminate().timeout(2s)` fails to fire, `done.future` never completes and `shutdownActiveConnections` hangs permanently via `Future.wait`. This is the most self-contradictory pattern in the PR.

**Effort**: Small (replace ~15 lines of chained futures with the established Completer+Timer pattern already proven at the outer level)

**Flagged by**: Agent 4 (Bug Hunter, BUG-1), Agent 8 (Devil's Advocate, Challenge 1), Agent 11 (Systems Thinker, RISK-2)

---

### S2. Add `logGrpcEvent` to the silent subscription-cancel timeout in `shutdownActiveConnections()` Step 1

**What to change**: In `lib/src/server/server.dart:284`, the `.timeout(5s, onTimeout: () => <void>[])` callback silently discards the timeout. Add a `logGrpcEvent` call matching the pattern already used at line 316-324 for the handler cancel timeout:

```dart
.timeout(const Duration(seconds: 5), onTimeout: () {
  logGrpcEvent(
    '[gRPC] Incoming subscription cancel timed out after 5s, proceeding to handler cancellation',
    component: 'Server',
    event: 'shutdownActiveConnections',
  );
  return <void>[];
})
```

**Why it matters**: CLAUDE.md Rule 4 states "Never treat timeout as success. `onTimeout` must fail loudly with context." The companion timeout at line 314-326 correctly logs diagnostics. This one was likely missed. Silent timeouts make production debugging impossible.

**Effort**: Trivial (add 5 lines to an existing callback)

**Flagged by**: Agent 7 (Contract Enforcer, VIOL-1)

---

### S3. Extract duplicated connection cleanup in `onError`/`onDone` into a shared method

**What to change**: In `lib/src/server/server.dart:185-201` (onError) and lines 209-218 (onDone), extract the nearly identical cleanup logic into a private method:

```dart
void _cleanupConnection(
  ServerTransportConnection connection,
  StreamController<void> onDataReceivedController,
) {
  final connectionHandlers = List.of(handlers[connection] ?? <ServerHandler>[]);
  for (final handler in connectionHandlers) {
    handler.cancel();
  }
  _connections.remove(connection);
  handlers.remove(connection);
  _incomingSubscriptions.remove(connection);
  _connectionSockets.remove(connection);
  _keepAliveControllers.remove(connection);
  onDataReceivedController.close();
}
```

The only difference between the two paths is `await` before `onDataReceivedController.close()` in `onDone`. Handle this by making the method return the close future and letting `onDone` await it.

**Why it matters**: This is the single most fragile pattern in the PR. Adding a new tracking map to `ConnectionServer` requires updating both cleanup blocks, and forgetting one path causes resource leaks that only manifest under specific connection-error conditions. Five maps must stay in sync between two copy-pasted blocks.

**Effort**: Small (pure refactor, no behavioral change, approximately 20 minutes)

**Flagged by**: Agent 13 (Maintainability, Section 6.1, rated HIGH priority)

---

### S4. Guard `connection.finish()` against synchronous throws in `_finishConnection()`

**What to change**: In `lib/src/server/server.dart:421-435`, wrap the `connection.finish()` chain in a try-catch:

```dart
try {
  connection
      .finish()
      .then((_) { complete(); })
      .catchError((e) { ... forceTerminate(); });
} catch (e) {
  logGrpcEvent('[gRPC] connection.finish() threw synchronously: $e', ...);
  forceTerminate();
}
```

**Why it matters**: If `finish()` throws synchronously (e.g., transport already disposed), the exception propagates through the async function body before `return done.future` executes. The `done` Completer never completes until the 5s Timer fires, but `Future.wait` already has the error from the synchronous throw. The error propagates to `Server.shutdown()`, potentially crashing the shutdown path.

**Effort**: Trivial (wrap existing code in try-catch, 5 lines)

**Flagged by**: Agent 4 (Bug Hunter, BUG-2)

---

### S5. Correct the `_finishConnection()` doc comment rationale

**What to change**: In `lib/src/server/server.dart:334-337`, update the comment from "because `.timeout()` relies on the same event loop that may be saturated" to the actual reason:

```dart
/// Using Completer + Timer instead of Future.timeout() because:
/// 1. If connection.finish() throws synchronously, .timeout() never
///    registers its timer.
/// 2. If connection.finish() completes with an error, .timeout()
///    resolves with that error and cancels the onTimeout callback --
///    meaning forceTerminate() never runs.
/// The Completer + Timer pattern guarantees forceTerminate() runs
/// after the deadline regardless of how finish() behaves.
```

**Why it matters**: The current rationale is technically imprecise -- both `Future.timeout()` and raw `Timer` use the same `Zone.current.createTimer()` under the hood and have identical timer-delivery guarantees. The real advantage of the Completer+Timer pattern is that it is immune to the original future's error behavior suppressing the timeout callback. Accurate documentation prevents future developers from questioning or removing the pattern based on a misunderstanding.

**Effort**: Trivial (edit a comment)

**Flagged by**: Agent 8 (Devil's Advocate, Challenge 1 verdict)

---

### S6. Use `_responseCancelFuture ??=` to avoid overwriting prior cancel futures

**What to change**: In `lib/src/server/handler.dart:600`, change the `cancel()` method to avoid overwriting a cancel future that is already in progress:

```dart
_responseCancelFuture ??= _responseSubscription?.cancel().catchError((e) {
  logGrpcEvent('[gRPC] Error cancelling response subscription: $e', ...);
});
```

**Why it matters**: When `_onTimedOut()` calls `_cancelResponseSubscription()` and stores the cancel future, then `cancel()` overwrites it with a second `.cancel()` call on the same subscription. `shutdownActiveConnections()` reads `handler.onResponseCancelDone` and may get an immediately-resolved future from the second cancel while the original async generator is still winding down from the first cancel. With `??=`, the original (slower) cancel future is preserved.

**Effort**: Trivial (change one line)

**Flagged by**: Agent 4 (Bug Hunter, BUG-3)

---

### S7. Add terminate assertions to `_onTimedOut` and `_onDoneError` handler regression tests

**What to change**: In `test/handler_regression_test.dart`, C1 group (timeout trailers) and C2 group (unexpected close), add assertions that the stream was terminated:

```dart
// C1: after verifying trailers
expect(stream.wasTerminated, isTrue, reason: '_onTimedOut should call _terminateStream()');

// C2: after verifying status
expect(stream.wasTerminated, isTrue, reason: '_onDoneError should call _terminateStream()');
```

The `TrackingServerStream` infrastructure already records `terminateCount` -- the assertions are simply missing.

**Why it matters**: REG-3 and REG-4 are MEDIUM-severity behavioral changes (new RST_STREAM on deadline and unexpected close). Without these assertions, the terminate behavior could regress silently. The test infrastructure is already in place; only the assertion lines are missing.

**Effort**: Trivial (add 2 lines per test group)

**Flagged by**: Agent 10 (Test Auditor, Coverage Matrix -- WEAK verdict on C1 and C2)

---

### S8. Add a test for `outgoingMessages.done.whenComplete` (REG-8)

**What to change**: Create a test (in `handler_regression_test.dart` or `handler_hardening_test.dart`) that triggers error completion of the outgoing message stream and verifies that `cancel()` is called on the handler. The test should:
1. Set up a server-streaming RPC
2. Cause `outgoingMessages.done` to complete with an error (e.g., by injecting a transport error on the outgoing stream)
3. Assert that the handler's `isCanceled` is true after the error

**Why it matters**: This is a one-character change (`.then` to `.whenComplete`) with zero overlapping test coverage. The Test Auditor identified it as the most concerning gap: a regression would silently leak handlers on outgoing stream errors. Every other handler lifecycle change has at least indirect coverage; this one has none.

**Effort**: Small (one new test, approximately 30-50 lines using existing test infrastructure)

**Flagged by**: Agent 10 (Test Auditor, Critical Gap #2), Agent 5 (Regression Detective, REG-8)

---

### S9. Snapshot the handler list in `shutdownActiveConnections` Step 2

**What to change**: In `lib/src/server/server.dart:298-306`, snapshot the handler list before iterating:

```dart
final connectionHandlers = List.of(handlers[connection] ?? <ServerHandler>[]);
for (final handler in connectionHandlers) {
  handler.cancel();
  cancelFutures.add(handler.onResponseCancelDone);
}
```

**Why it matters**: The current code iterates `handlers[connection]` directly. While Dart's synchronous for loop prevents microtask interleaving during the iteration, the pattern is inconsistent with the onError/onDone callbacks (which DO snapshot via `List.of()`). Consistent use of snapshots eliminates an entire class of potential bugs and makes the code more resilient to future changes that might introduce yields.

**Effort**: Trivial (change one line to add `List.of()`)

**Flagged by**: Agent 4 (Bug Hunter, BUG-5)

---

### S10. Validate pipe handle in `_handleNewConnection`

**What to change**: In `lib/src/server/named_pipe_server.dart`, add a defense-in-depth check at the beginning of `_handleNewConnection()`:

```dart
void _handleNewConnection(int hPipe) {
  if (hPipe == 0 || hPipe == INVALID_HANDLE_VALUE) {
    logGrpcEvent('[NamedPipe] Invalid pipe handle received from accept loop: $hPipe', ...);
    return;
  }
  // ... existing code
}
```

**Why it matters**: The `_PipeHandle.handle` integer is used directly as a Win32 handle for ReadFile/WriteFile/CloseHandle. While the accept-loop isolate is trusted and Dart's SendPort only accepts the types that the loop sends, a simple guard against invalid handles costs nothing and prevents undefined behavior if an FFI bug corrupts the handle value.

**Effort**: Trivial (add 4 lines)

**Flagged by**: Agent 6 (Security Auditor, SEC-6)

---

## 2. Nice to Have

These items are good improvements that should be addressed in follow-up PRs. They improve maintainability, performance, or security but are not urgent for the current merge.

---

### N1. Extract hardcoded shutdown timeout durations into named constants

**What to change**: In `lib/src/server/server.dart`, replace the 7 inline `Duration(seconds: 5)` and `Duration(seconds: 2)` literals with named static constants on `ConnectionServer`:

```dart
static const _subscriptionCancelTimeout = Duration(seconds: 5);
static const _handlerCancelTimeout = Duration(seconds: 5);
static const _connectionFinishGracePeriod = Duration(seconds: 5);
static const _connectionTerminateTimeout = Duration(seconds: 2);
```

**Why it matters**: The 5-second value appears at 7 locations across server.dart, named_pipe_server.dart, and named_pipe_transport.dart. Named constants make the relationships between timeouts explicit, eliminate magic numbers, and make future tuning a single-location change. The total worst-case shutdown budget (up to 17s TCP, 22s named pipe) should be documented alongside these constants.

**Effort**: Small (rename literals, add doc comments)

**Flagged by**: Agent 8 (Devil's Advocate, Challenge 6), Agent 12 (Performance Analyst, R3), Agent 13 (Maintainability, Section 3.2 Gap 3)

---

### N2. Add a state-transition diagram to `ServerHandler` class documentation

**What to change**: Add an ASCII state diagram to the class doc comment on `ServerHandler` in `lib/src/server/handler.dart`:

```dart
/// Handler State Machine:
///
///   IDLE --(_onDataIdle)--> ROUTING --(_startStreamingRequest)--> ACTIVE
///                                                                   |
///                    +--------+--------+--------+---------+---------+
///                    |        |        |        |         |
///                 timeout   error   cancel  response   onDone
///                    |        |        |     done         |
///                    v        v        v        v         v
///                 TERMINATED (via _sendError -> sendTrailers -> cleanup)
///
/// Key invariant: once _trailersSent = true, no further stream operations occur.
```

**Why it matters**: `ServerHandler` now has 6+ boolean/sentinel state fields (`_headersSent`, `_trailersSent`, `_hasReceivedRequest`, `_isTimedOut`, `_streamTerminated`, `isCanceled`) plus implicit state in nullable fields. A developer adding a new error path (e.g., a new interceptor hook) could forget to check `_trailersSent`. The state diagram makes the invariants explicit.

**Effort**: Small (documentation only)

**Flagged by**: Agent 13 (Maintainability, Section 1.3)

---

### N3. Sanitize error messages in client-facing gRPC status responses

**What to change**: In `lib/src/server/handler.dart`, replace raw exception interpolation in client-facing error messages with generic descriptions. Log the full details server-side:

```dart
// Instead of:
_sendError(GrpcError.internal('Error processing request: $error'));

// Use:
logGrpcEvent('[gRPC] Error processing request: $error', ...);
_sendError(GrpcError.internal('Error processing request'));
```

Apply to lines 259, 367, and 400 (all `GrpcError.internal('Error ...: $error')` patterns).

**Why it matters**: The `$error` interpolation includes full `toString()` of caught exceptions, which may contain stack traces, file paths, class names, and package versions. These are sent to clients as the `grpc-message` trailer. A malicious client sending crafted malformed payloads can fingerprint the server's internal Dart types and library versions.

**Effort**: Small (change 3 string interpolations, add 3 log calls)

**Flagged by**: Agent 6 (Security Auditor, SEC-3)

---

### N4. Add pipe name validation in `namedPipePath()` or `serve()`

**What to change**: Add input validation for named pipe names in `lib/src/shared/named_pipe_io.dart` or `lib/src/server/named_pipe_server.dart`:

```dart
String namedPipePath(String pipeName) {
  if (pipeName.isEmpty) throw ArgumentError.value(pipeName, 'pipeName', 'must not be empty');
  if (pipeName.contains(r'\') || pipeName.contains('/') || pipeName.contains('\x00')) {
    throw ArgumentError.value(pipeName, 'pipeName', 'must not contain path separators or null bytes');
  }
  if (pipeName.length > 200) {
    throw ArgumentError.value(pipeName, 'pipeName', 'exceeds maximum length (200 characters)');
  }
  return r'\\.\pipe\' + pipeName;
}
```

**Why it matters**: No validation prevents empty names, names with backslashes (creating sub-paths in the pipe namespace), names with null bytes (truncating the native UTF-16 string), or excessively long names. If pipe names are ever constructed from user-controlled input, these become injection vectors.

**Effort**: Small (add ~10 lines of validation)

**Flagged by**: Agent 6 (Security Auditor, SEC-2)

---

### N5. Default `maxInstances` to a bounded value instead of `PIPE_UNLIMITED_INSTANCES`

**What to change**: In `lib/src/server/named_pipe_server.dart:170`, change the default from `PIPE_UNLIMITED_INSTANCES` to a sensible bounded value:

```dart
Future<void> serve({
  required String pipeName,
  int maxInstances = 128,  // was PIPE_UNLIMITED_INSTANCES
}) async {
```

**Why it matters**: With unlimited instances, a local attacker can open pipe connections as fast as the server creates them. Each connection consumes 128KB of kernel buffer plus Dart-side allocations. At ~1000 connections/second accept rate, an attacker accumulates ~128MB/s of kernel buffer allocations without any limit, exhausting system memory in minutes.

**Effort**: Trivial (change one default value)

**Flagged by**: Agent 6 (Security Auditor, SEC-5)

---

### N6. Cancel keepalive subscriptions when `tooManyBadPings` fires

**What to change**: In the `tooManyBadPings` callback path in `lib/src/server/server.dart:152-157` or within the keepalive manager, close the `onDataReceivedController` and cancel the `pingNotifier`/`dataNotifier` subscriptions when ENHANCE_YOUR_CALM is triggered.

**Why it matters**: After `connection.terminate(ErrorCode.ENHANCE_YOUR_CALM)`, the ping listener continues processing incoming pings (incrementing `_badPings` uselessly). If `terminate()` does not fully close the connection in all edge cases, the server retains the connection in memory with active subscriptions consuming CPU.

**Effort**: Small (add subscription cancellation calls to the tooManyBadPings callback)

**Flagged by**: Agent 6 (Security Auditor, SEC-4)

---

### N7. Document the Windows 15.6ms timer resolution in source code comments

**What to change**: Update the polling delay comments in `lib/src/server/named_pipe_server.dart` (accept loop at ~line 1047 and read loop at ~line 544) and `lib/src/client/named_pipe_transport.dart` (~line 418) to reflect the actual behavior:

```dart
// On Windows, Future.delayed(Duration(milliseconds: 1)) actually waits
// ~15.6ms due to the default OS timer resolution. This means the actual
// poll interval is ~15.6ms, not 1ms. This affects accept loop
// responsiveness and read latency for the first message in a new burst.
// See MEMORY.md "Windows Timer Resolution Key Facts" for details.
await Future.delayed(const Duration(milliseconds: 1));
```

**Why it matters**: The code comments say "1ms" but the actual behavior is 15.6ms on Windows. This affects accept loop responsiveness during shutdown (up to 15.6ms, not "1-2ms" as stated), read latency for the first message in a new burst, and shutdown stop signal processing time. Accurate comments prevent developers from making timing assumptions based on the stated 1ms.

**Effort**: Trivial (update 3-4 comments)

**Flagged by**: Agent 8 (Devil's Advocate, Challenge 4), Agent 12 (Performance Analyst, Section 3)

---

### N8. Add an ASCII flow diagram to `_finishConnection()` showing the three completion paths

**What to change**: Add a doc comment to `_finishConnection()` in `lib/src/server/server.dart:354`:

```dart
/// Connection finish with bounded deadline:
///
///   connection.finish()
///       |
///       +-- success (.then) --> complete() --> done.future completes
///       |
///       +-- error (.catchError) --> forceTerminate()
///       |                              |
///       |                              +-- terminate().then --> complete()
///       |                              |
///       |                              +-- terminate() timeout (2s) --> socket.destroy()
///       |
///       +-- 5s Timer fires --> forceTerminate() (same as above)
///
///   Invariants:
///   - complete() is guarded by Completer.isCompleted (no double-complete)
///   - forceTerminate() is guarded by terminateCalled (no double-terminate)
///   - done.future always completes within 7 seconds
```

**Why it matters**: The method has three racing completion paths with two deduplication guards. The current comments explain the *why* but not the *which-path-when*. A developer adding a fourth path must understand the race topology to replicate both guards correctly.

**Effort**: Trivial (add a doc comment)

**Flagged by**: Agent 13 (Maintainability, Section 1.2)

---

### N9. Reduce `Future.delayed` usage in `handler_regression_test.dart` and `transport_guard_test.dart`

**What to change**: Replace the ~20 occurrences of `Future.delayed(Duration(milliseconds: 50-100))` used as synchronization barriers with Completer-based signals. The `TrackingServerStream` and `TrackingHarness` infrastructure can expose `Completer<void>` fields that complete when trailers are sent or when the handler completes. Example:

```dart
// Instead of:
await Future.delayed(const Duration(milliseconds: 100));

// Use:
await harness.trailersSent.timeout(const Duration(seconds: 2));
```

Similarly, in `transport_guard_test.dart`, replace the 50ms delays with per-stream `firstItemCompleter` patterns (already used in `rst_stream_stress_test.dart` lines 97-101).

**Why it matters**: CLAUDE.md Rule 1 violation ("Never use arbitrary `Future.delayed(...)` as synchronization"). While flake risk is low for unit-level harness tests, the pattern sets a bad precedent. The `rst_stream_stress_test.dart` covering the same shutdown scenario already uses proper Completer-based barriers, proving the pattern is feasible.

**Effort**: Medium (refactor ~20 call sites across 2 test files, add Completer fields to test harnesses)

**Flagged by**: Agent 10 (Test Auditor, TAUDIT-1, TAUDIT-3)

---

### N10. Add a test for the dispatch loop mid-GOAWAY re-queue path (REG-13)

**What to change**: In `test/dispatch_requeue_test.dart`, add a test where:
1. A client channel accumulates multiple pending calls
2. The server sends GOAWAY after the first call is dispatched but before all pending calls are dispatched
3. The test verifies that remaining calls are re-queued (not failed) and eventually succeed after reconnection with backoff

**Why it matters**: The dispatch loop yield (REG-13, HIGH severity) introduces a window where GOAWAY can interleave with mid-dispatch. The current `dispatch_requeue_test.dart` tests normal convergence but not the adversarial mid-dispatch state change that triggers the batch re-queue + backoff logic. This is the PR's most significant client-side behavioral change.

**Effort**: Medium (one new test, requires test infrastructure to inject GOAWAY at a specific point during dispatch)

**Flagged by**: Agent 10 (Test Auditor, Critical Gap #3), Agent 5 (Regression Detective, REG-13)

---

### N11. Document the shutdown time budget in the `Server` class comment

**What to change**: Add a doc comment to `Server` or `ConnectionServer` documenting the worst-case shutdown timeline:

```dart
/// Shutdown Time Budget:
///
/// TCP Server:
///   Step 1 (subscription cancel):  up to 5s
///   Step 1.5 (controller close):   ~0ms (synchronous)
///   Step 2 (handler cancel):       up to 5s
///   Step 3 (RST_STREAM flush):     ~0ms (single yield)
///   Step 4 (connection finish):    up to 5s + 2s terminate fallback
///   Total worst-case:              ~17 seconds
///
/// Named Pipe Server:
///   Above + isolate exit:          up to 5s
///   Total worst-case:              ~22 seconds
///
/// Steps 4 runs all connections in parallel via Future.wait,
/// so worst-case is bounded regardless of connection count.
```

**Why it matters**: Deployment environments need to set SIGTERM grace periods (e.g., Kubernetes terminationGracePeriodSeconds) to accommodate the maximum shutdown time. Without this documentation, operators must read the source code to determine the budget. The Devil's Advocate found that AWS Lambda's 3-second timeout exceeds even a single 5-second step.

**Effort**: Trivial (add a doc comment)

**Flagged by**: Agent 8 (Devil's Advocate, Challenge 6), Agent 12 (Performance Analyst, Section 4)

---

### N12. Rename `catch (_)` to `catch (e)` in `named_pipe_server.dart:233`

**What to change**: In `lib/src/server/named_pipe_server.dart:233`, change `catch (_)` to `catch (e)` for consistency with CLAUDE.md Rule 5, even though the error is rethrown:

```dart
} catch (e) {
  // Cleanup on failure: the isolate and receive port would otherwise leak
  ...
  rethrow;
}
```

**Why it matters**: While the `catch (_)` with `rethrow` is functionally correct (no information is lost), the underscore pattern is a code-review red flag under CLAUDE.md Rule 5 ("No `catch (_)`"). Renaming to `catch (e)` eliminates the false positive without changing behavior.

**Effort**: Trivial (rename one variable)

**Flagged by**: Agent 7 (Contract Enforcer, VIOL-3)

---

### N13. Consider adaptive polling for named pipe read loops

**What to change**: In the read loops of `named_pipe_server.dart` and `named_pipe_transport.dart`, implement a simple adaptive polling strategy:

```dart
int consecutiveEmptyPolls = 0;
while (!_isClosed) {
  PeekNamedPipe(_handle, nullptr, 0, nullptr, peekAvail, nullptr);
  if (peekAvail.value == 0) {
    consecutiveEmptyPolls++;
    final delay = consecutiveEmptyPolls < 10
        ? Duration.zero            // Aggressive: sub-ms for recent data
        : Duration(milliseconds: 1); // Back off when truly idle
    await Future.delayed(delay);
    continue;
  }
  consecutiveEmptyPolls = 0;
  // ... ReadFile
}
```

**Why it matters**: The fixed 1ms polling interval creates a latency floor of up to 15.6ms on Windows for every read when data arrives between polls. Adaptive polling reduces the latency to near-zero for bursty workloads (common in streaming RPCs) while maintaining the idle CPU benefits.

**Effort**: Small (add a counter and conditional delay, ~10 lines per read loop)

**Flagged by**: Agent 12 (Performance Analyst, R2), Agent 8 (Devil's Advocate, Challenge 4)

---

### N14. Document the `expectExpectedRpcSettlement` vs `expectHardcoreRpcSettlement` distinction

**What to change**: Add doc comments to both functions in `test/common.dart` explaining why `expectExpectedRpcSettlement` accepts `StateError` but `expectHardcoreRpcSettlement` does not:

```dart
/// Asserts that an RPC settled with an expected result type.
/// Accepts StateError because [reason: e.g., "transport-level errors
/// from closed sinks are expected during concurrent shutdown scenarios"].
void expectExpectedRpcSettlement(...) { ... }

/// Stricter variant that rejects StateError, used for scenarios where
/// transport errors indicate a real bug rather than expected shutdown behavior.
void expectHardcoreRpcSettlement(...) { ... }
```

**Why it matters**: Future test authors need to know which assertion helper to use and why. The distinction between "expected transport error" and "bug indicator" is not currently documented, which could lead to tests using the wrong variant and hiding real failures.

**Effort**: Trivial (add doc comments)

**Flagged by**: Agent 13 (Maintainability, Section 5.2)

---

### N15. Document the upstream `package:http2` dependency for the RST_STREAM yield

**What to change**: In `lib/src/server/server.dart:328-330`, add a comment documenting the implementation dependency:

```dart
// Step 3: Yield one event-loop turn for RST_STREAM frame flushing.
//
// This relies on package:http2's ConnectionMessageQueueOut.enqueueMessage
// being synchronous -- all RST_STREAM frames from handler.cancel() in
// Step 2 are queued before this yield. A single yield allows the http2
// transport's write callback to drain the entire queued buffer.
//
// If a future version of package:http2 defers write scheduling (e.g.,
// batches frames across multiple event-loop turns), this single yield
// would be insufficient and Step 4's 5s deadline would catch the gap.
await Future.delayed(Duration.zero);
```

**Why it matters**: The single yield is the most fragile novel pattern in the PR (identified by the Contextualizer as having no parallel in C++, Go, or Java gRPC). It works because of an implementation detail of `package:http2`. If that package changes its flushing strategy, the yield becomes silently insufficient. Documenting the dependency ensures that an upstream http2 update triggers review of this code.

**Effort**: Trivial (add a comment)

**Flagged by**: Agent 9 (Contextualizer, Section 3), Agent 8 (Devil's Advocate, Challenge 2), Agent 11 (Systems Thinker, RISK-3)

---

## 3. Informational

These items are awareness notes. No action is required, but they provide context for future development decisions.

---

### I1. All 22 behavioral regressions are intentional bug fixes

The Regression Detective (Agent 5) identified 22 behavioral changes (2 HIGH, 5 MEDIUM, 15 LOW). All 22 are deliberate corrections aligned with gRPC specification or Dart SDK contracts. Zero accidental regressions were found. The two HIGH-severity items (keepalive comparison inversion REG-1, async dispatch loop REG-13) are the most impactful for existing deployments but are both spec-correct.

**Flagged by**: Agent 5 (Regression Detective)

---

### I2. Named pipe NULL SECURITY_ATTRIBUTES is a design-level item, not a PR-level fix

SEC-1 (NULL DACL on `CreateNamedPipe`) is a HIGH-severity security finding for multi-user Windows systems. However, constructing explicit `SECURITY_ATTRIBUTES` with a restrictive DACL requires significant Win32 FFI work (SECURITY_DESCRIPTOR, InitializeSecurityDescriptor, SetSecurityDescriptorDacl, SID lookup). This is appropriately scoped as a separate feature/issue, not a fix within this PR. It should be tracked as a follow-up issue.

**Flagged by**: Agent 6 (Security Auditor, SEC-1), Agent 10 (Test Auditor, Design-Level Gap)

---

### I3. The two-isolate named pipe architecture is over-engineered given PIPE_NOWAIT but defensible

The Devil's Advocate (Agent 8) argued that since the PR already implements `PIPE_NOWAIT` non-blocking polling, the accept loop could run in the main isolate, eliminating ~200 lines of isolate lifecycle code. The counter-argument: the isolate provides a clean failure boundary for FFI crashes, and removing it would be a separate simplification effort. If PIPE_NOWAIT is the permanent solution, this should be tracked as technical debt for a future simplification pass.

**Flagged by**: Agent 8 (Devil's Advocate, Challenge 3)

---

### I4. Pre-existing gap: Dart keepalive does not reset ping strikes on data frames

Both gRPC C++ and Go reset the ping strike counter when data frames are received/sent. The Dart implementation's `_badPings` counter is never reset by data activity. This makes the Dart server stricter than reference implementations: a connection that sends bursts of fast pings interspersed with data will accumulate strikes permanently in Dart but get reset in C++/Go. This is a pre-existing behavioral difference not introduced by this PR.

**Flagged by**: Agent 9 (Contextualizer, Section 2)

---

### I5. Pre-existing gap: No double-GOAWAY pattern in shutdown

gRPC Go and Java both implement a double-GOAWAY pattern: send GOAWAY(MAX_STREAM_ID) first to signal "stop creating streams," then PING to probe RTT, then send GOAWAY(real_lastStreamId). The PR's shutdown uses a single GOAWAY from `connection.finish()`. This is a limitation of `package:http2`, not something the PR can fix. Clients that create a stream between the server's decision to shut down and receipt of GOAWAY will get an unrecoverable error rather than a retryable one.

**Flagged by**: Agent 9 (Contextualizer, Section 1)

---

### I6. The `_incomingSubscription.cancel()` return value is not awaited (pre-existing)

Four call sites in `handler.dart` invoke `_incomingSubscription?.cancel()` without awaiting the returned Future. Per the Dart `StreamSubscription` contract, `cancel()` returns a Future that completes when the subscription is fully terminated. This is a pre-existing pattern from upstream grpc-dart (not introduced by this PR). The `_incomingSubscription` is an HTTP/2 frame listener whose cancel is typically synchronous in the http2 package. No action needed for this PR.

**Flagged by**: Agent 7 (Contract Enforcer, VIOL-2)

---

### I7. Performance impact of this PR is minimal in steady-state

The Performance Analyst (Agent 12) confirmed zero measurable overhead on the normal (non-error) data path. The dispatch loop yield adds ~10us/call only during post-reconnect burst dispatch. Named pipe polling introduces an inherent 0-15.6ms latency floor acceptable for local IPC. Shutdown is bounded at 17-22s worst-case (improvement over the old code's unbounded shutdown). Memory overhead is ~320-472 bytes per connection. The most performance-positive change is the handler leak fix (`isCanceled = true` in `sendTrailers`), which eliminates unbounded memory growth.

**Flagged by**: Agent 12 (Performance Analyst)

---

### I8. The `logGrpcEvent` catch-all in `logging_io.dart` is a justified CLAUDE.md Rule 5 exception

The `catch (_)` in `logGrpcEvent()` silently swallows errors from user-provided custom loggers. This technically violates CLAUDE.md Rule 5, but the trade-off is correct for a library: logging must never crash the server. The CLAUDE.md rule should acknowledge this exception for logging infrastructure code. No action needed in the PR.

**Flagged by**: Agent 13 (Maintainability, Section 6.2)

---

### I9. Test suite coverage is strong -- 500 tests passed, 0 failures

The Test Auditor confirmed 84 new/modified test functions across 30 test files. The highest-risk fixes have strong, direct coverage. 4 critical gaps were identified (S1/S7/S8 in this document, plus BUG-1 forceTerminate), of which 3 have overlapping integration coverage. The test-to-production code ratio (~3:1) is appropriate for concurrency and race-condition fixes.

**Flagged by**: Agent 10 (Test Auditor)

---

## Summary Statistics

| Priority | Count | Effort Breakdown |
|----------|-------|-----------------|
| **Should Fix Soon** | 10 | 6 trivial, 3 small, 1 medium |
| **Nice to Have** | 15 | 8 trivial, 5 small, 2 medium |
| **Informational** | 9 | N/A (no action) |
| **Total** | 34 | |

### Agent Attribution

| Agent | Suggestions Contributed |
|-------|------------------------|
| Agent 4 (Bug Hunter) | S1, S4, S6, S9 |
| Agent 5 (Regression Detective) | S8, N10, I1 |
| Agent 6 (Security Auditor) | S10, N3, N4, N5, N6, I2 |
| Agent 7 (Contract Enforcer) | S2, N12, I6 |
| Agent 8 (Devil's Advocate) | S1, S5, N1, N7, N8, N11, N13, N15, I3, I5 |
| Agent 9 (Contextualizer) | N15, I4, I5 |
| Agent 10 (Test Auditor) | S7, S8, N9, N10, I9 |
| Agent 11 (Systems Thinker) | S1, N15 |
| Agent 12 (Performance Analyst) | N1, N11, N13, I7 |
| Agent 13 (Maintainability) | S3, N1, N2, N8, N14, I8 |
