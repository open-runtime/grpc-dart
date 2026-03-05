# Phase 1 — Agent 1: Narrative Walkthrough of PR #41

**Branch**: `fix/named-pipe-race-condition` → `main`
**Repository**: `open-runtime/grpc-dart`

---

## The Problem Space

The upstream `grpc/grpc-dart` package was written with an assumption that shutdown
is clean and sequential: stop the socket, cancel handlers, finish connections. In
production, that assumption fails under three distinct conditions:

1. A client is actively streaming data when shutdown is initiated.
2. An async* generator RPC is still yielding values when `cancel()` is called.
3. A Windows named pipe's `ConnectNamedPipe` FFI call blocks the isolate's event
   loop, preventing any subsequent async work from running.

PR #41 addresses all three — and in doing so rewrites the shutdown path, hardens
every error boundary in the handler lifecycle, fixes a keepalive comparison
inversion, introduces the named pipe transport, and guards every outgoing sink
write against a "Cannot add event after closing" crash.

---

## 1. `lib/src/server/server.dart` — The Shutdown Rewrite

The most significant change is the `shutdownActiveConnections()` method on
`ConnectionServer` (lines 260–338). The original code was a simple loop that called
`connection.finish()` on each connection and awaited it. This had two failure modes:

- If a client was actively pumping DATA frames, `finish()` never completed because
  the HTTP/2 connection waited for the incoming stream to drain.
- If there were no pending calls, the server's VM process could hang for 30+ minutes
  on Windows CI because an unclosed `StreamController` kept the Dart VM alive.

The rewrite imposes a strict four-step sequence with explicit timeouts:

**Step 1** (lines 266–285): Cancel all `incomingStreams` subscriptions in parallel.
This stops the server from processing new DATA frames immediately. Without this,
`connection.finish()` blocks because the connection's parser is still consuming
frames from the client.

**Step 1.5** (lines 291–294): Close the keepalive `StreamController` instances
tracked in `_keepAliveControllers`. Cancelling a subscription does not fire
`onDone`, so the controller's listener is permanently pending. This was the root
cause of 30-minute VM hangs.

**Step 2** (lines 297–326): Cancel all active `ServerHandler` instances and await
their `onResponseCancelDone` futures. This is critical for async* generators: a
server-streaming RPC continues yielding values even after `cancel()` is called until
the generator processes the cancel signal across event-loop turns. Without awaiting
this, `connection.finish()` blocks because HTTP/2 streams remain open.

**Step 3** (line 331): A single `await Future.delayed(Duration.zero)`. This gives
the HTTP/2 outgoing message queue at least one event-loop turn to flush RST_STREAM
frames before GOAWAY closes the socket. GOAWAY alone does not terminate
already-acknowledged streams on the client side.

**Step 4** (lines 338): `Future.wait([for ... _finishConnection(connection)])` — each
connection gets its own `Completer<void>` and a `Timer(Duration(seconds: 5), ...)`.
This is the key insight: `Future.timeout()` relies on the same event loop that
incoming data frames may saturate, so it can fail to fire. A `Timer` fires from a
native OS callback, which is not blocked by an I/O-saturated Dart event loop.

The `_finishConnection()` helper (lines 354–438) attempts `connection.finish()`,
falls back to `connection.terminate()` after 5 seconds, then calls
`socket?.destroy()` (line 399) to stop the `FrameReader`'s orphaned socket
subscription — a known missing `onCancel` handler in `package:http2`.

Three new tracking maps support this (lines 102–120): `_incomingSubscriptions`,
`_connectionSockets`, and `_keepAliveControllers`. All three are populated in
`serveConnection()` and consumed in `shutdownActiveConnections()`.

The `serveConnection()` method also adds a null-guard on `handlers[connection]`
(lines 164–165) before adding a new handler. A race between the incoming stream
error path and a new stream arriving could previously trigger a null-dereference.

---

## 2. `lib/src/server/handler.dart` — Handler Lifecycle Hardening

`ServerHandler` gained several targeted fixes that prevent crashes during concurrent
teardown.

**`_streamTerminated` guard** (lines 67, 626–642): `_terminateStream()` now checks
and sets a boolean flag before calling `_stream.terminate()`. This prevents double-
terminate when `Server.shutdown()` calls `cancel()` on handlers that have already
completed normally.

**`_addErrorAndClose()` helper** (lines 171–201): A dedicated method that closes
`_requests` using two independent `try` blocks. Previously, if `addError()` threw
(e.g., because the controller was already closed), `close()` was never called,
leaving handlers blocked on `await for` indefinitely. Now both operations are
attempted regardless.

**`onResponseCancelDone` / `_responseCancelFuture`** (lines 73, 87): The shutdown
path in `server.dart` needs to await the response subscription's cancel completion.
The handler stores the cancel `Future` in `_responseCancelFuture` — set both in
`cancel()` (line 600) and `_cancelResponseSubscription()` (line 155). The
`onResponseCancelDone` getter returns this future (or a resolved future if cancel was
never called), making it safe to await unconditionally.

**`cancel()` now closes `_requests`** (lines 596): Every other termination path
(`_onError`, `_onTimedOut`, `_onDone`) closes `_requests`. Before this fix, `cancel()`
did not, leaving server methods blocked on `await for (final req in requests)` when
`Server.shutdown()` was called.

**`isCanceled = true` in `sendTrailers()`** (line 511): Handlers that completed
normally (via `_onResponseDone` → `sendTrailers()`) were never marked cancelled, so
the `onCanceled.then(remove)` callback in `serveConnection()` never fired. The
handler leaked in the map until the connection closed. The `isCanceled` setter is
idempotent (backed by a `Completer`), so this is safe.

**`_onDataIdle` cancel-guard** (line 252): After `_applyInterceptors()` completes
its async await, `cancel()` may have already run. Without the `if (isCanceled)
return` guard, the handler continues processing the request indefinitely, blocking
`Server.shutdown()`.

**`sendTrailers()` try-catch** (lines 491–504): `_stream.sendHeaders()` now runs
inside a try/catch. During concurrent connection teardown, the HTTP/2 stream sink
can be closed before `sendTrailers()` completes, producing "Cannot add event after
closing" errors. These are caught and logged instead of crashing.

---

## 3. `lib/src/server/named_pipe_server.dart` — Two-Isolate Architecture

This file is new to the fork. It implements a Windows-only gRPC server over Win32
named pipes, with a design that directly encodes lessons from debugging FFI blocking.

The core architectural decision lives in lines 59–76 of the class comment: data I/O
must not run in the same isolate that calls `ConnectNamedPipe`. `ConnectNamedPipe`
is a synchronous blocking Win32 call. When it blocks waiting for a client, the
isolate's Dart event loop is frozen — `await Future.delayed(...)` inside a
`PeekNamedPipe` polling loop simply never resumes.

**The accept loop isolate** (spawned at line 204): Its only job is to call
`CreateNamedPipe` + `ConnectNamedPipe` in a loop and send the resulting Win32 handle
(an integer) back to the main isolate via a `SendPort`. Handles are valid across
isolates in the same process.

**The main isolate** receives handles via `_receivePort` (line 201) and in
`_handleNewConnection()` (line 288) wraps each handle in a `_ServerPipeStream`. The
`_ServerPipeStream._readLoop()` (line 502) uses `PeekNamedPipe` to check availability
before calling `ReadFile`, keeping the event loop responsive between 1ms `await
Future.delayed` yields.

**Shutdown** (lines 325–417) implements a layered teardown:
- Sets `_isRunning = false` so straggler `_PipeHandle` messages are discarded.
- Starts `shutdownActiveConnections()` concurrently to snapshot connections before
  transport teardown.
- Force-closes all `_ServerPipeStream` instances (calling `DisconnectNamedPipe` +
  `CloseHandle`) so blocking I/O paths unblock.
- Sends a cooperative stop signal to the accept loop isolate via `_stopSendPort`.
- Calls `Isolate.kill(priority: Isolate.immediate)` as a safety net and awaits
  confirmation via an exit listener port (lines 380–401).

The cooperative stop + `Isolate.immediate` combination solves the race that
`Isolate.kill(beforeNextEvent)` had: if the isolate was in the middle of a
`ConnectNamedPipe` call when kill was sent, `beforeNextEvent` waited for the next
event-loop yield — which never came because the FFI call blocked the thread.
`Isolate.immediate` kills at VM safepoints, which are injected even into FFI calls.

---

## 4. `lib/src/client/http2_connection.dart` — Dispatch and Refresh Fixes

**Connection generation counter** (lines 68, 101): `_connectionGeneration` is
incremented before the `await _transportConnector.connect()` call. A stale
`socket.done` callback from a previous connection that fires during the connect
`await` sees a mismatched generation and is a no-op. Without this, a stale callback
could call `_abandonConnection()` on a brand-new, healthy connection.

**Dispatch loop re-queue pattern** (lines 183–237): When a burst of pending calls
is dispatched after reconnection, each `dispatchCall()` is followed by
`await Future.delayed(Duration.zero)` so the HTTP/2 transport can process
`WINDOW_UPDATE` and `SETTINGS_ACK` frames between call dispatches. The key fix is
how calls that fail mid-iteration are re-queued: they are added directly to
`_pendingCalls` (line 204) rather than calling `dispatchCall()` per-call.
Calling `dispatchCall()` in a non-ready state triggers `_connect()` immediately with
zero backoff, producing a tight reconnection loop. The batch re-queue followed by a
post-loop backoff timer (lines 233–237) applies proper exponential backoff.

**Connection life timer reset** (lines 222–226): Inside the dispatch loop, after
each `await`, the `_connectionLifeTimer` is reset. Without this, draining N pending
calls with N yields could take longer than `connectionTimeout`, causing
`_refreshConnectionIfUnhealthy()` to abandon a perfectly good connection mid-dispatch
and destroy already-dispatched RPCs.

**`onError` handler on `socket.done`** (lines 109–116): `socket.done` can complete
with an error (broken pipe, connection reset). Without a handler, the error is
unhandled and the connection becomes a zombie — never abandoned, never reconnected.

---

## 5. `lib/src/client/named_pipe_transport.dart` — Client Transport

`NamedPipeTransportConnector` implements `ClientTransportConnector` for Windows
named pipes, allowing `Http2ClientConnection` to use a pipe exactly where it would
use a TCP socket.

**Reconnect safety** (line 125): `_disposeCurrentPipeResources()` is called at the
start of `connect()` to dispose any stale handle from a prior connection before
creating a new one.

**Two shutdown race guards** (lines 159–165, 199–205): `connect()` contains two
`if (_doneCompleter.isCompleted)` checks — one after `_openPipeWithRetry()` (which
can yield on PIPE_BUSY retries) and one after the synchronous setup. If
`shutdown()` fires during either window, the newly opened handle is closed directly
or via `_disposeCurrentPipeResources()` and the method throws `ERROR_OPERATION_ABORTED`
rather than returning a half-initialized transport.

**`_openPipeWithRetry()`** (lines 222–305): Retries `CreateFile` up to 3 times with
exponential backoff (100ms, 200ms, 400ms) only on `ERROR_PIPE_BUSY`. All other
errors fail immediately. `WaitNamedPipeW` is called when a timeout is configured to
avoid busy-spinning.

**`_NamedPipeStream._readLoop()`** (lines 411–505): Uses `PeekNamedPipe` to check
availability before calling `ReadFile`. If `PeekNamedPipe` returns zero bytes, the
loop yields with `await Future.delayed(const Duration(milliseconds: 1))` rather than
spinning. The deferred-close pattern (lines 570–603) allows the HTTP/2 transport to
finish writing queued frames before the underlying Win32 handle is released.

---

## 6. `lib/src/server/server_keepalive.dart` — Keepalive Comparison Fix

A single logic inversion in `_onPingReceived()` (line 93). The original code flagged
a ping as "bad" when `elapsed >= minIntervalBetweenPingsWithoutData`, meaning pings
that arrived *after* the minimum interval were punished and pings that arrived *too
fast* were accepted. The corrected comparison uses `<`: a ping is bad when it arrives
*faster* than the minimum interval.

The `_timeOfLastReceivedPing` stopwatch is also reset on every ping (lines 98–108),
including legitimate ones. Without the reset, elapsed time accumulates across pings,
making subsequent fast pings appear to arrive slowly. This matches the behaviour of
gRPC C++'s `ping_abuse_policy.cc`.

---

## 7. `lib/src/client/transport/http2_transport.dart` — Guarded Callbacks

`Http2TransportStream._outgoingSubscription` wraps the three listen callbacks with
try/catch (lines 53–94). The `outSink` (the HTTP/2 transport's outgoing messages
sink) can be closed externally — by an incoming `RST_STREAM` or connection teardown —
while serialized frames are still queued in `_outgoingMessages`. Direct method
references to `outSink.add`, `outSink.addError`, and `outSink.close` throw
`StateError: Cannot add event after closing` in this case. The try/catch logs the
event and continues without crashing.

---

## 8. `lib/src/client/call.dart` — Guarded Callbacks

The same guard pattern is applied to `ClientCall._sendRequest()` (lines 262–308),
which subscribes to the outgoing request stream. If the transport stream is
terminated (RST_STREAM received, connection teardown) while serialized request data
is still in flight, the sink callbacks throw. Each of the three listen callbacks —
`onData`, `onError`, `onDone` — is wrapped with a try/catch that logs and continues,
matching the approach in `http2_transport.dart`.

The `addErrorIfNotClosed` extension method (lines 526–531) used across `ClientCall`
methods provides a null-safe pattern for adding errors to `_responses` when the
state of the controller is uncertain.

---

## Summary: The Thread Running Through All Eight Files

Every change in PR #41 addresses the same category of failure: **state that becomes
invalid after an async yield**. Dart's event loop means that any `await` is a
potential cancellation or teardown point. The fixes share a common vocabulary:

- Check isCanceled / isCompleted after every await that guards lifecycle transitions.
- Store cancel Futures so callers can await them, not just fire-and-forget.
- Wrap every outgoing sink call in try/catch to survive externally-closed sinks.
- Use `Completer + Timer` instead of `Future.timeout()` for hard deadlines.
- Snapshot mutable collections before iterating to prevent concurrent modification.
- Use `List.of(handlers[connection] ?? [])` to guard against null entries that
  appear when error and done callbacks race on the same connection.

Together, these changes make the gRPC server and client robust to the full range of
concurrent teardown scenarios that occur in production under load.
