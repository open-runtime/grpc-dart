# Phase 2 -- Agent 5: Regression Detective

## Regressions Found

---

### [REG-1] Keepalive Comparison Inversion Changes Which Clients Get ENHANCE_YOUR_CALM
**Behavior Change:** In `server_keepalive.dart`, the comparison `_timeOfLastReceivedPing!.elapsed > options.minIntervalBetweenPingsWithoutData` was changed to `<`. On `main`, a "bad ping" was counted when the elapsed time *exceeded* the minimum interval (slow pings were penalized). The fix inverts this so fast pings (below the minimum interval) are penalized, which matches the gRPC C++ reference implementation.

**Before (main):** Clients sending pings *slower* than the configured minimum interval (default 5 minutes) were penalized. Clients sending rapid pings were tolerated. This is backwards, but any server running in production with `maxBadPings > 0` has adapted to this behavior -- their clients are slow-ping-safe or they set `maxBadPings` to null/0.

**After (PR):** Clients sending pings *faster* than the minimum interval are penalized. Clients that were previously fine (sending fast keepalive pings) will now receive ENHANCE_YOUR_CALM and be disconnected.

**Additional sub-changes:**
- Stopwatch is now reset on every ping (not just the first). On `main`, the stopwatch was never reset after the first ping, so `elapsed` grew monotonically. This means on `main`, only the *second* ping could ever be a "bad ping" (since `elapsed` only gets larger over time, it eventually always exceeds the threshold). After the fix, each ping interval is measured independently.
- `_tooManyBadPingsTriggered` flag prevents calling `tooManyBadPings` more than once. On `main`, the callback could fire on every subsequent ping after hitting `maxBadPings`.

**Affected Users:** Any server with `maxBadPings > 0` (default is 2) paired with clients that send pings faster than `minIntervalBetweenPingsWithoutData` (default 5 minutes). This is the correct behavior per gRPC spec, but it reverses the actual enforcement direction.

**Severity:** HIGH

**Intentional:** Yes -- this is a deliberate bug fix aligning with the gRPC C++ reference implementation. The old behavior was objectively wrong, but servers in production may have unknowingly relied on the broken behavior.

**Evidence:**
```dart
// main (WRONG):
} else if (_timeOfLastReceivedPing!.elapsed > options.minIntervalBetweenPingsWithoutData) {
  _badPings++;
}

// PR (CORRECT):
} else if (_timeOfLastReceivedPing!.elapsed < options.minIntervalBetweenPingsWithoutData) {
  _badPings++;
  _timeOfLastReceivedPing!..reset()..start();
} else {
  _timeOfLastReceivedPing!..reset()..start();
}
```

**Mitigation:** This is a correct fix. Callers relying on the broken behavior should adjust their client keepalive intervals. The 5-minute default threshold is generous -- only aggressive sub-5-minute ping patterns are affected.

---

### [REG-2] Server Shutdown Ordering Changed: Sequential Instead of Parallel
**Behavior Change:** `Server.shutdown()` was restructured from a single parallel `Future.wait()` (close server sockets + finish all connections simultaneously) to a sequential flow: first close server sockets, then run `shutdownActiveConnections()` which has a 4-step process with multiple 5-second timeouts.

**Before (main):**
```dart
await Future.wait([
  for (var connection in _connections) connection.finish(),
  if (_insecureServer != null) _insecureServer!.close(),
  if (_secureServer != null) _secureServer!.close(),
]);
```
All connections finished in parallel with server socket closure. Shutdown was unbounded in time (no timeouts). If `connection.finish()` hung, shutdown hung forever.

**After (PR):**
```dart
await Future.wait([if (insecure != null) insecure.close(), if (secure != null) secure.close()]);
await shutdownActiveConnections(); // 4-step with 5s+5s+5s+2s timeouts
```
Server sockets close first (no new connections), then active connections drain through a structured 4-step process. Maximum shutdown time is bounded at roughly 17 seconds worst case.

**Affected Users:** All TCP/TLS server users.

**Severity:** MEDIUM

**Intentional:** Yes -- the new ordering prevents the deadlock where `connection.finish()` waits for streams that active handlers keep open. However, the maximum ~17-second bounded shutdown (5s sub cancel + 5s handler cancel + 5s finish + 2s terminate) is a new wall-clock constraint that did not exist before. Callers who relied on instant unbounded shutdown semantics (or who set their own process-level timeouts) may see different behavior.

**Evidence:** `lib/src/server/server.dart` lines 616-629 (new) vs main lines 329-350 (old)

**Mitigation:** The bounded shutdown is strictly better for production. If the 5-second per-step timeouts are too aggressive, they should be configurable (they are currently hardcoded `const Duration(seconds: 5)`).

---

### [REG-3] `_onTimedOut` Now Terminates the HTTP/2 Stream (New RST_STREAM on Deadline)
**Behavior Change:** In `handler.dart`, `_onTimedOut()` previously only sent the deadline error to the request stream and emitted error trailers. The PR adds `_cancelResponseSubscription()`, `_incomingSubscription?.cancel()`, and `_terminateStream()`, which sends RST_STREAM to the client.

**Before (main):** On deadline expiry, the server sent error trailers (grpc-status: DEADLINE_EXCEEDED) but did NOT terminate the HTTP/2 stream. The stream stayed open, and the client-side transport could continue sending data.

**After (PR):** On deadline expiry, the server sends error trailers AND terminates the HTTP/2 stream with RST_STREAM. The response subscription is also cancelled.

**Affected Users:** All server users with RPC deadlines configured.

**Severity:** MEDIUM

**Intentional:** Yes -- the old behavior leaked server-side resources after deadline expiry. However, clients that were tolerant of the half-open state (e.g., sending additional data after deadline) will now see RST_STREAM.

**Evidence:**
```dart
// PR adds these three lines to _onTimedOut():
_cancelResponseSubscription();
_incomingSubscription?.cancel();
_terminateStream();
```

**Mitigation:** This is correct per gRPC semantics -- deadline expiry should fully terminate the stream. Clients that depended on sending data after a server deadline are violating the protocol.

---

### [REG-4] `_onDoneError` Now Terminates the HTTP/2 Stream
**Behavior Change:** In `handler.dart`, `_onDoneError()` (called when the request stream closes unexpectedly) previously only sent error trailers and closed the request controller. The PR adds `_terminateStream()`.

**Before (main):**
```dart
void _onDoneError() {
    _sendError(GrpcError.unavailable('Request stream closed unexpectedly'));
    _onDone();
}
```
No RST_STREAM sent. HTTP/2 stream left in an ambiguous state.

**After (PR):**
```dart
void _onDoneError() {
    _sendError(GrpcError.unavailable('Request stream closed unexpectedly'));
    _onDone();
    _terminateStream();
}
```

**Affected Users:** All server users where clients disconnect unexpectedly mid-stream.

**Severity:** LOW

**Intentional:** Yes -- prevents resource leaks on unexpected client disconnects.

**Evidence:** `lib/src/server/handler.dart` _onDoneError method

**Mitigation:** Correct behavior. No user action needed.

---

### [REG-5] `cancel()` Now Closes `_requests` Stream and Cancels `_incomingSubscription`
**Behavior Change:** `ServerHandler.cancel()` was previously minimal: set `isCanceled`, cancel timeout, cancel response subscription, terminate stream. The PR adds: close `_requests` with a cancellation error, cancel `_incomingSubscription`, and conditionally skip `_terminateStream()` if trailers were already sent.

**Before (main):**
```dart
void cancel() {
    isCanceled = true;
    _timeoutTimer?.cancel();
    _cancelResponseSubscription();
    _terminateStream();
}
```
Handler methods blocked on `await for (final request in requests)` would hang indefinitely because `_requests` was never closed.

**After (PR):** Handler methods are unblocked with `GrpcError.cancelled('Cancelled')`, incoming subscription is cancelled, and RST_STREAM is only sent if trailers haven't already been sent.

**Affected Users:** All server users. Specifically, server-side streaming or bidi handlers that `await for` on the request stream during server shutdown.

**Severity:** MEDIUM

**Intentional:** Yes -- prevents `Server.shutdown()` from hanging when handlers are blocked on request streams.

**Evidence:** `lib/src/server/handler.dart` cancel() method, lines 588-617

**Mitigation:** Correct fix. Handlers will now see `GrpcError.cancelled('Cancelled')` in their request stream during shutdown, which is the expected gRPC cancellation pattern. Handlers that catch generic exceptions and retry will see different behavior.

---

### [REG-6] `sendTrailers()` Now Sets `isCanceled = true` (Handlers Complete via Cancellation Path)
**Behavior Change:** After sending trailers, `sendTrailers()` now sets `isCanceled = true`. This causes `onCanceled` (the Completer-based future) to complete, which triggers the `handler.onCanceled.then((_) => handlers[connection]?.remove(handler))` cleanup in `serveConnection`.

**Before (main):** Normal RPC completion (response done -> sendTrailers) did NOT complete the `_isCanceledCompleter`. Handlers were never removed from the `handlers` map until the connection itself was torn down by onDone.

**After (PR):** Handlers are removed from the map immediately after trailers are sent. The `handlers` map is kept trimmed, and `shutdownActiveConnections()` sees fewer handlers to cancel.

**Affected Users:** All server users.

**Severity:** LOW

**Intentional:** Yes -- fixes a handler leak in the `handlers` map. However, any code that inspects `handlers[connection]` after a normal RPC completes will see fewer entries than before.

**Evidence:**
```dart
// Added at end of sendTrailers():
isCanceled = true;
```

**Mitigation:** Correct fix. The `handlers` map should be kept clean. The `isCanceled` setter is idempotent (Completer.complete is a no-op if already completed).

---

### [REG-7] `_onResponseError` Now Closes `_requests` Stream
**Behavior Change:** In `handler.dart`, `_onResponseError()` previously only sent the error via trailers. The PR adds `_addErrorAndClose(_requests, ...)` which closes the request stream.

**Before (main):**
```dart
void _onResponseError(Object error, StackTrace trace) {
    if (error is GrpcError) {
      _sendError(error, trace);
    } else {
      _sendError(GrpcError.unknown(error.toString()), trace);
    }
}
```
The request stream was left open. Bidi handlers could theoretically continue reading requests after a response error.

**After (PR):** Request stream is closed with the error. Bidi handlers blocked on `await for` will be unblocked.

**Affected Users:** Server users with bidi streaming RPCs where the response stream errors but the handler wants to continue reading requests.

**Severity:** MEDIUM

**Intentional:** Yes -- prevents bidi handlers from hanging indefinitely when the response stream errors.

**Evidence:** `_addErrorAndClose(_requests, grpcError, trace, '_onResponseError')` added to `_onResponseError()`

**Mitigation:** This is correct cleanup behavior. Bidi handlers that intentionally continued after response errors were relying on undefined behavior.

---

### [REG-8] `outgoingMessages.done.then` Changed to `.whenComplete` in handler.dart
**Behavior Change:** In `handler.dart`, the outgoing messages done callback was changed from `.then((_) { cancel(); })` to `.whenComplete(() { cancel(); })`.

**Before (main):** `cancel()` was only called when `outgoingMessages.done` completed *successfully*. If `done` completed with an error, `cancel()` was NOT called, and the error was unhandled.

**After (PR):** `cancel()` is called regardless of whether `done` completed normally or with an error.

**Affected Users:** All server users where outgoing message streams complete with an error (e.g., transport errors during response sending).

**Severity:** LOW

**Intentional:** Yes -- fixes a case where cancel was not called on error completion, potentially leaking handlers.

**Evidence:** `lib/src/server/handler.dart` line 145: `.done.whenComplete(() {` vs `.done.then((_) {`

**Mitigation:** Correct fix. Error completion of the outgoing stream should trigger cleanup.

---

### [REG-9] `_applyInterceptors` Now Preserves GrpcError Status Codes
**Behavior Change:** When an interceptor throws a `GrpcError`, the old code wrapped it in `GrpcError.internal(error.toString())`, losing the original status code. The PR adds `if (error is GrpcError) return error;` before the wrapping.

**Before (main):**
```dart
} catch (error) {
    final grpcError = GrpcError.internal(error.toString());
    return grpcError;
}
```
All interceptor exceptions became INTERNAL (code 13).

**After (PR):**
```dart
} catch (error) {
    if (error is GrpcError) return error;
    final grpcError = GrpcError.internal(error.toString());
    return grpcError;
}
```
GrpcError exceptions preserve their original status code.

**Affected Users:** All server users with interceptors that throw GrpcError (e.g., `GrpcError.unauthenticated()`, `GrpcError.permissionDenied()`).

**Severity:** MEDIUM (behavioral change, but a *correction*)

**Intentional:** Yes -- interceptors that deliberately throw `GrpcError.unauthenticated()` expect clients to see status 16, not status 13.

**Evidence:** `lib/src/server/handler.dart` _applyInterceptors method

**Mitigation:** This is a correct fix. However, clients that were keying on `INTERNAL` status from interceptor errors will now see the actual status code. This is a semantic improvement but technically a behavioral change.

---

### [REG-10] Client `makeRequest` Throws `GrpcError.unavailable` Instead of `ArgumentError`
**Behavior Change:** In `http2_connection.dart`, `makeRequest()` previously threw `ArgumentError('Trying to make request on null connection')` when the transport connection was null. The PR changes this to `GrpcError.unavailable('Connection not ready')`.

**Before (main):**
```dart
throw ArgumentError('Trying to make request on null connection');
```
Callers catching `ArgumentError` would see this. The error was also not a proper gRPC error, making client-side status handling inconsistent.

**After (PR):**
```dart
throw GrpcError.unavailable('Connection not ready');
```

**Affected Users:** Client users that catch `ArgumentError` from `makeRequest`. Also affects any error-type assertions in tests.

**Severity:** MEDIUM (exception type change)

**Intentional:** Yes -- `GrpcError.unavailable` is semantically correct and allows clients to handle this via standard gRPC status code processing.

**Evidence:** `lib/src/client/http2_connection.dart` makeRequest method

**Mitigation:** Correct fix. Client code that was catching `ArgumentError` specifically (unlikely but possible) should catch `GrpcError` instead. The `GrpcError` is automatically propagated to the client call's response stream.

---

### [REG-11] SETTINGS Frame Wait Changed from Fixed 20ms Delay to Event-Driven with 100ms Timeout
**Behavior Change:** `connectTransport()` previously waited a fixed 20ms (`_estimatedRoundTripTime`) for the peer's SETTINGS frame. The PR replaces this with `await connection.onInitialPeerSettingsReceived.timeout(100ms)`.

**Before (main):** Always waited exactly 20ms, regardless of whether SETTINGS arrived. Fast peers wasted time; slow peers (>20ms RTT) started RPCs before SETTINGS were processed.

**After (PR):** Waits up to 100ms for the actual SETTINGS frame. If SETTINGS arrives in 2ms, proceeds immediately. If it doesn't arrive in 100ms, proceeds anyway.

**Affected Users:** All client users.

**Severity:** LOW

**Intentional:** Yes -- the 20ms delay was a self-documented hack. The event-driven approach is correct and the 100ms safety timeout is generous.

**Evidence:** `lib/src/client/http2_connection.dart` connectTransport method. Depends on `http2 2.3.1+` which exposes `onInitialPeerSettingsReceived`.

**Mitigation:** The 100ms timeout is 5x the previous fixed delay, providing more headroom for slow peers. Connections that consistently take >100ms for SETTINGS exchange will fall through to the same behavior as the old 20ms delay (proceed optimistically).

---

### [REG-12] Client `shutdown()` and `terminate()` Now Call `_transportConnector.shutdown()` (Socket Destruction)
**Behavior Change:** On `main`, `Http2ClientConnection.shutdown()` only called `transportConnection.finish()` and stopped the keepalive manager. It did NOT destroy the underlying socket/connector. The PR adds `_disconnect()` and `_transportConnector.shutdown()` which calls `socket.destroy()`.

**Before (main):** After shutdown, the raw socket was left intact. The `SocketTransportConnector` could theoretically be reused (though this is unlikely in practice).

**After (PR):** After shutdown, the raw socket is destroyed. This is a terminal operation -- the connector cannot be reused.

**Affected Users:** Client users who call `channel.shutdown()` or `channel.terminate()`.

**Severity:** LOW

**Intentional:** Yes -- prevents socket/pipe handle leaks, especially on named pipes where the OS resource stays alive until explicitly destroyed.

**Evidence:**
```dart
// PR adds to shutdown():
_disconnect();
_transportConnector.shutdown();

// PR adds to terminate():
_disconnect();
_transportConnector.shutdown();
```

**Mitigation:** Correct fix. Socket leaks after shutdown are a bug. Any code that reuses a connection after calling shutdown was already relying on undefined behavior.

---

### [REG-13] Dispatch Loop Now Yields Between Calls (Async Behavior Change)
**Behavior Change:** In `http2_connection.dart`, the pending call dispatch after connection ready was changed from synchronous `pendingCalls.forEach(dispatchCall)` to an async loop with `await Future.delayed(Duration.zero)` between each call.

**Before (main):** All pending calls were dispatched synchronously in a single event-loop turn. The connection state could not change between dispatches.

**After (PR):** Each pending call dispatch is followed by a microtask yield. Between yields, the connection state can change (e.g., GOAWAY received). Calls dispatched after a state change are re-queued with backoff or failed with shutdown error.

**Affected Users:** All client users with multiple pending calls during reconnection.

**Severity:** HIGH

**Intentional:** Yes -- the synchronous burst could exhaust flow-control windows on non-TCP_NODELAY transports. However, this changes the observable dispatch order and timing: previously, all pending calls were dispatched atomically; now, intermediate GOAWAY/RST frames can interleave.

**Evidence:**
```dart
// main:
pendingCalls.forEach(dispatchCall);

// PR:
for (final call in pendingCalls) {
  if (_state != ConnectionState.ready) { /* re-queue or fail */ }
  dispatchCall(call);
  await Future.delayed(Duration.zero);
  if (_state == ConnectionState.ready) {
    _connectionLifeTimer..reset()..start();
  }
}
```

**Mitigation:** The yield is necessary for transport correctness, but it introduces a window where connection state can change mid-dispatch. Calls that would have all succeeded (dispatched before a GOAWAY) may now be partially re-queued. The re-queue uses proper exponential backoff, which is correct but changes the retry timing from the old synchronous pattern.

---

### [REG-14] `onTransportIdle` Calls Removed from `_handleConnectionFailure` and `_abandonConnection`
**Behavior Change:** Two calls to `keepAliveManager?.onTransportIdle()` were removed: one in `_handleConnectionFailure` and one in `_abandonConnection` (the no-pending-calls branch). The `_disconnect()` method now calls `onTransportTermination()` (via its existing logic), and `keepAliveManager` is set to `null` after.

**Before (main):** `onTransportIdle()` was called in failure/abandon paths, which notified the keepalive manager that the transport was idle (not terminated). `onTransportTermination()` was called separately in `_disconnect()`.

**After (PR):** Only `onTransportTermination()` (called inside `_disconnect()`) is used. `onTransportIdle()` is never called from these paths.

**Affected Users:** Client users with keepalive configured.

**Severity:** LOW

**Intentional:** Yes -- since `_disconnect()` sets `keepAliveManager = null`, calling `onTransportIdle()` beforehand was redundant. The manager is about to be destroyed. However, if `ClientKeepAlive.onTransportIdle()` had side effects beyond the manager instance (unlikely), those are lost.

**Evidence:** Removed `-keepAliveManager?.onTransportIdle();` from two locations

**Mitigation:** Correct cleanup. The keepalive manager is nulled out by `_disconnect()` immediately after, making the idle notification meaningless.

---

### [REG-15] Proxy `_waitForResponse` Error Handling Changed from `throw` to `completer.completeError`
**Behavior Change:** In `http2_connection.dart`, the proxy response handler previously threw `TransportException` synchronously (which would be an uncaught exception in a stream listener). The PR changes this to `completer.completeError(...)`.

**Before (main):**
```dart
print(response);
if (response.startsWith('HTTP/1.1 200')) {
  completer.complete();
} else {
  throw TransportException('Error establishing proxy connection: $response');
}
```
The `throw` inside a stream listener would be an unhandled async error. The `print()` call also leaked proxy response data to stdout.

**After (PR):**
```dart
if (response.startsWith('HTTP/1.1 200')) {
  completer.complete();
} else {
  completer.completeError(TransportException('Error establishing proxy connection: $response'));
}
```
Error is properly delivered to the completer. `print()` is removed.

**Affected Users:** Client users connecting through HTTP proxies.

**Severity:** MEDIUM

**Intentional:** Yes -- fixes unhandled async exception and removes debug `print()`.

**Evidence:** `lib/src/client/http2_connection.dart` `_waitForResponse` method

**Mitigation:** This is a correct fix. The `throw` inside a listener was a bug -- the error was never delivered to the caller. The `print()` removal is also correct (it was debug code). However, callers that were catching unhandled exceptions from the zone may see different behavior: the error now propagates via the completer's future.

---

### [REG-16] `SocketTransportConnector.done` and `.shutdown()` Guard Changes
**Behavior Change:** `done` previously used `ArgumentError.checkNotNull(socket)` which would throw `ArgumentError` if called before `connect()`. The PR changes to `StateError` for `done` and makes `shutdown()` a no-op before connect.

**Before (main):**
```dart
Future get done {
  ArgumentError.checkNotNull(socket);
  return socket.done;
}
void shutdown() {
  ArgumentError.checkNotNull(socket);
  socket.destroy();
}
```

**After (PR):**
```dart
Future get done {
  if (!_socketInitialized) {
    throw StateError('SocketTransportConnector.done accessed before connect()');
  }
  return socket.done;
}
void shutdown() {
  if (!_socketInitialized) return;
  socket.destroy();
}
```

**Affected Users:** Client users who call `shutdown()` on a connector that was never connected. Also changes exception type from `ArgumentError` to `StateError` for `done`.

**Severity:** LOW

**Intentional:** Yes -- `shutdown()` being a no-op before connect prevents crashes during error recovery. `StateError` is more semantically correct than `ArgumentError` for accessing state that isn't ready.

**Evidence:** `lib/src/client/http2_connection.dart` SocketTransportConnector class

**Mitigation:** Correct fixes. Anyone catching `ArgumentError` from `.done` should catch `StateError` instead (extremely unlikely external usage since these are internal implementation details).

---

### [REG-17] New Public API: `ServerHandler.onResponseCancelDone`
**Behavior Change:** A new public getter `onResponseCancelDone` is added to `ServerHandler`, exposing a `Future<void>` that completes when the response subscription cancel finishes.

**Before (main):** No such API. `ServerHandler` only exposed `onCanceled`.

**After (PR):** `onResponseCancelDone` is available and used by `shutdownActiveConnections()` to await generator cleanup.

**Affected Users:** External code that subclasses or inspects `ServerHandler` (unlikely since it's an internal class, but `@visibleForTesting` exposes it).

**Severity:** LOW

**Intentional:** Yes -- required for the shutdown protocol to await async generator cleanup.

**Evidence:** `lib/src/server/handler.dart` line 85: `Future<void> get onResponseCancelDone`

**Mitigation:** Additive change, non-breaking. The getter returns `Future.value()` if no cancel has been initiated.

---

### [REG-18] `_sendError` Now Catches Error Handler Exceptions
**Behavior Change:** In `handler.dart`, `_sendError()` previously called `_errorHandler?.call(error, trace)` without a try-catch. If the user-provided error handler threw, the exception would propagate and prevent `sendTrailers()` from being called.

**Before (main):** A throwing error handler would crash the handler and potentially leave the HTTP/2 stream open without trailers.

**After (PR):** Error handler exceptions are caught and logged. `sendTrailers()` always runs.

**Affected Users:** All server users with custom `GrpcErrorHandler` callbacks that throw.

**Severity:** LOW

**Intentional:** Yes -- error handlers should not be able to crash the gRPC server.

**Evidence:**
```dart
try {
  _errorHandler?.call(error, trace);
} catch (e) {
  logGrpcEvent('[gRPC] Error handler threw: $e', ...);
}
sendTrailers(status: error.code, message: error.message, errorTrailers: error.trailers);
```

**Mitigation:** Correct fix. Error handlers that intentionally threw to abort processing will no longer prevent trailers from being sent. This is arguably a behavior change for error handlers that threw to signal "don't send trailers", but that was never a documented or supported pattern.

---

### [REG-19] `sendTrailers()` Is Now Idempotent (Double-Send Prevented by `_trailersSent` Flag)
**Behavior Change:** `sendTrailers()` previously had no guard against being called twice. Calling it twice would send duplicate headers and potentially crash with "Cannot add event after closing". The PR adds `_trailersSent` flag and returns early on duplicate calls.

**Before (main):** Double `sendTrailers()` would crash or send malformed HTTP/2 frames.

**After (PR):** Second call is a silent no-op.

**Affected Users:** All server users (but only observable during race conditions where sendTrailers could be called from multiple paths).

**Severity:** LOW

**Intentional:** Yes -- prevents crashes during concurrent teardown paths.

**Evidence:** `lib/src/server/handler.dart` sendTrailers: `if (_trailersSent) return; _trailersSent = true;`

**Mitigation:** Correct fix. Silent suppression of duplicate trailers is the right behavior.

---

### [REG-20] `Http2TransportStream.terminate()` Now Cancels Outgoing Subscription First
**Behavior Change:** In `http2_transport.dart`, `terminate()` previously only closed `_outgoingMessages` and terminated the transport stream. The PR adds `await _outgoingSubscription.cancel()` before closing.

**Before (main):**
```dart
Future<void> terminate() async {
  await _outgoingMessages.close();
  _transportStream.terminate();
}
```
If the outgoing subscription was still processing data, closing the controller could leave the subscription in a partial state.

**After (PR):**
```dart
Future<void> terminate() async {
  await _outgoingSubscription.cancel();
  await _outgoingMessages.close();
  _transportStream.terminate();
}
```

**Affected Users:** All client users calling `terminate()` on active streams.

**Severity:** LOW

**Intentional:** Yes -- ensures clean subscription cleanup before controller closure.

**Evidence:** `lib/src/client/transport/http2_transport.dart` terminate method

**Mitigation:** Correct fix. Cancelling the subscription before closing is the proper Dart stream cleanup order.

---

### [REG-21] Connection `onError` in `serveConnection` Now Cleans Up State
**Behavior Change:** In `server.dart`, the `onError` callback for `connection.incomingStreams.listen()` previously only forwarded `Error` types to the zone. The PR adds full cleanup: cancel all handlers, remove connection from `_connections`, `handlers`, and all tracking maps.

**Before (main):**
```dart
onError: (error, stackTrace) {
  if (error is Error) {
    Zone.current.handleUncaughtError(error, stackTrace);
  }
},
```
Connection state leaked permanently on stream errors.

**After (PR):** Full cleanup mirrors the `onDone` path.

**Affected Users:** All server users where connection streams error (e.g., TLS errors, broken pipes).

**Severity:** LOW

**Intentional:** Yes -- fixes a connection state leak.

**Evidence:** `lib/src/server/server.dart` serveConnection onError callback

**Mitigation:** Correct fix. The old behavior leaked entries in `_connections` and `handlers` forever.

---

### [REG-22] Stale `socket.done` Callback Protection via Generation Counter
**Behavior Change:** `connectTransport()` now uses a `_connectionGeneration` counter to prevent stale `socket.done` callbacks from abandoning a newer connection. Additionally, `socket.done` now has an `onError` handler.

**Before (main):**
```dart
_transportConnector.done.then((_) => _abandonConnection());
```
A stale `done` callback from a previous connection could abandon a fresh connection. `done` completing with error was unhandled.

**After (PR):**
```dart
final generation = ++_connectionGeneration;
_transportConnector.done.then(
  (_) { if (generation == _connectionGeneration) _abandonConnection(); },
  onError: (_) { if (generation == _connectionGeneration) _abandonConnection(); },
);
```

**Affected Users:** Client users experiencing connection instability (reconnection patterns).

**Severity:** LOW

**Intentional:** Yes -- fixes a TOCTOU race where stale socket callbacks corrupt connection state.

**Evidence:** `lib/src/client/http2_connection.dart` connectTransport method

**Mitigation:** Correct fix. The generation counter is a standard pattern for preventing stale callback interference.

---

## Summary

| Severity | Count | Intentional (Bug Fix) | Accidental |
|----------|-------|-----------------------|------------|
| HIGH     | 2     | 2                     | 0          |
| MEDIUM   | 5     | 5                     | 0          |
| LOW      | 15    | 15                    | 0          |
| BREAKING | 0     | 0                     | 0          |
| **Total** | **22** | **22**              | **0**      |

### Key Takeaways

1. **No accidental regressions found.** All 22 behavioral changes are deliberate bug fixes with clear rationale.

2. **The two HIGH-severity items deserve the most attention:**
   - **REG-1 (Keepalive inversion):** This is the most impactful change. Servers that were unknowingly tolerating rapid client pings will now reject them. While the fix is correct per gRPC spec, it reverses the actual enforcement direction for all existing deployments.
   - **REG-13 (Async dispatch loop):** The yield between dispatches changes the atomicity guarantee of pending call dispatch. Previously, all pending calls were dispatched in a single synchronous burst; now, intermediate protocol events can interleave. This is necessary for flow control but changes observable behavior.

3. **The MEDIUM-severity items are all correct fixes** but change behavior that callers may have adapted to:
   - Shutdown ordering/timing (REG-2)
   - Deadline stream termination (REG-3)
   - Response error request stream closure (REG-7)
   - Interceptor error code preservation (REG-9)
   - Exception type change in makeRequest (REG-10)
   - Proxy error delivery fix (REG-15)

4. **Hardcoded 5-second timeouts** in `shutdownActiveConnections()` are a new constraint. They should ideally be configurable or at least documented as part of the shutdown contract.

5. **Exception swallowing pattern** (call.dart, http2_transport.dart): The try-catch guards around `outSink.add/addError/close` convert crashes into logged warnings. While this prevents "Cannot add event after closing" server crashes, it also silently drops data. Callers who relied on these exceptions for flow control will see silent data loss instead.
