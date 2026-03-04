# Phase 3 — Agent 9: Contextualizer

**PR #41**: `fix/named-pipe-race-condition` -> `main`
**Repository**: `open-runtime/grpc-dart`

This review places every significant PR decision in context by comparing it against the canonical gRPC implementations: **gRPC C++** (grpc/grpc), **gRPC Go** (grpc/grpc-go), and **gRPC Java** (grpc/grpc-java). For each decision, I evaluate whether the approach is standard practice, a novel adaptation, or an anti-pattern.

---

## Cross-Implementation Comparison

### 1. Shutdown Handling

#### What the PR does

`shutdownActiveConnections()` implements a four-step shutdown:

1. Cancel all `incomingStreams` subscriptions (stop accepting new DATA).
2. Cancel all `ServerHandler` instances and await `onResponseCancelDone` (drain async generators).
3. Yield one event-loop turn (`await Future.delayed(Duration.zero)`) for RST_STREAM flush.
4. Finish each connection independently with `Completer + Timer` (not `Future.timeout()`).

Server sockets are closed *before* connection draining begins.

#### gRPC Go: `GracefulStop()` / `stop()`

```go
// grpc-go server.go
func (s *Server) stop(graceful bool) {
    s.quit.Fire()
    defer s.done.Fire()
    s.closeListenersLocked()       // Step 1: stop accepting new connections
    s.serveWG.Wait()               // Wait for serving goroutines to exit
    if graceful {
        s.drainAllServerTransportsLocked()  // Step 2: send GOAWAY to all transports
    } else {
        s.closeServerTransportsLocked()     // Forceful close
    }
    for len(s.conns) != 0 {
        s.cv.Wait()                // Step 3: wait for all connections to drain
    }
    if graceful || s.opts.waitForHandlers {
        s.handlersWG.Wait()        // Step 4: wait for handler goroutines
    }
}
```

Go's `drainAllServerTransportsLocked()` calls `st.Drain("graceful_stop")` on each transport, which triggers the double-GOAWAY + PING pattern (see Section 3 below). It then waits for all connections to close via a condition variable. There is no explicit "yield to flush RST_STREAM" step because Go's HTTP/2 transport has a dedicated `loopyWriter` goroutine that serializes all outgoing frames and flushes them independently of the application goroutines.

**Key structural difference**: Go uses goroutines (one per connection) + condition variables for coordination. Dart uses a single-threaded event loop, so the PR must yield explicitly where Go's goroutines proceed concurrently.

#### gRPC Java: `NettyServerHandler.GracefulShutdown`

```java
// grpc-java NettyServerHandler.java
void start(final ChannelHandlerContext ctx) {
    goAway(ctx, Integer.MAX_VALUE, Http2Error.NO_ERROR.code(), ...);  // First GOAWAY
    pingFuture = ctx.executor().schedule(() -> secondGoAwayAndClose(ctx),
        GRACEFUL_SHUTDOWN_PING_TIMEOUT_NANOS, TimeUnit.NANOSECONDS);
    encoder().writePing(ctx, false, GRACEFUL_SHUTDOWN_PING, ...);     // Probe PING
}

void secondGoAwayAndClose(ChannelHandlerContext ctx) {
    goAway(ctx, connection().remote().lastStreamCreated(), ...);      // Second GOAWAY
    NettyServerHandler.super.close(ctx, ctx.newPromise());            // Close channel
}
```

Java uses Netty's event-loop-based executor to schedule the second GOAWAY after PING ACK or timeout. Frame ordering is guaranteed by Netty's pipeline: all writes go through the same `ChannelHandlerContext` and are serialized in order.

#### gRPC C++: `Server::Shutdown()`

C++ uses completion queues. `Server::Shutdown(deadline)` rejects new RPCs immediately, lets in-flight RPCs run until the deadline, then forcefully cancels remaining RPCs. CQ drain happens in application code: the user must call `cq->Next()` in a loop until it returns `false`.

#### Verdict: **Standard practice (adapted for Dart's event model)**

| Aspect | C++ | Go | Java | This PR |
|--------|-----|-----|------|---------|
| Stop accepting connections first | Yes | Yes | Yes | Yes |
| Cancel/drain in-flight RPCs | Yes (deadline) | Yes (GOAWAY + wait) | Yes (GOAWAY + grace) | Yes (cancel handlers + await) |
| Bounded shutdown timeout | Yes (deadline arg) | No (blocks forever or user calls Stop) | Yes (grace time) | Yes (Timer 5s) |
| Independent per-connection timeout | Implicit (thread-per-CQ) | Implicit (goroutine-per-conn) | Yes (Netty pipeline) | Yes (Completer + Timer) |

The PR's approach is structurally equivalent to Go's `GracefulStop` + Java's grace period pattern. The `Completer + Timer` instead of `Future.timeout()` is a Dart-specific adaptation that is novel but well-justified: Dart's event loop is cooperative, and if incoming DATA frames saturate the microtask queue, `Future.timeout()` (which uses `Timer` internally but chains through `Future`) can be starved. Using `Timer` directly bypasses this.

**One notable gap**: The PR does not implement the double-GOAWAY pattern used by both Go and Java. The HTTP/2 spec recommends sending an initial GOAWAY with `MAX_STREAM_ID` to allow clients to stop creating streams, followed by a second GOAWAY with the actual `lastStreamId`. This is not a correctness issue (GOAWAY with the real `lastStreamId` is sufficient), but it does mean clients that create a stream between the server's decision to shut down and the client's receipt of GOAWAY will get an unrecoverable error instead of a retryable one. This is an existing limitation of `package:http2`, not something the PR introduces.

---

### 2. Keepalive Enforcement

#### What the PR fixes

The original `server_keepalive.dart` had an inverted comparison:
```dart
// BEFORE (wrong): punishes slow pings, accepts fast ones
} else if (_timeOfLastReceivedPing!.elapsed > options.minIntervalBetweenPingsWithoutData) {
    _badPings++;
}

// AFTER (correct): punishes fast pings, accepts slow ones
} else if (_timeOfLastReceivedPing!.elapsed < options.minIntervalBetweenPingsWithoutData) {
    _badPings++;
    _timeOfLastReceivedPing!..reset()..start();  // Reset stopwatch
} else {
    _timeOfLastReceivedPing!..reset()..start();  // Reset stopwatch
}
```

The PR also resets the stopwatch on every ping (both good and bad) and adds a `_tooManyBadPingsTriggered` guard to prevent multiple ENHANCE_YOUR_CALM dispatches.

#### gRPC C++: `ping_abuse_policy.cc`

```cpp
bool Chttp2PingAbusePolicy::ReceivedOnePing(bool transport_idle) {
    const Timestamp now = Timestamp::Now();
    const Timestamp next_allowed_ping =
        last_ping_recv_time_ + RecvPingIntervalWithoutData(transport_idle);
    last_ping_recv_time_ = now;                // Always reset timestamp
    if (next_allowed_ping <= now) return false; // Ping is OK (enough time passed)
    ++ping_strikes_;                           // Too fast: increment strikes
    return ping_strikes_ > max_ping_strikes_ && max_ping_strikes_ != 0;
}
```

Critical observations from C++:
- **`last_ping_recv_time_ = now`** is set unconditionally (line 62 in the .cc file), on every ping, whether good or bad. This matches the PR's stopwatch reset behavior.
- The comparison is `next_allowed_ping <= now`, which is equivalent to `elapsed >= min_interval` meaning "enough time passed." A ping is bad when `next_allowed_ping > now`, i.e., `elapsed < min_interval`. This matches the PR's corrected `<` comparison.
- `ResetPingStrikes()` resets both the timestamp and the strike counter. It is called when DATA or header frames are sent (confirmed in grpc-go's equivalent: `resetPingStrikes` is an atomic flag set on data/header sends).
- The default `max_ping_strikes` in C++ is **2** (not 3). The PR uses `maxBadPings` which defaults to 3 in the Dart codebase.

#### gRPC Go: `handlePing()` in `http2_server.go`

```go
func (t *http2Server) handlePing(f *http2.PingFrame) {
    now := time.Now()
    defer func() {
        t.lastPingAt = now     // Always reset timestamp
    }()
    if atomic.CompareAndSwapUint32(&t.resetPingStrikes, 1, 0) {
        t.pingStrikes = 0      // Data was sent: reset strikes
        return
    }
    if t.lastPingAt.Add(t.kep.MinTime).After(now) {
        t.pingStrikes++        // Too fast: increment strikes
    }
    if t.pingStrikes > maxPingStrikes {
        t.controlBuf.put(&goAway{code: http2.ErrCodeEnhanceYourCalm, ...})
    }
}
```

Go's pattern:
- `lastPingAt = now` is set unconditionally via `defer` (always resets).
- The comparison `lastPingAt.Add(MinTime).After(now)` is equivalent to `elapsed < MinTime` — bad ping. Identical to the PR's corrected logic.
- `resetPingStrikes` is an atomic flag set when data/headers are sent, resetting both the counter and implicitly the timing (because `lastPingAt` is always updated).
- Go uses `maxPingStrikes = 2` (same as C++).

#### Verdict: **Bug fix restoring spec compliance (standard practice)**

| Aspect | C++ | Go | This PR (after fix) |
|--------|-----|-----|---------------------|
| Comparison direction | `elapsed < min` = bad | `elapsed < min` = bad | `elapsed < min` = bad |
| Timestamp reset | Every ping (unconditional) | Every ping (defer) | Every ping (unconditional) |
| Strike counter reset on data | Yes (ResetPingStrikes) | Yes (atomic flag) | No (not in this PR) |
| Max strikes default | 2 | 2 | 3 (Dart default) |
| ENHANCE_YOUR_CALM guard | Implicit (one GOAWAY) | Implicit (one put) | Explicit `_tooManyBadPingsTriggered` flag |

The original code had a logic inversion that is clearly a bug — it accepted fast pings and punished slow ones. The fix aligns exactly with C++ and Go. The stopwatch reset on every ping is also correct per both reference implementations.

**One difference**: C++ and Go both reset ping strikes when data frames are received/sent. The PR's `onDataReceived` controller serves a different purpose (keepalive liveness), and the `_badPings` counter is never reset by data activity. This means the Dart implementation is *stricter* than C++ and Go: a connection that sends bursts of fast pings followed by data frames will accumulate strikes permanently in Dart but get reset in C++/Go. This is a pre-existing behavioral difference in the Dart keepalive implementation (not introduced by this PR), but it is worth noting as a potential future alignment item.

---

### 3. RST_STREAM Flushing (The Yield Pattern)

#### What the PR does

```dart
// Step 3: Yield to let the http2 outgoing queue flush
// RST_STREAM frames before connection.finish() enqueues
// GOAWAY and closes the socket.
await Future.delayed(Duration.zero);
```

This single event-loop yield between handler cancellation (which enqueues RST_STREAM) and `connection.finish()` (which enqueues GOAWAY and closes the socket) is the most structurally unusual pattern in the PR.

#### gRPC Go: loopyWriter

Go does not need an explicit yield because the HTTP/2 transport has a dedicated writer goroutine (`loopyWriter`) that:
1. Reads from a `controlBuf` (a channel of frame commands).
2. Writes frames to the wire in order.
3. The `Drain()` call puts a GOAWAY command on the `controlBuf`.
4. RST_STREAMs from stream cancellation also go through the `controlBuf`.

Because both RST_STREAM and GOAWAY go through the same serial queue, ordering is guaranteed by the `controlBuf` sequencing — no yield needed.

#### gRPC Java: Netty pipeline

Java uses Netty's `ChannelPipeline`, which serializes all writes through a single I/O thread per channel. GOAWAY and RST_STREAM are both written through `ChannelHandlerContext`, so ordering is guaranteed by Netty's execution model.

#### gRPC C++: Completion queue

C++ uses an outgoing frame queue within the chttp2 transport. All frames (RST_STREAM, GOAWAY, DATA) are serialized through the same combiner, ensuring ordering.

#### What Dart's `package:http2` does

`package:http2`'s `ConnectionMessageQueueOut` collects outgoing frames and flushes them to the socket. `connection.finish()` enqueues a GOAWAY frame and then drains the queue. The problem is that when `handler.cancel()` enqueues RST_STREAM frames (via `stream.terminate()`), those frames are placed in the connection's outgoing queue but may not be flushed until the event loop processes the microtask queue. If `connection.finish()` is called synchronously after `handler.cancel()`, the GOAWAY may be enqueued and the socket closed before RST_STREAM frames get flushed.

#### Verdict: **Novel adaptation (correct for Dart's event model, but fragile)**

The single yield is the Dart-specific equivalent of Go's `loopyWriter` serialization, Java's Netty pipeline, and C++'s combiner. It is correct given `package:http2`'s implementation, but it is fragile because:

1. It relies on the implementation detail that one event-loop turn is sufficient for `package:http2` to flush queued frames. If `package:http2` ever changes its flushing strategy (e.g., batches frames across multiple turns), the yield becomes insufficient.
2. Under high load, microtask queue saturation could delay the flush beyond the single yield.
3. There is no verification that RST_STREAM frames were actually written to the socket.

Other implementations solve this architecturally: Go has a dedicated writer goroutine, Java has Netty's pipeline, C++ has a combiner. All three guarantee frame ordering without relying on timing. The PR's yield is a pragmatic workaround for `package:http2`'s lack of a frame-ordering guarantee, but it would be more robust to either:
- Expose a "flush" future from `package:http2` that resolves when all queued frames are written.
- Or move to an architecture where GOAWAY is only enqueued after RST_STREAM flush is confirmed.

That said, the yield is better than no yield (which is what the code had before), and for the current `package:http2` implementation, it works.

---

### 4. Handler Lifecycle Hardening

#### What the PR does

- `_addErrorAndClose()` uses separate try blocks for `addError()` and `close()`.
- `_streamTerminated` flag prevents double-terminate.
- `_trailersSent` flag prevents double-trailer.
- `cancel()` now closes `_requests` (matches all other termination paths).
- `isCanceled = true` in `sendTrailers()` to prevent handler leaks.
- `sendTrailers()` has try-catch around `_stream.sendHeaders()`.
- `_onDataIdle` has a `cancel()` guard after async interceptor await.

#### How other implementations handle this

**gRPC Go**: The `ServerStream` abstraction has a mutex-guarded state machine. `SendMsg()`, `RecvMsg()`, and close operations all check state under the mutex before proceeding. Double-close is a no-op. The `handleStream` goroutine owns the lifecycle and coordinates with the transport via `controlBuf`.

**gRPC Java**: Netty's `AbstractServerStream` uses `synchronized` blocks and boolean flags (`headersSent`, `closeSent`) to prevent double-send. Error paths converge to `transportReportStatus()` which is idempotent.

**gRPC C++**: The core library uses a state machine (`grpc_call_element`) with atomic state transitions. The `RecvClose` and `SendStatus` operations are guarded by the call's combiner (single-threaded executor), preventing concurrent access.

#### Verdict: **Standard practice (Dart-idiomatic implementation of universal patterns)**

Every gRPC implementation uses some form of:
- Idempotent close/terminate operations (flags or state machines).
- Guarded sink writes (mutex, synchronized, try-catch).
- Lifecycle ownership (one component owns the termination sequence).

The PR's approach — boolean flags (`_streamTerminated`, `_trailersSent`, `isCanceled`) + try-catch on sink operations + `_addErrorAndClose` with independent try blocks — is the Dart-idiomatic equivalent of Go's mutex-guarded state, Java's synchronized flags, and C++'s combiner-serialized state machine.

The `isCanceled = true` in `sendTrailers()` is particularly well-motivated: it ensures the handler is removed from the tracking map on normal completion, not just on cancellation. Go handles this differently (the `handleStream` goroutine always calls `removeStream` on exit), but the effect is the same.

---

### 5. Client Dispatch Loop Rework

#### What the PR does

```dart
for (final call in pendingCalls) {
    if (_state != ConnectionState.ready) {
        if (_state == ConnectionState.shutdown) {
            _shutdownCall(call);
        } else {
            _pendingCalls.add(call);  // Batch re-queue, NOT dispatchCall()
        }
        continue;
    }
    dispatchCall(call);
    await Future.delayed(Duration.zero);  // Yield for flow control frames
    if (_state == ConnectionState.ready) {
        _connectionLifeTimer..reset()..start();  // Prevent timeout during drain
    }
}
// Post-loop: exponential backoff for re-queued calls
if (_hasPendingCalls() && _state != ConnectionState.shutdown && ...) {
    _setState(ConnectionState.transientFailure);
    _currentReconnectDelay = options.backoffStrategy(_currentReconnectDelay);
    _timer = Timer(_currentReconnectDelay!, _handleReconnect);
}
```

#### How other implementations handle this

**gRPC Go**: The client transport dispatches calls through `http2Client.NewStream()`, which checks `transportDraining`, `goAway`, and `streamQuota` before creating a stream. Flow control is handled by the `loopyWriter` goroutine, which pauses when the send window is exhausted. There is no batch-dispatch loop — each RPC is dispatched independently, and flow control back-pressure is handled at the frame level.

**gRPC Java**: Netty's flow control uses `DefaultHttp2RemoteFlowController`, which queues frames when the window is exhausted and writes them when `WINDOW_UPDATE` arrives. Dispatch is asynchronous through Netty's pipeline.

**gRPC C++**: Uses flow control at the transport level via `grpc_chttp2_begin_write()`. Pending writes are batched and flushed when the flow control window allows.

#### Verdict: **Novel (necessary adaptation for Dart, with a correct backoff pattern)**

No other gRPC implementation has a client-side "dispatch loop with yields" pattern because:
- Go and Java have dedicated I/O threads/goroutines that handle flow control independently.
- C++ uses a combiner that serializes writes without blocking the application thread.

In Dart, the HTTP/2 transport and the application code share a single event loop. Without yields between dispatches, a burst of pending calls can exhaust the flow control window before `WINDOW_UPDATE` frames from the server are processed. The yield gives the event loop a chance to process incoming frames.

The batch re-queue pattern (adding to `_pendingCalls` instead of calling `dispatchCall()`) is a correct fix for what would otherwise be a zero-backoff tight loop. This pattern is analogous to Go's `backoff.Strategy` in the client transport, though Go applies it at the connection level rather than per-dispatch-batch.

The `_connectionLifeTimer` reset during the loop is a defensive measure with no direct parallel in other implementations, but it addresses a real Dart-specific problem: the connection timeout can fire during a long dispatch drain on slow CI hardware.

---

### 6. Guarded Sink Writes (http2_transport.dart, call.dart)

#### What the PR does

Wraps all three `listen()` callbacks (`onData`, `onError`, `onDone`) with try-catch to survive `StateError: Cannot add event after closing` when the HTTP/2 transport sink is closed externally.

#### How other implementations handle this

**gRPC Go**: The `loopyWriter` owns the encoder and handles all writes. If the connection is closed, the `loopyWriter` exits its loop. Application code never directly writes to the HTTP/2 framer.

**gRPC Java**: Netty's `ChannelPipeline` serializes writes. If the channel is closed, `write()` returns a failed `ChannelFuture`. The `Http2FrameWriter` checks `isStreamOpen()` before writing.

**gRPC C++**: The combiner serializes access. Writes to a closed transport return an error status without throwing.

#### Verdict: **Standard practice (Dart-specific surface, universal concept)**

Every implementation guards against writes to closed transports. Go uses ownership (single writer goroutine), Java uses pipeline ordering + futures, C++ uses combiner serialization. The PR uses try-catch, which is the idiomatic Dart approach given that `package:http2` throws `StateError` instead of returning an error code. The try-catch approach is correct but chatty (each callback has its own catch block with logging). A cleaner pattern would be a single helper method, but that is a style concern, not a correctness issue.

---

### 7. Named Pipe Transport

#### What the PR does

A two-isolate architecture:
- **Accept loop isolate**: Calls `CreateNamedPipe` + `ConnectNamedPipe` (blocking FFI) in a loop, sends handles to the main isolate via `SendPort`.
- **Main isolate**: Receives handles, wraps them in `_ServerPipeStream` with `PeekNamedPipe`-based non-blocking reads, feeds them to `serveConnection()`.

Shutdown uses `Isolate.kill(priority: Isolate.immediate)` + exit listener confirmation + dummy client connection to break blocking `ConnectNamedPipe`.

#### How other implementations handle platform transports

**gRPC C++**: No native named pipe support. The transport abstraction (`grpc_endpoint`) supports TCP and UDS. Named pipes would require a custom `grpc_endpoint` implementation. There is an open issue (grpc/grpc#13447) requesting named pipe support with no implementation.

**gRPC Go**: Named pipes are supported via the custom dialer pattern:
```go
grpc.WithContextDialer(func(ctx context.Context, addr string) (net.Conn, error) {
    return winio.DialPipeContext(ctx, addr)
})
```
The `winio` package provides a `net.Conn`-compatible wrapper for named pipes. The gRPC transport layer (HTTP/2) sits on top of `net.Conn` unchanged. Go's goroutine model means blocking reads in `winio` do not affect other goroutines.

**gRPC Java**: No native named pipe support. Non-TCP transports include `InProcessTransport` (same JVM) and UDS (via `netty-transport-native-epoll`). Named pipes would require a custom Netty `Channel` implementation.

**.NET (ASP.NET Core gRPC)**: Has official named pipe support via `SocketsHttpHandler` with `ConnectCallback`. The transport is a standard `Stream` wrapper around Win32 named pipes.

#### Verdict: **Novel architecture (well-justified by Dart's FFI constraints)**

The two-isolate design is unique across all gRPC implementations. This is directly motivated by Dart's single-threaded event loop model: `ConnectNamedPipe` is a blocking Win32 call that freezes the entire isolate. Go's goroutine scheduler and C++/Java's thread pools naturally handle blocking I/O without affecting the main event loop.

The design is sound:
- Isolate isolation prevents FFI blocking from affecting the event loop.
- `SendPort` handle transfer is safe (Win32 handles are process-global integers).
- `Isolate.immediate` kills at VM safepoints, working even during FFI calls.
- The dummy client connection pattern is a standard technique for unblocking `ConnectNamedPipe` (used in Win32 service shutdown code).

The `PeekNamedPipe` + 1ms delay read loop is a polling pattern that would not be acceptable in C++ or Go (where async I/O or I/O completion ports would be used), but is the pragmatic choice for Dart where IOCP integration is not available in the standard library.

---

### 8. Connection Generation Counter

#### What the PR does

```dart
final generation = ++_connectionGeneration;
final connection = await _transportConnector.connect();
_transportConnector.done.then((_) {
    if (generation == _connectionGeneration) {
        _abandonConnection();
    }
});
```

#### How other implementations handle this

**gRPC Go**: Uses a `transportDraining` flag + `goAway.streamID` to distinguish stale from current connections. The `ClientTransport` interface returns errors on stale operations.

**gRPC Java**: Netty channel ownership prevents this class of bug. Each channel has a single lifecycle; reconnection creates an entirely new channel object.

**gRPC C++**: The subchannel has a `connected_subchannel` pointer that is atomically swapped. Stale references detect the swap via pointer comparison.

#### Verdict: **Standard practice (generation counter is a well-known concurrency pattern)**

The generation counter is a classic technique for handling stale callbacks in asynchronous code. It is equivalent to Go's transport-level `goAway` detection, Java's per-channel-lifecycle isolation, and C++'s atomic pointer swap. The Dart implementation is straightforward and correct.

---

## Summary Verdict Table

| PR Decision | Classification | Notes |
|-------------|---------------|-------|
| **4-step shutdown sequence** | Standard practice | Structural equivalent of Go's `GracefulStop` + Java's grace period |
| **Completer + Timer** (not Future.timeout) | Novel adaptation | Correct for Dart's saturated event loop; no parallel in other impls |
| **Keepalive comparison fix** (`<` not `>`) | Bug fix (spec compliance) | Restores alignment with C++ and Go |
| **Stopwatch reset on every ping** | Standard practice | Matches C++ `last_ping_recv_time_ = now` and Go `lastPingAt = now` |
| **_tooManyBadPingsTriggered guard** | Standard practice | Prevents double GOAWAY; equivalent to Go's single `controlBuf.put` |
| **RST_STREAM yield** | Novel adaptation (fragile) | No parallel in other impls; correct for current package:http2 |
| **Handler lifecycle flags** | Standard practice | Dart-idiomatic equivalent of Go's mutex + Java's synchronized |
| **_addErrorAndClose** | Standard practice | Independent try blocks match error-handling in all impls |
| **cancel() closes _requests** | Bug fix (completeness) | Every other termination path closed it; this was the missing one |
| **isCanceled in sendTrailers()** | Standard practice | Ensures cleanup on normal completion; matches Go's removeStream |
| **Client dispatch loop with yields** | Novel adaptation | Dart-specific; other impls have dedicated I/O threads |
| **Batch re-queue with backoff** | Standard practice | Matches Go's backoff.Strategy at the connection level |
| **Guarded sink writes** | Standard practice | Universal pattern; Dart uses try-catch where others use ownership |
| **Two-isolate named pipe server** | Novel architecture | Unique to Dart; well-justified by FFI blocking constraints |
| **Connection generation counter** | Standard practice | Classic stale-callback pattern; equivalent to pointer swaps/flags |
| **Missing double-GOAWAY** | Gap (not introduced by PR) | Go and Java use GOAWAY(MAX_ID) + PING + GOAWAY(real_ID) |
| **No strike reset on data** | Gap (pre-existing) | C++ and Go reset ping strikes on data frames; Dart does not |

---

## Overall Assessment

The PR makes decisions that are overwhelmingly aligned with standard gRPC implementation patterns. Where it diverges (the RST_STREAM yield, the dispatch loop yields, the two-isolate pipe server), the divergence is justified by fundamental differences in Dart's execution model: single-threaded event loop, cooperative scheduling, and FFI blocking.

There are no anti-patterns. The two identified gaps (no double-GOAWAY, no ping-strike reset on data) are pre-existing limitations of the Dart gRPC and `package:http2` codebases, not regressions introduced by this PR.

The most fragile decision is the single-yield RST_STREAM flush (Step 3 of shutdown). While correct today, it depends on `package:http2` implementation internals. A more robust approach would involve exposing a flush confirmation from `package:http2`, but that is an upstream dependency change outside the scope of this PR.
