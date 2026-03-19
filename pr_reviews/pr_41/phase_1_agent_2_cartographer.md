# Phase 1 — Agent 2: Cartographer
## PR #41 Structural Map: fix/named-pipe-race-condition

---

## 1. Class Hierarchy

```
ConnectionServer                     (lib/src/server/server.dart:83)
  │  Core logic: serveConnection, shutdownActiveConnections, _finishConnection
  │  Owns: handlers map, connection lists, keepalive controllers
  │
  ├── Server                          (lib/src/server/server.dart:466)
  │     Adds: TCP/TLS socket binding (ServerSocket / SecureServerSocket)
  │     Adds: _connectionSockets map (Socket destroy on shutdown)
  │     shutdown(): close listeners → shutdownActiveConnections()
  │
  └── NamedPipeServer                 (lib/src/server/named_pipe_server.dart:96)
        Adds: two-isolate accept loop architecture (Windows only)
        Adds: _activeStreams list (_ServerPipeStream tracking)
        shutdown(): cooperative stop + Isolate.immediate kill
        Does NOT populate _connectionSockets (no raw Socket)

ServerHandler extends ServiceCall    (lib/src/server/handler.dart:37)
  One instance per HTTP/2 stream (one per RPC call).
  Created by ConnectionServer.serveStream_() and tracked in handlers[connection].

_ServerPipeStream                    (lib/src/server/named_pipe_server.dart:435)
  Bidirectional stream wrapper around a Win32 HANDLE. Main-isolate only.
  Wraps the handle into incoming/outgoing StreamControllers for HTTP/2.
```

---

## 2. ConnectionServer: Collections and What They Track

| Collection | Key | Value | Purpose |
|---|---|---|---|
| `handlers` | `ServerTransportConnection` | `List<ServerHandler>` | All active RPCs per connection |
| `_connections` | — | `List<ServerTransportConnection>` | Ordered list of live connections |
| `_incomingSubscriptions` | `ServerTransportConnection` | `StreamSubscription` | Cancel on shutdown to stop new streams |
| `_connectionSockets` | `ServerTransportConnection` | `Socket` | TCP/TLS only; destroy to break FrameReader |
| `_keepAliveControllers` | `ServerTransportConnection` | `StreamController<void>` | Must be closed; unclosed keeps VM alive |
| `_activeStreams` | — | `List<_ServerPipeStream>` | Named-pipe only; force-close on shutdown |

---

## 3. ServerHandler State Flags

| Flag | Type | Set by | Guards |
|---|---|---|---|
| `_headersSent` | `bool` | `sendHeaders()` | Prevents double header send |
| `_trailersSent` | `bool` | `sendTrailers()` | Prevents double trailer send; skip RST_STREAM if set |
| `_streamTerminated` | `bool` | `_terminateStream()` | Prevents double RST_STREAM |
| `_isTimedOut` | `bool` | timeout path | Exposed as `isTimedOut` |
| `_hasReceivedRequest` | `bool` | `_onDataActive()` | Guards `_onDoneExpected` unimplemented error |
| `isCanceled` (Completer) | `bool` | `cancel()`, `sendTrailers()`, `_onError()` | Idempotent; drives `onCanceled` future |

`_isCanceledCompleter` provides two futures:
- `onCanceled` — resolves when RPC is considered cancelled; used by `ConnectionServer` to remove handler from map
- `onResponseCancelDone` — resolves when `_responseSubscription.cancel()` finishes; awaited in `shutdownActiveConnections` Step 2

### ServerHandler State Machine (Incoming Message Listener transitions)

```
[CREATED] handle() called
    │  _incomingSubscription listens with _onDataIdle
    │  outgoingMessages.done.whenComplete → cancel()
    ▼
[IDLE] Waiting for header frame
    │  _onDataIdle: parses headers, resolves service/method
    │  Pauses incoming subscription
    ▼
[ACTIVE] Serving call
    │  _incomingSubscription resumes, switches to _onDataActive
    │  _responseSubscription listens on _responses
    │  Data: _onResponse → sendHeaders (lazy), _stream.sendData
    │  Done: _onResponseDone → sendTrailers → _trailersSent=true, isCanceled=true
    │
    ├── _onError(error): client cancel → isCanceled, RST_STREAM
    ├── _onDoneError(): unexpected close → sendError, _terminateStream
    ├── _onDoneExpected(): clean close → _requests.close
    └── cancel(): external cancel → _requests.addError+close, RST_STREAM (if !_trailersSent)

[TERMINAL] isCanceled completed, removed from handlers map
```

---

## 4. shutdownActiveConnections() — Step-by-Step Sequence

`ConnectionServer.shutdownActiveConnections()` is the shared shutdown path called by both `Server.shutdown()` and `NamedPipeServer.shutdown()`.

```
Step 1   Cancel _incomingSubscriptions (parallel, 5s timeout)
         → stops server accepting new HTTP/2 streams
         → prevents new DATA frames from blocking connection.finish()

Step 1.5 Close _keepAliveControllers
         → subscription cancel does NOT fire onDone, so controllers would
           never close; unclosed controllers keep the Dart VM alive forever

Step 2   For each connection: handler.cancel() on all handlers
         → sets isCanceled, closes _requests, sends RST_STREAM (if !_trailersSent)
         → stores _responseCancelFuture from _responseSubscription.cancel()
         → awaits all onResponseCancelDone (parallel, 5s timeout)
         → async* generators need event-loop turns to honour cancel signal

Step 3   await Future.delayed(Duration.zero)
         → yields to http2 ConnectionMessageQueueOut so RST_STREAM frames
           are flushed BEFORE GOAWAY closes the socket
         → GOAWAY alone does not terminate already-acknowledged streams

Step 4   _finishConnection(connection) for each connection (parallel)
         → Starts 5s Completer+Timer deadline (NOT .timeout() — saturated
           event loop can prevent .timeout() from firing)
         → connection.finish() attempts graceful GOAWAY + stream drain
         → On timeout: connection.terminate() (2s sub-deadline)
         → After terminate: _connectionSockets[connection]?.destroy()
           (TCP only; no-op for NamedPipe)
         → One hung connection never blocks others
```

### NamedPipeServer.shutdown() — Additional Steps

```
Step 1   _isRunning = false (guard against new _handleIsolateMessage activity)

Step 1.5 Start shutdownActiveConnections() future (non-awaited, captured)
         → snapshots active connections immediately

Step 2   force-close all _activeStreams (stream.close(force: true))
         → calls DisconnectNamedPipe + CloseHandle
         → breaks blocking ReadFile/WriteFile in pipe I/O paths
         → _activeStreams.clear()

Step 2.5 await shutdownConnectionsFuture (from Step 1.5)

Step 3   _stopSendPort?.send(null) — cooperative stop to accept loop
         → accept loop's shouldStop flag becomes true at next 1ms yield

Step 4   serverIsolate.addOnExitListener + serverIsolate.kill(immediate)
         → exit listener confirms termination (Completer + ReceivePort)
         → Isolate.immediate kills even mid-event (safety net)
         → 5s timeout; logs warning on timeout but does not block

Step 5   Cancel _receivePortSubscription, close _receivePort
         → must be AFTER isolate kill to avoid missing straggler messages
```

---

## 5. Named Pipe Architecture

### Two-Isolate Design

```
Main Isolate                           Server Isolate (_acceptLoop)
──────────────────────────────         ─────────────────────────────────────
NamedPipeServer.serve()         spawn  _AcceptLoopConfig sent as arg
  _receivePort.listen(...)  ◄────────  config.mainPort.send(_ServerReady)
  _stopSendPort ◄──────────────────── config.stopPort.send(stopPort.sendPort)
  serve() awaits _readyCompleter       CreateNamedPipe (PIPE_ACCESS_DUPLEX)
                                       SetNamedPipeHandleState(PIPE_NOWAIT)
  _readyCompleter.complete() ◄──────── config.mainPort.send(_ServerReady())
                                       [client connect poll loop, 1ms yields]
  _handleIsolateMessage:               ConnectNamedPipe (non-blocking NOWAIT)
    _PipeHandle → _handleNewConnection   → result: connected, already connected,
    _ServerReady → completer             → or still listening (retry after 1ms)
    _ServerError → log/completer error  SetNamedPipeHandleState(PIPE_WAIT)
                                        config.mainPort.send(_PipeHandle(hPipe))
  _handleNewConnection(hPipe):
    _ServerPipeStream(hPipe)            [loop back for next connection]
    ServerTransportConnection.viaStreams
    serveConnection(connection)
```

### Message Protocol (Isolate → Main)

| Message type | Direction | Meaning |
|---|---|---|
| `_AcceptLoopConfig` | Main → Isolate | Spawn argument: pipeName, ports, maxInstances |
| `SendPort` (stop) | Isolate → Main | Accept loop's stop ReceivePort; stored as `_stopSendPort` |
| `_ServerReady` | Isolate → Main | First pipe instance created; serve() can return |
| `_PipeHandle(int handle)` | Isolate → Main | Win32 HANDLE for newly accepted connection |
| `_ServerError(String)` | Isolate → Main | CreateNamedPipe or mode-switch failure |
| `null` (stop signal) | Main → Isolate | Cooperative shutdown; sets `shouldStop = true` |

Win32 HANDLE sharing works because Dart isolates share the same OS process (same Win32 handle table).

### _ServerPipeStream (Main Isolate)

Wraps a Win32 `HANDLE` in two `StreamController<List<int>>`:
- `_incomingController` — PeekNamedPipe polling → ReadFile → `add()`
- `_outgoingController` — `_outgoingSubscription` → WriteFile

`close(force: true)` cancels `_outgoingSubscription` + calls `DisconnectNamedPipe` + `CloseHandle`.
Normal close defers handle cleanup to `_onOutgoingDone()` (deferred close path with 5s safety timer).

---

## 6. Http2ClientConnection — Connection Lifecycle and Dispatch Loop

### Connection State Machine

```
          idle ──────────────────────────────────────────────┐
           │  dispatchCall() with no transport               │
           │  → _connect()                                   │
           ▼                                                  │
       connecting                                            │
           │  connectTransport() awaits socket + SETTINGS    │
           │  generation counter guards stale .done callbacks│
           ▼                                                  │
         ready ──────────────────────────────────────────────┤
           │  dispatchCall() → _startCall()                  │
           │  Pending calls dispatched with yield between    │
           │  each (WINDOW_UPDATE processing)                │
           │  _connectionLifeTimer reset after each yield    │
           │                                                  │
           ├── idle timeout → _handleIdleTimeout → idle      │
           │                                                  │
           ├── _abandonConnection() (no pending) → idle ─────┘
           │
           └── _abandonConnection() (pending calls)
                │
                ▼
         transientFailure
           │  Timer(_currentReconnectDelay) → _handleReconnect
           │  Exponential backoff via options.backoffStrategy
           ▼
         connecting (retry)

  shutdown (terminal from any state via shutdown() or terminate())
    → _setShutdownState(): cancel timer, fail all pending calls, clear list
    → _transportConnection.finish() or .terminate()
    → _disconnect(): null transport, cancel frame sub, stop life timer
    → _transportConnector.shutdown(): release OS handle
```

### Key Fields

| Field | Type | Purpose |
|---|---|---|
| `_state` | `ConnectionState` | idle / connecting / ready / transientFailure / shutdown |
| `_pendingCalls` | `List<ClientCall>` | Calls waiting for a ready connection |
| `_transportConnection` | `ClientTransportConnection?` | Live HTTP/2 transport; null when disconnected |
| `_timer` | `Timer?` | Dual-use: idle timeout (ready) OR reconnect delay (transientFailure) |
| `_connectionLifeTimer` | `Stopwatch` | Detects stale connections via `connectionTimeout` |
| `_currentReconnectDelay` | `Duration?` | Exponential backoff state |
| `_connectionGeneration` | `int` | Guards stale `.done` callbacks on reconnect |
| `_frameReceivedSubscription` | `StreamSubscription?` | Keepalive frame-received signal; cancelled in `_disconnect` |

### Dispatch Loop Re-queue Pattern (Race Fix)

When state changes mid-dispatch (e.g., GOAWAY during pending-call drain):

```dart
// WRONG — calls dispatchCall() per remaining call → _connect() with zero backoff
dispatchCall(call);  // in transientFailure triggers _connect immediately

// CORRECT — batch re-queue, then apply exponential backoff once
_pendingCalls.add(call);  // re-queue all remaining calls
// post-loop: if still has pending && not shutdown/connecting:
_setState(ConnectionState.transientFailure);
_currentReconnectDelay = options.backoffStrategy(_currentReconnectDelay);
_timer = Timer(_currentReconnectDelay!, _handleReconnect);
```

`_abandonConnection()` is NOT terminal: it moves to idle (no pending) or transientFailure (with backoff). `_handleConnectionFailure()` IS terminal: errors all pending calls, no re-queue.

---

## Summary: Ownership Boundaries

```
NamedPipeServer.shutdown()
  ├── owns: _serverIsolate, _receivePort, _stopSendPort, _activeStreams
  └── delegates: shutdownActiveConnections() (ConnectionServer)

ConnectionServer.shutdownActiveConnections()
  ├── owns: _incomingSubscriptions, _keepAliveControllers, handlers, _connections
  └── delegates: _finishConnection() per connection

_finishConnection()
  ├── owns: Completer+Timer deadline, connection.finish() / .terminate()
  └── delegates: _connectionSockets[connection]?.destroy() (TCP only)

ServerHandler.cancel()
  ├── owns: _requests (addError+close), _responseSubscription.cancel()
  └── delegates: _terminateStream() → _stream.terminate() (RST_STREAM)
```
