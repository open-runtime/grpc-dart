# Phase 2 -- Agent 4: Bug Hunter

## Findings

### [BUG-1] `_finishConnection` uses `.timeout()` on `terminate()` despite documenting that `.timeout()` is unreliable under event loop saturation

**File:** `lib/src/server/server.dart:371`
**Severity:** MEDIUM

**Description:**
The `shutdownActiveConnections` method's Step 4 comment explicitly states: "Using Completer + Timer instead of Future.timeout() because .timeout() relies on the same event loop that may be saturated by incoming data frames, causing the timeout to never fire." However, inside `forceTerminate()` (which is the fallback when the Timer-based deadline fires), `connection.terminate().timeout(const Duration(seconds: 2))` uses exactly the `.timeout()` pattern that was documented as unreliable.

If the event loop is truly saturated (the entire reason `forceTerminate()` was called in the first place), the 2-second `.timeout()` timer may also fail to fire. The `.whenComplete(() => complete())` chain would never execute, and `done.future` would never complete. Since `shutdownActiveConnections` does `await Future.wait([...])`, the entire shutdown hangs on this one connection.

**Reproduction:**
1. Start a server under heavy load where a client is flooding data frames
2. Call `shutdown()`
3. The 5-second Timer fires `forceTerminate()` (proving the event loop CAN process timers)
4. `connection.terminate()` starts but the transport is blocked by data saturation
5. The `.timeout(2s)` timer may not fire if the event loop becomes re-saturated between the Timer fire and the timeout check
6. `done.future` never completes, `shutdownActiveConnections` hangs

**Suggested Fix:**
Apply the same Completer + Timer pattern to the `terminate()` call inside `forceTerminate()`:

```dart
void forceTerminate() {
  if (terminateCalled) return;
  terminateCalled = true;

  final terminateDeadline = Timer(const Duration(seconds: 2), () {
    logGrpcEvent('[gRPC] connection.terminate() timed out after 2s', ...);
    _connectionSockets.remove(connection)?.destroy();
    complete();
  });

  try {
    connection.terminate().catchError((e) {
      logGrpcEvent('[gRPC] connection.terminate() async error: $e', ...);
    }).whenComplete(() {
      terminateDeadline.cancel();
      _connectionSockets.remove(connection)?.destroy();
      complete();
    });
  } catch (e) {
    terminateDeadline.cancel();
    _connectionSockets.remove(connection)?.destroy();
    complete();
  }
}
```

---

### [BUG-2] `_finishConnection` does not guard against `connection.finish()` throwing synchronously

**File:** `lib/src/server/server.dart:421-435`
**Severity:** MEDIUM

**Description:**
The `connection.finish()` call is not wrapped in a try-catch. If `finish()` throws synchronously (rather than returning a Future that completes with an error), the exception propagates through the `async` function body, causing `_finishConnection`'s returned Future to complete with an error *before* `return done.future` executes. The `done` Completer never completes (until the 5-second Timer fires `forceTerminate()`), but `Future.wait` in the caller already has the error.

Consequences:
- The Timer still fires 5 seconds later, calling `forceTerminate()` on an already-errored connection. `connection.terminate()` may throw or behave unexpectedly.
- `Future.wait([...], eagerError: false)` collects the error. When `shutdownActiveConnections` awaits it, the error propagates up to `Server.shutdown()`, potentially crashing the shutdown.

**Reproduction:**
1. Use a custom `ServerTransportConnection` whose `finish()` throws synchronously (e.g., when the underlying transport is already disposed)
2. Call `shutdown()`
3. `_finishConnection` throws, `shutdownActiveConnections` re-throws

**Suggested Fix:**
Wrap the `connection.finish()` chain in a try-catch:

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

---

### [BUG-3] `cancel()` overwrites `_responseCancelFuture` from prior `_cancelResponseSubscription()` call

**File:** `lib/src/server/handler.dart:600`
**Severity:** LOW

**Description:**
When `_onTimedOut()` runs, it calls `_cancelResponseSubscription()` (line 334) which stores the cancel future in `_responseCancelFuture` (line 155). Later, `cancel()` is called (e.g., from `outgoingMessages.done.whenComplete` or `_stream.onTerminated`), which overwrites `_responseCancelFuture` at line 600 with a NEW cancel future (the second `.cancel()` call on the same subscription).

The `shutdownActiveConnections` method reads `handler.onResponseCancelDone` after calling `handler.cancel()`. By that point, `_responseCancelFuture` contains the second cancel's future (which completes immediately since the subscription is already cancelled). The original cancel future from `_cancelResponseSubscription` is no longer tracked.

In practice, calling `.cancel()` twice on a `StreamSubscription` is safe and the second call returns immediately or returns the same future. But this pattern means `shutdownActiveConnections` may think the cancel completed instantly when the underlying async generator is still winding down from the first cancel.

**Reproduction:**
1. Server-streaming RPC with a slow async* generator
2. Request times out (`_onTimedOut` fires, `_cancelResponseSubscription` initiates cancel)
3. `outgoingMessages.done.whenComplete` fires, calling `cancel()` which overwrites `_responseCancelFuture`
4. `shutdownActiveConnections` calls `handler.cancel()` and awaits `onResponseCancelDone`
5. Gets an immediately-resolved future, proceeds to `connection.finish()` while the generator is still cleaning up

**Suggested Fix:**
In `cancel()`, only set `_responseCancelFuture` if it is currently null:

```dart
_responseCancelFuture ??= _responseSubscription?.cancel().catchError((e) { ... });
```

Or coalesce both futures:
```dart
final newCancel = _responseSubscription?.cancel().catchError(...);
if (newCancel != null) {
  final existing = _responseCancelFuture;
  _responseCancelFuture = existing != null
    ? Future.wait([existing, newCancel]).then((_) {})
    : newCancel;
}
```

---

### [BUG-4] `_ServerPipeStream._onOutgoingDone()` calls `close()` after `_closeHandle()`, creating a window where the close completer fires before `_isClosed` is set

**File:** `lib/src/server/named_pipe_server.dart:668-684`
**Severity:** LOW

**Description:**
In `_onOutgoingDone()`, the sequence is:
1. Line 680: `_closeHandle(disconnect: false)` -- sets `_handleClosed = true`, completes `_closeCompleter`
2. Line 681-682: checks `_isClosed`, calls `close()` which sets `_isClosed = true`

Between steps 1 and 2, `_closeCompleter` has already completed, but `_isClosed` may still be false. Any code awaiting `_closeFuture` (which is `_closeCompleter.future`) would see the stream as "closed" before `_isClosed` is set. In the current implementation, `_closeFuture` is only used in `_handleNewConnection`:

```dart
stream._closeFuture.whenComplete(() {
  _activeStreams.remove(stream);
});
```

This means the stream gets removed from `_activeStreams` before `_isClosed = true`. If `NamedPipeServer.shutdown()` iterates `_activeStreams` to force-close streams between steps 1 and 2, the stream is already removed and won't be force-closed. However, since step 1 already closed the handle, no resources leak. The issue is theoretical in the current code because there are no yields between steps 1 and 2 (so shutdown can't interleave).

**Reproduction:**
Theoretical -- would require a yield between `_closeHandle` and the `close()` call in `_onOutgoingDone`, which doesn't exist currently. Documented as a latent correctness concern.

**Suggested Fix:**
Move `_closeHandle()` after `close()` in `_onOutgoingDone`, or set `_isClosed = true` before completing the close completer:

```dart
void _onOutgoingDone() {
  _cancelDeferredCloseTimer();
  _outgoingSubscription = null;
  if (!_incomingController.isClosed) {
    _incomingController.close();
  }
  if (!_isClosed) {
    _isClosed = true;  // Set before closeHandle so completer fires after state is consistent
  }
  _closeHandle(disconnect: false);
}
```

---

### [BUG-5] `shutdownActiveConnections` Step 2 iterates a live handler list that can be modified by `onCanceled.then()` microtasks

**File:** `lib/src/server/server.dart:298-306`
**Severity:** LOW

**Description:**
In Step 2 of `shutdownActiveConnections`, the code iterates `handlers[connection]` directly (not a snapshot):

```dart
final connectionHandlers = handlers[connection];
if (connectionHandlers != null) {
  for (final handler in connectionHandlers) {
    handler.cancel();
    cancelFutures.add(handler.onResponseCancelDone);
  }
}
```

`handler.cancel()` sets `isCanceled = true` which completes `_isCanceledCompleter`. In `serveConnection()`, there is:
```dart
handler.onCanceled.then((_) => handlers[connection]?.remove(handler));
```

The `.then()` callback is scheduled as a microtask. In Dart, microtasks do NOT interleave with synchronous code. The `for` loop is synchronous, so the `.then()` callbacks cannot fire mid-iteration.

However, `handler.cancel()` also calls `_addErrorAndClose` which includes `_requests?.close()`. `StreamController.close()` in Dart can schedule microtask callbacks if the controller has listeners. If any microtask processing happens between iterations (which it shouldn't in a synchronous for loop), the list could be modified.

In practice, Dart's synchronous for loop guarantees no microtask checkpoints between iterations. But this relies on implementation behavior. A snapshot would be safer and is used elsewhere in this PR (e.g., `onError` and `onDone` callbacks).

**Reproduction:**
Theoretical -- requires microtask interleaving within a synchronous for loop, which doesn't happen in the current Dart VM.

**Suggested Fix:**
Snapshot the list for consistency with other iteration sites in the same file:
```dart
final connectionHandlers = List.of(handlers[connection] ?? <ServerHandler>[]);
```

---

### [BUG-6] `onDataReceived?.add(null)` in handler can throw if keepalive controller was closed during shutdown

**File:** `lib/src/server/handler.dart:207`
**Severity:** LOW

**Description:**
In `_onDataIdle`, `onDataReceived?.add(null)` is called at line 207. The `onDataReceived` sink is the keepalive controller's sink set in `serveConnection()`. During `shutdownActiveConnections()` Step 1.5, keepalive controllers are explicitly closed:

```dart
_keepAliveControllers.remove(connection)?.close();
```

If a data frame arrives on a connection whose keepalive controller has been closed (but whose incoming subscription cancel hasn't completed yet), `_onDataIdle` fires and `onDataReceived?.add(null)` throws `StateError: Cannot add event after closing`.

The `_onDataIdle` method does have a try-catch (lines 205-261) that catches `error` and sends a `GrpcError.internal`, but `onDataReceived?.add(null)` is on line 207 INSIDE the try block, so the catch at line 255 will handle it. The handler will send an internal error to the client and sink incoming. This is incorrect behavior -- the handler should check if the sink is closed or the error should be silently discarded since it's a shutdown-initiated condition, not a real request processing error.

**Reproduction:**
1. Server has active connections with handlers in idle state (waiting for first data frame)
2. `shutdown()` is called
3. Step 1.5 closes keepalive controllers
4. Between Step 1 (cancel incoming subscriptions) and actual cancellation completing, a data frame arrives
5. `_onDataIdle` fires, `onDataReceived.add(null)` throws
6. Client receives `INTERNAL: Error processing request: ...Cannot add event after closing...`

**Suggested Fix:**
Guard the `onDataReceived?.add(null)` call:

```dart
try {
  onDataReceived?.add(null);
} catch (_) {
  // Keepalive controller may be closed during shutdown. Safe to ignore.
}
```

Or in `_onDataActive`:
```dart
if (onDataReceived is StreamSink && !(onDataReceived as StreamController).isClosed) {
  onDataReceived?.add(null);
}
```

---

### [BUG-7] `_ServerPipeStream._writeData` can use-after-free native memory if `close(force: true)` runs during partial write loop

**File:** `lib/src/server/named_pipe_server.dart:614-653`
**Severity:** LOW

**Description:**
The `_writeData` method at line 604-653 allocates native buffers (`calloc<Uint8>` and `calloc<DWORD>`) and enters a `while (offset < data.length)` loop calling WriteFile. The guard at line 605 checks `_handleClosed` before entering the loop but does NOT re-check inside the loop.

`WriteFile` is a synchronous FFI call, so there's no yield between iterations. However, if `WriteFile` returns success with `bytesWritten.value > 0` but `< remaining`, we loop again. Between the end of one `WriteFile` call and the start of the next, there is no yield (it's synchronous). But `_handleClosed` could have been set true by `close(force: true)` which calls `CloseHandle(_handle)`. Actually, since this is all synchronous code (no yields), `close(force: true)` cannot interleave.

Wait -- `_writeData` is called from the outgoing subscription's `onData` callback. The `close(force: true)` path cancels the outgoing subscription. Once the subscription is cancelled, no more `onData` callbacks fire. So `_writeData` cannot be called while the close is in progress. And within a single `_writeData` call, the code is synchronous, so close() cannot interleave.

**Conclusion:** This is NOT actually a bug. Removing from findings.

---

### [BUG-8] `_acceptLoop` leaks pipe handle if `shouldStop` becomes true between CreateNamedPipe and the inner ConnectNamedPipe poll loop

**File:** `lib/src/server/named_pipe_server.dart:963-1058`
**Severity:** LOW

**Description:**
In the accept loop, after `CreateNamedPipe` succeeds (line 966-975), `SetNamedPipeHandleState` switches to NOWAIT mode (line 1008-1014). If this call fails, the handle is properly closed (line 1012). Then, the readiness signal is sent (line 1019-1022), and the inner poll loop starts (line 1029).

The inner poll loop checks `shouldStop` on each iteration (line 1029). If `shouldStop` is set between `SetNamedPipeHandleState` success and the inner loop start, the inner loop runs one iteration of `ConnectNamedPipe`. If no client connects, it breaks out. Then `connected` is false, and line 1052 `CloseHandle(hPipe)` handles cleanup. If `shouldStop` is true, line 1055 `break`s the outer loop. This is correct.

But what if `shouldStop` becomes true between the `_ServerReady` send (line 1020) and the inner loop entry (line 1029)? The only yield between these is... none. It's synchronous. `shouldStop` can only change during an `await` yield in the `_acceptLoop`. Between lines 1022 and 1029, there are no yields. So `shouldStop` cannot change here.

**Conclusion:** NOT a bug. The accept loop's synchronous sections are safe.

---

## Confirmed Findings Summary

After thorough analysis of all 8 production files changed in this PR:

**6 bugs found: 0 critical, 2 medium, 4 low**

| ID | Severity | File | Summary |
|----|----------|------|---------|
| BUG-1 | MEDIUM | server.dart:371 | `forceTerminate()` uses `.timeout()` despite documenting it as unreliable under event loop saturation |
| BUG-2 | MEDIUM | server.dart:421 | No guard against `connection.finish()` throwing synchronously |
| BUG-3 | LOW | handler.dart:600 | `cancel()` overwrites `_responseCancelFuture` from prior `_cancelResponseSubscription()` |
| BUG-4 | LOW | named_pipe_server.dart:680 | `_closeHandle` fires close completer before `_isClosed` is set in `_onOutgoingDone` |
| BUG-5 | LOW | server.dart:300 | `shutdownActiveConnections` Step 2 iterates live handler list (no snapshot) |
| BUG-6 | LOW | handler.dart:207 | `onDataReceived?.add(null)` can throw if keepalive controller closed during shutdown |

## Methodology

Each production file was analyzed by:
1. Reading the full `git diff main...HEAD` output
2. Reading the complete current file to understand context around changes
3. Tracing race condition scenarios with Dart's single-threaded event loop model
4. Identifying yield points (await, Future.delayed, microtask boundaries) where state can change
5. Verifying TOCTOU (time-of-check-to-time-of-use) gaps between guards and operations
6. Checking resource lifecycle completeness (open/close on all paths)
7. Verifying idempotency of cleanup operations called from multiple paths

Files with no actionable bugs found:
- `lib/src/server/server_keepalive.dart` -- The comparison inversion fix (`>` to `<`) is correct. The `_tooManyBadPingsTriggered` guard and stopwatch reset on all branches are correct.
- `lib/src/client/transport/http2_transport.dart` -- The guarded sink callbacks correctly log and swallow errors from closed sinks. `cancelOnError: true` is appropriate.
- `lib/src/client/call.dart` -- Same guarded callback pattern as http2_transport.dart. Correctly mirrors the sink protection.
- `lib/src/client/named_pipe_transport.dart` -- The shutdown race guards, deferred close, and handle lifecycle are correct. The `_doneCompleter` reset at connect start is the right per-generation pattern.
- `lib/src/server/named_pipe_server.dart` -- The two-isolate architecture, PIPE_NOWAIT polling, and deferred close with timer safety net are well-implemented. The handle lifecycle (CloseHandle after DisconnectNamedPipe) follows Win32 best practices.
- `lib/src/client/http2_connection.dart` -- The generation counter pattern, batch re-queue with exponential backoff, and connection life timer reset during dispatch are correct.
