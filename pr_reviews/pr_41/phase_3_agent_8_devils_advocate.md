# Phase 3 -- Agent 8: Devil's Advocate

**PR #41**: `fix/named-pipe-race-condition` -> `main`
**Repository**: `open-runtime/grpc-dart`

---

## Preamble

This review deliberately argues the strongest counter-position for each major
design decision in PR #41. The goal is not to be right, but to surface risks
and assumptions the author may not have examined. Where a decision is sound,
I say so. Where it is defensible but fragile, I say that too.

---

## Challenge 1: Completer+Timer vs Future.timeout()

### The Decision

`_finishConnection()` in `server.dart:354-438` uses a hand-rolled
`Completer<void>` + `Timer(Duration(seconds: 5), forceTerminate)` instead of
calling `connection.finish().timeout(Duration(seconds: 5))`. The comment at
line 334-337 states: "Using Completer + Timer instead of Future.timeout()
because .timeout() relies on the same event loop that may be saturated by
incoming data frames, causing the timeout to never fire."

### The Strongest Argument Against It

**The claim that `Future.timeout()` fails under event loop saturation is
imprecise, and the alternative has the exact same vulnerability.**

Dart's `Future.timeout()` is implemented using `Timer`. From the Dart SDK
(`dart:async`, `future_impl.dart`):

```dart
Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) {
  ...
  timer = Zone.current.createTimer(timeLimit, () { ... });
  ...
}
```

Both `Future.timeout()` and a raw `Timer()` use `Zone.current.createTimer()`.
They are backed by the same native timer mechanism. If the event loop is so
saturated that a `Timer` callback cannot fire, then the hand-rolled
`Timer(5s, forceTerminate)` will ALSO not fire. The two approaches have
identical timer-delivery guarantees because they are literally the same
mechanism.

What the author may have actually observed is a different problem: if
`connection.finish()` completes with an error synchronously or via microtask,
`.timeout()` immediately cancels its internal timer and returns the error --
never invoking `onTimeout`. This is `.timeout()`'s contract: it resolves
with whichever completes first (the original future OR the timeout), and
errors from the original future propagate. The Completer+Timer pattern
avoids this because the Timer is independent of the original future's
completion -- even if `finish()` errors out, `forceTerminate` is still
called. But that is a correctness argument about error handling, not about
event loop saturation.

The complexity cost is real: 80 lines of state management (the `complete()`
helper, the `forceTerminate()` closure, the `terminateCalled` guard, the
nested `try/catch/catchError/whenComplete` chain) versus what would be
approximately 15 lines with `.timeout()`.

Furthermore, as BUG-1 from the Bug Hunter (Phase 2, Agent 4) identified,
the inner `terminate()` call at line 371 still uses `.timeout(2s)` --
contradicting the stated rationale. If the event loop is truly saturated
(which is why `forceTerminate()` was called), then `terminate().timeout(2s)`
is subject to the same alleged vulnerability. This inconsistency undermines
the documented justification.

### The Strongest Argument For It

The Completer+Timer pattern provides a structural guarantee that no code path
can suppress the deadline. With `.timeout()`:

1. If `finish()` throws synchronously, the `.timeout()` call itself may
   throw before the timer is registered.
2. If `finish()` completes with an error immediately, `.timeout()` resolves
   with that error and cancels the timer -- meaning `forceTerminate` never
   runs. The connection hangs in a half-finished state.
3. If `finish()` returns a future that never completes AND never errors, both
   approaches would fire the timer after 5 seconds. But only the
   Completer+Timer pattern fires `forceTerminate` even when `finish()` errors.

The Completer+Timer makes the guarantee explicit: after 5 seconds, either
`finish()` completed or `forceTerminate()` runs. Period. No edge case in
`finish()`'s behavior can prevent the deadline from firing. With
`.timeout()`, `finish()` erroring out is a silent escape hatch that skips
the `onTimeout` callback entirely, and the connection is never terminated.

### Verdict: Right call, wrong justification.

The Completer+Timer pattern is the correct choice for a hard deadline on
`connection.finish()`. But the stated reason ("event loop saturation prevents
timer from firing") is technically inaccurate -- both `.timeout()` and raw
`Timer` use the same underlying mechanism. The real reason the pattern is
needed is that `.timeout()` cannot guarantee the `onTimeout` path runs when
the underlying future completes with an error. The documentation should be
corrected to state the actual reason, and the inconsistency with
`terminate().timeout(2s)` at line 371 should be resolved (BUG-1 is real
and should be fixed).

---

## Challenge 2: 4-Step Shutdown Sequence

### The Decision

`shutdownActiveConnections()` in `server.dart:260-338` implements a 4-step
(really 5-step: 1, 1.5, 2, 3, 4) shutdown sequence:
1. Cancel incoming subscriptions
1.5. Close keepalive controllers
2. Cancel all handlers + await response subscription cancellation
3. Yield one event loop turn for RST_STREAM flush
4. Finish each connection with Completer+Timer deadline

### The Strongest Argument Against It

**This is over-engineered. Two steps should suffice: terminate all
connections immediately + destroy sockets.**

The entire sequence exists to achieve a "graceful" GOAWAY-based shutdown.
But in practice:

- Step 1 cancels incoming subscriptions, stopping new DATA frames. But why
  bother? If we are shutting down, we do not care about new data.
- Step 1.5 closes keepalive controllers to prevent VM hangs. But this is
  only needed because cancelling a subscription does not fire `onDone`. If
  the controller was created with `sync: true` and wired differently, this
  step would be unnecessary. It patches a design gap in how keepalive
  controllers are lifecycle-managed.
- Step 2 cancels all handlers and awaits their response cancel futures. This
  is complex because async* generators need event loop turns to process
  cancel signals. But if we just called `connection.terminate()` (which
  sends RST_STREAM on every open stream), the client would clean up on its
  own.
- Step 3 is a single `await Future.delayed(Duration.zero)` to flush
  RST_STREAM frames. But is one yield actually enough? If the HTTP/2
  connection has N open streams, each needing an RST_STREAM frame, the
  outgoing message queue may need multiple event loop turns to flush all of
  them. A single yield flushes whatever is ready in that microtask cycle,
  but there is no proof that all RST_STREAM frames are queued synchronously.
  The write callback for stream N might only be registered after the write
  callback for stream N-1 completes.
- Step 4 tries `finish()` then falls back to `terminate()`. But
  `terminate()` is what we should have done from the start if the goal is
  "shut down reliably."

A simpler alternative:
```dart
Future<void> shutdownActiveConnections() async {
  for (final connection in List.of(_connections)) {
    connection.terminate();
    _connectionSockets.remove(connection)?.destroy();
  }
  for (final connection in List.of(_connections)) {
    _keepAliveControllers.remove(connection)?.close();
  }
}
```

This sends RST_STREAM on all streams, destroys sockets to stop the
FrameReader, and closes keepalive controllers. Total: ~10 lines. No
Completer+Timer machinery, no yield, no multi-step orchestration.

### The Strongest Argument For It

The 4-step sequence exists because `connection.terminate()` alone is not
sufficient in production:

1. **RST_STREAM is not GOAWAY**: `terminate()` sends RST_STREAM per-stream,
   but clients that are mid-send may not process RST_STREAM before
   attempting to send more data. GOAWAY (from `finish()`) tells the client
   "stop opening new streams," which is a fundamentally different signal.
   Without it, clients on poor connections may immediately reconnect and
   hammer the shutting-down server.

2. **async* generators**: Calling `terminate()` does not cancel the Dart
   async* generator that is producing response values. The generator
   continues yielding until the subscription is cancelled AND the cancel
   signal propagates through the event loop. If we skip Step 2, the
   generator holds a reference to the connection, preventing garbage
   collection and potentially holding database connections or file handles.

3. **VM hang prevention**: Step 1.5 is necessary because of a real Dart VM
   behavior -- unclosed `StreamController` listeners keep the process alive.
   This was the root cause of 30-minute hangs on Windows CI. No amount of
   connection.terminate() fixes this.

4. **One yield IS enough for RST_STREAM**: HTTP/2's `ConnectionMessageQueueOut`
   drains its write buffer synchronously when the event loop yields. All
   RST_STREAM frames queued by handler.cancel() in Step 2 are in the
   outgoing buffer before Step 3. A single yield lets the HTTP/2 transport's
   write callback run once, which drains the entire buffer. The HTTP/2
   spec requires RST_STREAM to be a single 9-byte frame per stream --
   they are all queued synchronously, not asynchronously.

5. **Graceful shutdown matters for observability**: Server metrics,
   distributed tracing, and logging all benefit from clean GOAWAY+drain
   rather than abrupt RST_STREAM. The 5-second fallback to terminate()
   ensures we try graceful first but never hang.

### Verdict: Right call, with one open question.

The 4-step sequence is correct for a production gRPC server that needs
graceful shutdown. The "just terminate everything" approach sacrifices client
observability, leaks async* generators, and does not solve the VM hang
problem.

However, the Step 3 single-yield guarantee deserves formal verification.
The claim that "all RST_STREAM frames are queued synchronously before the
yield" depends on the internal implementation of `package:http2`'s outgoing
message queue. If a future version of that package defers write scheduling,
a single yield would be insufficient. The comment at line 328-330 should
document this dependency explicitly (e.g., "this relies on
ConnectionMessageQueueOut.enqueueMessage being synchronous") so that an
upstream http2 package update does not silently break the shutdown sequence.

Additionally, Step 2 uses `.timeout(5s)` at line 314 -- the exact pattern
the PR explicitly rejects for Step 4. Either the "event loop saturation"
concern applies to both steps (in which case Step 2 should also use
Completer+Timer), or it does not apply to either. The inconsistency suggests
the threat model is incomplete. The difference may be that Step 1 already
cancelled incoming subscriptions, so by Step 2 the event loop is no longer
saturated. If so, this should be documented.

---

## Challenge 3: Two-Isolate Named Pipe Architecture

### The Decision

`NamedPipeServer` in `named_pipe_server.dart:96` uses a two-isolate design:
a server isolate runs the accept loop (CreateNamedPipe + ConnectNamedPipe),
and the main isolate handles all data I/O via PeekNamedPipe polling. The
isolates communicate via SendPort/ReceivePort, passing raw Win32 HANDLEs
as integers.

### The Strongest Argument Against It

**`dart:ffi` with NativePort or overlapped I/O would eliminate the isolate
entirely, reducing complexity by ~400 lines.**

The isolate exists for one reason: `ConnectNamedPipe` in `PIPE_WAIT` mode
blocks the calling thread, freezing the Dart event loop. But this PR already
solves that problem with `PIPE_NOWAIT` polling. The accept loop at line
1029-1048 uses:

```dart
mode.value = PIPE_READMODE_BYTE | PIPE_NOWAIT;
// ...
while (!shouldStop) {
  final result = ConnectNamedPipe(hPipe, nullptr);
  // ... check result ...
  await Future<void>.delayed(const Duration(milliseconds: 1));
}
```

This is non-blocking. It never freezes the event loop. So why does it need
to run in a separate isolate? If `ConnectNamedPipe` in `PIPE_NOWAIT` mode
returns immediately, the polling loop could run in the main isolate without
blocking anything. The accept loop already yields every 1ms via
`Future.delayed`.

Running the accept loop in the main isolate would eliminate:
- `Isolate.spawn` and its error handling (~20 lines)
- `_AcceptLoopConfig` message class (~15 lines)
- `_ServerReady`, `_PipeHandle`, `_ServerError` message classes (~25 lines)
- `_handleIsolateMessage` dispatcher (~30 lines)
- Stop port bootstrap sequence (~25 lines)
- Exit listener + `Isolate.kill` shutdown sequence (~35 lines)
- The entire message-passing protocol documentation

That is roughly 150-200 lines of removed complexity, plus elimination of
all isolate lifecycle bugs (the entire Isolate.immediate vs beforeNextEvent
investigation becomes moot).

Alternatively, Win32 overlapped I/O with `OVERLAPPED` structures and
`WaitForSingleObject` would allow truly event-driven accept without polling.
The Dart `NativePort` API (`dart:ffi`) can receive callbacks from native
code, enabling a C helper to call `ConnectNamedPipe` with an `OVERLAPPED`
parameter and signal the Dart isolate on completion.

### The Strongest Argument For It

The two-isolate architecture was not an arbitrary choice -- it evolved from
a failed single-isolate attempt that is documented in the architecture
comment (line 74-76):

> The previous architecture (data I/O in the server isolate) deadlocked
> because `ConnectNamedPipe` blocked the server isolate's event loop,
> preventing `PeekNamedPipe` polling and `WriteFile` calls from executing.

The `PIPE_NOWAIT` mode was introduced as PART of the two-isolate solution.
But PIPE_NOWAIT has a critical behavioral difference: the server isolate
switches back to `PIPE_WAIT` mode at line 1071 BEFORE sending the handle
to the main isolate. This is because `ReadFile` on a `PIPE_NOWAIT` handle
has broken semantics (returns success with zero bytes when no data is
available, which is indistinguishable from a zero-length message). The main
isolate's `_readLoop` uses `PeekNamedPipe` + `ReadFile` in `PIPE_WAIT`
mode, where `ReadFile` blocks until data is available -- but only for the
duration of the read, not indefinitely.

If the accept loop ran in the main isolate, the 1ms poll delays would
compete with data I/O for event loop time. With 50 concurrent connections
each doing `PeekNamedPipe` polling every 1ms, that is 50,000 timer
callbacks per second. Adding an accept loop that also polls every 1ms is
a 2% overhead increase. Under 500 connections (the named pipe target), the
main isolate processes 500,000 timer callbacks per second just for reads.
Adding the accept loop's polling is negligible. So the performance argument
for separation is weak.

However, the isolate provides a clean failure boundary. If `CreateNamedPipe`
fails catastrophically (e.g., invalid pipe name, access denied), the failure
is contained in the server isolate and communicated back via `_ServerError`.
In a single-isolate design, an unhandled FFI exception in `CreateNamedPipe`
would crash the entire main isolate, taking down all active connections.

The `NativePort` alternative is theoretically cleaner but has practical
issues: (a) it requires writing and shipping a C helper library, which
complicates the Dart-only distribution model, (b) Dart's `NativePort` API
has limited documentation and edge cases around GC pressure, and (c) the
`OVERLAPPED` + `WaitForSingleObject` pattern requires a dedicated OS thread,
which is what the isolate already provides (Dart isolates map 1:1 to OS
threads).

### Verdict: Defensible but over-engineered for the current use case.

The two-isolate architecture is a correct solution to the blocking-FFI
problem, but it solves a problem that `PIPE_NOWAIT` already solves. Since
the PR already implements non-blocking `ConnectNamedPipe`, the accept loop
could run in the main isolate with negligible performance impact. The
isolate adds ~200 lines of complexity, introduces an entire class of isolate
lifecycle bugs (the `Isolate.immediate` vs `beforeNextEvent` saga), and
makes debugging harder because pipe state is split across two isolates.

The failure-boundary argument has merit but is narrow: `CreateNamedPipe`
failures are startup errors that should crash the server anyway.

If the named pipe server is under active development and may later need
blocking `ConnectNamedPipe` for non-NOWAIT scenarios, keeping the isolate as
forward investment makes sense. If PIPE_NOWAIT is the permanent solution,
the isolate should be considered for removal in a future simplification pass.
This is not a blocking issue for PR #41, but it should be documented as
technical debt.

---

## Challenge 4: PIPE_NOWAIT Polling with 1ms Delays

### The Decision

Both the accept loop (line 1048) and `_readLoop` (line 544) use 1ms
`Future.delayed` as their idle-poll interval.

### The Strongest Argument Against It

**1ms polling wastes CPU and does not scale.**

On an idle server with one pipe waiting for a connection, the accept loop
executes `ConnectNamedPipe` + `Future.delayed(1ms)` = 1000 FFI calls per
second, burning CPU for nothing. On the read side, each idle connection
polls `PeekNamedPipe` 1000 times per second. With 100 idle connections,
that is 100,000 `PeekNamedPipe` calls per second -- all returning "no data."

Windows provides purpose-built mechanisms for this:

- **Overlapped I/O + IOCP**: `ConnectNamedPipe` with an `OVERLAPPED`
  parameter returns immediately and signals an event when a client connects.
  `WaitForMultipleObjects` can wait on multiple pipe handles simultaneously
  with zero CPU usage during idle periods.

- **`ReadFileEx` + completion routines**: For reads, `ReadFileEx` with a
  completion callback fires only when data arrives, eliminating polling.

- **`WaitForSingleObject` on a pipe handle**: Blocks the thread until data
  is available, with no polling. In an isolate, this is safe because the
  isolate's thread has nothing else to do.

The 1ms poll interval also creates a latency floor. Even when data is
available, the read loop must wait up to 1ms before the next `PeekNamedPipe`
call detects it. For latency-sensitive RPCs, this is an unnecessary 0.5ms
average delay per message segment.

On Windows, `Future.delayed(Duration(milliseconds: 1))` actually waits
~15.6ms due to the default timer resolution (the MEMORY.md notes this
explicitly: "Timer(Duration(milliseconds: 1)) -> ~15.6ms (OS timer)"). So
the actual poll interval is 15.6ms, not 1ms. This means the accept loop
fires ~64 times per second and reads have up to 15.6ms latency per segment.
This is a significant performance gap versus overlapped I/O.

### The Strongest Argument For It

Overlapped I/O and IOCP require either:
(a) A C/C++ helper library compiled and shipped alongside the Dart package,
(b) Complex `dart:ffi` bindings for `OVERLAPPED` structures, completion
    ports, and `WaitForMultipleObjects`, or
(c) A dedicated thread pool managed from Dart.

All three are significantly more complex than the current 5-line polling
loop. The polling approach is:
- Pure Dart (no native helper library)
- Trivially debuggable (add a print statement anywhere)
- Portable across Dart versions (no dependency on `NativePort` stability)
- Correct (never misses data, never blocks the event loop)

The CPU cost is bounded: 64 `PeekNamedPipe` calls/second per connection at
Windows' 15.6ms resolution is negligible. `PeekNamedPipe` is a kernel
system call that completes in microseconds. Even at 500 connections, that is
32,000 syscalls/second -- well within normal operating parameters for a
Windows system.

The 15.6ms latency floor only applies to the poll interval, not to
throughput. Once data starts flowing, `PeekNamedPipe` returns data
immediately on the next poll, and the read loop processes the entire buffer
in a single `ReadFile` call. For streaming RPCs, the first message has
up to 15.6ms latency, but subsequent messages arrive at wire speed because
the pipe buffer (64KB by default) accumulates data between polls.

For a local-machine IPC transport (named pipes reject remote clients via
`PIPE_REJECT_REMOTE_CLIENTS`), 15.6ms worst-case latency is acceptable.
This is not a cross-datacenter transport.

### Verdict: Acceptable for the current scope, with a documented limitation.

The polling approach is the right pragmatic choice for a Dart-only package
that ships as a pub dependency. Overlapped I/O would require native code,
which conflicts with the package distribution model.

However, the 15.6ms timer resolution on Windows should be documented as a
known limitation, because the comments say "1ms" but the actual behavior is
15.6ms. This affects:
- Accept loop responsiveness during shutdown (up to 15.6ms, not "1-2ms" as
  stated in comments at lines 365-366 and 1047)
- Read latency for the first message in a new burst
- The shutdown stop signal processing time

The code comments should be updated to reflect the Windows timer resolution
reality, and the `MEMORY.md` timer resolution findings should be referenced
in the source code.

---

## Challenge 5: try/catch on Every Sink Callback

### The Decision

In `http2_transport.dart:47-96` and `call.dart:262-308`, every `outSink.add`,
`outSink.addError`, and `outSink.close` call is wrapped in an individual
try/catch block. The catch logs the error and continues.

### The Strongest Argument Against It

**This treats symptoms, not root causes. The correct fix is to prevent sinks
from being closed externally while they have active producers.**

The "Cannot add event after closing" `StateError` occurs because the HTTP/2
transport stream's outgoing message sink is closed by one code path (e.g.,
RST_STREAM handling in `package:http2`) while another code path (the
outgoing data subscription) is still pushing data. This is a broken ownership
model: two unrelated code paths both have close authority over the same sink.

The principled fix is to make the ownership explicit:

1. The outgoing subscription should own a local `StreamController` that
   buffers messages.
2. The buffer controller forwards to the transport sink.
3. When the transport sink is closed externally, the buffer controller
   catches the error once, cancels the source subscription, and stops
   forwarding.

This collapses 6 try/catch blocks (3 in http2_transport.dart, 3 in
call.dart) into a single error handler on the forwarding subscription. It
also prevents the semantic issue where `outSink.add(message)` silently
drops the message -- the caller has no idea the message was not delivered.

With the current approach, an RPC response frame is silently dropped when
the transport closes mid-send. The client sees an incomplete response with
no error indication. With a buffer-and-forward pattern, the dropped frame
triggers subscription cancellation, which propagates an error to the caller.

### The Strongest Argument For It

The "fix the ownership model" approach requires modifying `package:http2`'s
internal sink lifecycle, which is upstream code this fork does not control.
The transport sink is owned by the HTTP/2 transport connection, which closes
it in response to RST_STREAM, GOAWAY, and connection errors. These close
signals come from the remote peer -- they are not a local decision that can
be deferred.

Adding a buffer controller between the outgoing subscription and the
transport sink introduces:
- Memory overhead: every outgoing message is buffered through an extra
  StreamController
- Latency: an additional microtask hop per message
- Complexity: the buffer controller needs its own lifecycle management
  (when to close, when to drain, backpressure)

The try/catch approach is zero-overhead in the happy path (try/catch with no
exception is free in Dart), handles the edge case correctly (log + continue
is the right behavior when the remote peer has already disconnected), and
is locally reviewable (each guard is self-contained at its use site).

The "silent drop" concern is valid but not actionable: when the transport
sink is closed because the remote peer sent RST_STREAM, the correct
behavior IS to drop remaining outgoing data. The peer has already said "I
don't want this data." Propagating an error to the caller would trigger
retry logic for an RPC that the client already cancelled.

### Verdict: Right call for a fork; wrong call for upstream.

In the context of a fork that cannot modify `package:http2`, try/catch
guards are the correct and least-invasive fix. They prevent server crashes
in production with zero performance overhead.

In an ideal world, `package:http2` would expose a "sink closed" signal
before the sink throws on `add()`, allowing consumers to check state before
writing. The upstream package should provide `outgoingMessages.isClosed` or
equivalent. This fork should document the upstream gap and consider filing
an issue (on the http2 package, not grpc-dart upstream) if one does not
exist.

The silent drop behavior should be documented: when these log messages
appear, it means the remote peer disconnected or cancelled. Operators
should not treat these as errors requiring action.

---

## Challenge 6: Hardcoded 5-Second Timeouts

### The Decision

The value `Duration(seconds: 5)` appears at 7 locations in the production
code:

1. `server.dart:284` - incoming subscription cancel timeout
2. `server.dart:315` - handler response cancel timeout
3. `server.dart:416` - connection finish deadline
4. `named_pipe_server.dart:216` - stop port bootstrap timeout
5. `named_pipe_server.dart:392` - isolate exit confirmation timeout
6. `named_pipe_server.dart:436` - deferred pipe close timeout
7. `named_pipe_transport.dart:346` - client deferred pipe close timeout

Additionally, `server.dart:371` has a hardcoded `Duration(seconds: 2)` for
the terminate sub-deadline.

### The Strongest Argument Against It

**Hardcoded timeouts are a deployment anti-pattern.**

Different environments have radically different shutdown requirements:

- **Kubernetes with a 30-second SIGTERM grace period**: The 5+2=7 second
  total shutdown time is fine, leaving 23 seconds of margin.
- **AWS Lambda with a 3-second timeout**: The 5-second `finish()` deadline
  alone exceeds the entire execution budget. The server never gets to
  `terminate()`.
- **High-throughput streaming with 10,000 concurrent RPCs**: Each handler's
  async* generator needs event loop turns to process cancel. 5 seconds may
  not be enough for 10,000 generators to wind down. The timeout fires,
  `forceTerminate` kills the connection, and generators leak.
- **Low-latency edge services**: 5 seconds is an eternity. The service
  should be down in 200ms.
- **CI environments**: Windows CI runners are notoriously slow. The
  MEMORY.md documents that `Future.delayed(Duration(milliseconds: N))` for
  N>0 is quantized to 15.6ms on Windows. Timer callbacks fire 15.6ms late.
  Under heavy CI load, 5 seconds of wall time may only deliver 3 seconds
  of useful event loop processing.

The `Server` class already accepts a `ServerKeepAliveOptions` for keepalive
configuration. A `ShutdownOptions` or `shutdownTimeout` parameter on
`Server.shutdown()` would be consistent with the existing API pattern:

```dart
Future<void> shutdown({
  Duration finishTimeout = const Duration(seconds: 5),
  Duration terminateTimeout = const Duration(seconds: 2),
}) async { ... }
```

### The Strongest Argument For It

Configurability has a cost:

1. **Testing surface**: Every configurable timeout needs test coverage at
   minimum, maximum, and edge values. That is 3+ tests per timeout, times
   7 timeout sites = 21+ new tests.

2. **User confusion**: Exposing 7 timeout knobs invites misconfiguration.
   Setting `finishTimeout: Duration.zero` would skip the graceful path
   entirely, causing abrupt disconnections. Setting it to 60 seconds could
   stall shutdown for a minute. Every knob needs validation, documentation,
   and sensible defaults.

3. **The 5-second value is not arbitrary**: It is the gRPC default grace
   period used by gRPC-Go, gRPC-Java, and gRPC-C++. Using a different
   default would be surprising to gRPC users who expect standard behavior.

4. **The timeouts are all SAFETY NETS, not expected paths**: The
   5-second `finish()` deadline only fires if `connection.finish()` hangs
   (a bug in `package:http2`). The 5-second handler cancel timeout only
   fires if an async* generator ignores cancel signals (a user code bug).
   In normal operation, all of these complete in milliseconds. Making them
   configurable implies they are user-facing parameters, when they are
   actually defensive timeouts against upstream bugs.

5. **YAGNI**: No user of this fork has requested configurable shutdown
   timeouts. Adding the configuration now adds complexity without a known
   consumer.

### Verdict: Right call for now, with a minor improvement.

The hardcoded 5-second timeouts are appropriate for a fork that targets a
specific deployment environment (Pieces.app desktop and server). The gRPC
standard 5-second grace period is well-established and sufficient for the
fork's use case.

However, the total shutdown time budget should be documented. Currently, a
worst-case shutdown takes:
- 5s (Step 1: subscription cancel)
- 0s (Step 1.5: synchronous controller close)
- 5s (Step 2: handler response cancel)
- 0s (Step 3: yield)
- 5s (Step 4: connection finish) + 2s (terminate fallback)
- Total: up to 17 seconds for a single shutdown attempt

For named pipe servers, add:
- 5s (isolate exit confirmation)
- Total: up to 22 seconds

These stages are partially parallel (`Future.wait`), so the real-world worst
case is closer to 12-15 seconds. But this should be documented in the class
comment so that deployment environments can set their SIGTERM grace period
accordingly. A single `static const` for the grace period (rather than 7
independent literals) would also make future changes easier:

```dart
/// Maximum time for graceful shutdown before forcing termination.
static const _shutdownGracePeriod = Duration(seconds: 5);
```

This does not add configurability but eliminates magic numbers and makes the
relationship between the timeouts explicit.

---

## Summary Table

| # | Decision | Verdict | Risk Level |
|---|----------|---------|------------|
| 1 | Completer+Timer vs .timeout() | Correct, but documentation cites wrong reason | Low |
| 2 | 4-step shutdown sequence | Correct for production gRPC | Low |
| 3 | Two-isolate named pipe architecture | Over-engineered given PIPE_NOWAIT | Medium (technical debt) |
| 4 | PIPE_NOWAIT 1ms polling | Acceptable; 15.6ms reality underdocumented | Low |
| 5 | try/catch on every sink callback | Correct for fork; documents upstream gap | Low |
| 6 | Hardcoded 5-second timeouts | Correct for current scope; needs budget docs | Low |

## Cross-Cutting Concern: Inconsistency in Timeout Strategy

The most significant finding across all six challenges is the **inconsistent
application of the Completer+Timer pattern**. The PR explicitly documents
why `.timeout()` is unreliable (server.dart line 334-337), then uses
`.timeout()` in three places:

1. `server.dart:284` - Step 1 subscription cancel timeout
2. `server.dart:314` - Step 2 handler response cancel timeout
3. `server.dart:371` - terminate() sub-deadline inside forceTerminate()

If the threat model (event loop saturation) is real, all three are
vulnerable. If the threat model only applies after Step 1 has been skipped
(because the incoming data flood was not stopped), then Step 1 itself cannot
use `.timeout()` because it IS the step that stops the flood.

The PR should either:
(a) Apply Completer+Timer consistently to all timeout sites, or
(b) Correct the documentation to explain the actual reason (`.timeout()`
    suppresses `onTimeout` when the future errors, not event loop
    saturation) and acknowledge that `.timeout()` is acceptable for
    Steps 1-2 where the timeout is a best-effort bound, not a hard deadline.

Option (b) is the recommended path. Steps 1 and 2 are pre-cleanup whose
timeouts are "nice to have" -- if they time out, shutdown continues
regardless. Step 4 is the critical deadline where the Completer+Timer
pattern's stronger guarantee matters.
