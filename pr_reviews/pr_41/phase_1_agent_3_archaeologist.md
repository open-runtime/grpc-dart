# Phase 1: Archaeologist — Commit History Analysis of PR #41

**Branch:** fix/named-pipe-race-condition -> main
**Total commits:** 73 (2026-02-23 through 2026-03-03)
**Commit type breakdown:** fix (38), fix(test) (15), test (7), ci (4), chore (4), refactor (3), fix(ci) (1), fix(triage) (1)

---

## Development Timeline Overview

| Date | Commits | Phase |
|------|---------|-------|
| 2026-02-23 | 8 | Foundation + Wave hardening |
| 2026-02-24 | 42 | Core discoveries + massive expansion |
| 2026-02-25 | 4 | CI stabilization (transport, ping races) |
| 2026-03-02 | 8 | March regression wave |
| 2026-03-03 | 11 | Final isolate termination campaign |

---

## Phase 1: Initial Problem Statement and Foundation (Feb 23, commits 1-8)

**Commits:** `eaa8af0` through `1223322`

The PR begins with a well-understood root cause: a race between `NamedPipeServer.serve()` returning and the accept loop isolate calling `CreateNamedPipe()`. Clients racing the isolate startup hit `ERROR_FILE_NOT_FOUND`, silently hanging for the full 20-minute CI process timeout.

**`eaa8af0`** — The founding fix introduces three layered defenses: (1) server readiness signaling via `_ServerReady` message, (2) dummy client unblock for `ConnectNamedPipe`, (3) per-test 30-second timeouts to fail fast. This is the only commit that arrives with a complete mental model of the problem.

**`c757fb7`** (Wave 1) — Within an hour, a second wave of findings is applied: `ERROR_PIPE_BUSY` retry with exponential backoff, a double-close handle bug (`_pipeHandle` assigned before `SetNamedPipeHandleState` could fail), CPU-wasting spin loops using `Duration.zero` instead of 1ms delays, and a 13-test stress suite. The stress test suite is the first evidence that the initial fix was not sufficient.

**`e284fe8`** (Wave 2) — Allocator mismatch: `toNativeUtf16()` defaults to `malloc` but was being freed with `calloc.free()`. Zero-length write guard (undefined behavior from `calloc<Uint8>(0)`). Shutdown ordering bug where the receive port closed before the isolate could send its final message.

**`573d954`** (Wave 3) — Partial write data corruption: `WriteFile` could succeed with fewer bytes than requested, silently corrupting HTTP/2 frames under buffer pressure. Both server and client write paths now loop until all bytes are sent. Outgoing `StreamController` leak: `_handleNewConnection` never closed the controller on pipe read close.

**`34a44a6`** — Refactor: shared pipe I/O extracted to `lib/src/shared/named_pipe_io.dart`. This is the only purely structural commit before the architecture pivot.

**`1223322`** — Copyright header cleanup (Wave 4), no logic changes.

**Key pattern:** Three architectural bugs are found within the first 8 commits by inspection alone, before any CI run could validate the fix. This suggests the initial implementation was written quickly for proof-of-concept and the hardening was immediate second-pass review.

---

## Phase 2: Architecture Pivot — Blocking FFI Discovery (Feb 23, commits 9-10)

**Commits:** `70e6c3b`, `5597a8b`

This is the first true turning point. The stress tests written in Wave 1 began actually running, and the result was not test failures but complete deadlocks. The root cause: `ReadFile` is a synchronous blocking FFI call. Calling it in `Future.microtask` does not yield to the event loop — it blocks the entire Dart isolate thread. The client's `_readLoop` froze waiting for server data; the server waited for the HTTP/2 connection preface that could never be sent.

**`70e6c3b`** — Replaces blocking `ReadFile` with `PeekNamedPipe` polling. When no data is available, yield via `Future.delayed(1ms)`. `ReadFile` is called only when data presence is confirmed, so it returns immediately.

**`5597a8b`** — Architecture is restructured: the server isolate's accept loop is limited to accepting connections and passing raw Win32 handles (integers) to the main isolate. All pipe I/O (`_ServerPipeStream`) moves to the main isolate to keep the HTTP/2 event loop responsive. This eliminates `_spawnConnectionHandler`, `_startPipeReader`, `_writeToPipe`, `_PipeData`, `_PipeClosed`, `_SetResponsePort`. The `_PipeConnection(SendPort)` message becomes `_PipeHandle(int handle)`.

**Causation chain exposed:** Wave 1 stress tests revealed that no data ever transferred in the RPC-based tests — all 24 timed out. The diagnosis traced back to the fundamental misunderstanding that FFI calls cooperate with Dart's async scheduler.

---

## Phase 3: Shutdown Correctness Under the New Architecture (Feb 24, commits 11-30)

**Commits:** `036c67f` through `c0c6b39`

The architecture pivot unlocked new failure modes concentrated in shutdown paths. This phase represents the highest commit density (42 commits in a single day) and the broadest surface area: named pipe shutdown, HTTP/2 transport guards, server handler lifecycle, UDS test breakage, and CI infrastructure.

**`036c67f`** — `addStream()` race during `_ServerPipeStream.close()`: the HTTP/2 transport pipes frames via `addStream()` into the outgoing `StreamController`. Calling `close()` while `addStream()` is active throws `"Cannot add event while adding a stream"`. Fix: `try-catch` around `_outgoingController.close()`.

**`7f65012`** — Accept loop yield point + shutdown ordering: without an `await Future.delayed(Duration.zero)` after each `ConnectNamedPipe` iteration, `Isolate.kill()` has no event-loop checkpoint to take effect. The test process hangs indefinitely. Ordering fix: `Isolate.kill(beforeNextEvent)` must be queued before the dummy client unblocks the accept loop.

**`8cfa9c1`** — Outgoing subscription never cancelled: `_outgoingController.stream.listen()` kept the event loop alive after `close()`. The cascade: cancel listener -> `addStream()` loses subscriber -> `addStream()` future completes -> controller unlocks -> `close()` succeeds -> process exits. Applied to both `_NamedPipeStream` (client) and `_ServerPipeStream` (server). **Also** fixes byte truncation in adversarial tests: `echo(777)` becomes `echo(99)` because the echo service serializes `int` as a single byte.

**`4c722ac`** — `FlushFileBuffers` blocked during shutdown for 20 minutes: the synchronous FFI call blocks until the remote end reads all pending pipe data. During server shutdown, the client may not be reading, causing indefinite hang. Fix: remove `FlushFileBuffers` entirely.

**`87ec00e`** — Removing `FlushFileBuffers` exposed a new problem: `DisconnectNamedPipe` discards unread pipe buffer data, breaking high-throughput tests (expected 1000 items, got 232). Fix: introduce `{bool force}` parameter — `force=false` (normal close) calls only `CloseHandle` preserving buffered data; `force=true` (shutdown) calls `DisconnectNamedPipe` for fast cleanup.

**`220d325`** — `Stream.fromIterable` vs `StreamController` audit: `Stream.fromIterable` creates a synchronous source that can produce all items before the HTTP/2 flow-control window opens, deadlocking under UDS and named pipe transports. Comprehensive audit replaces all instances in transport tests.

**`c8198c6`** — UDS variants with permanent deadlocks are skipped (`skip: 'UDS deadlock'`). This is a notable deviation from the CLAUDE.md rule requiring skip metadata with tracking issues and expiry dates — but the commit message indicates these are permanent, not temporary.

**`2248981`** — Large consolidated fix: RST_STREAM propagation (yield between `handler.cancel()` and `connection.finish()` to flush frames before GOAWAY closes the socket), transport sink guards (`try-catch` on `add/addError/close` callbacks), server keepalive inverted comparison fix, `call.dart` request serialization pipeline guards, `http2_connection.dart` pending dispatch re-queue fix.

**`47206a1`, `8b0f111`** — Pure formatting refactors. The fact that two formatting commits appear in the middle of a critical fix wave suggests formatting was applied as a cleanup sweep between logical phases.

**`b292760`** — Governance: `triage.toml` updated to prevent `gh` commands resolving to upstream `grpc/grpc-dart` repository in fork context. Unrelated to the named pipe work but merged into the same branch.

---

## Phase 4: HTTP/2 and gRPC Core Transport Hardening (Feb 24-25, commits 31-50)

**Commits:** `9a66d18` through `610158b`

The named pipe work exposed analogous races in the shared HTTP/2 infrastructure. This phase extends fixes from the pipe layer to the core transport.

**`630565d`** — `await` response subscription cancellation during shutdown (was fire-and-forget).

**`9a66d18`** — Test matchers narrowed from `isA<Exception>()` / `isA<Error>()` to specific transport types (`GrpcError`, `HttpException`). This directly enforces CLAUDE.md Rule 3 (never weaken assertions) in reverse: tighten what was previously too broad.

**`df25c08`** — Named pipe error handling improvements: `ERROR_NO_DATA` retry loops, `WaitNamedPipe` FFI binding, logged close errors.

**`f750aff`** — `onMetadataException` test timeout increase. This is the only instance where a timeout is increased as a fix rather than as a capitulation — the test was slow because `_streamTerminated` flag race in `handler.dart` prevented the error from propagating promptly.

**`6180da9`** — 20+ adversarial tests added: compression, large payloads, mixed RPC shutdown, keepalive flood overlap. These tests serve as regression anchors for the entire Phase 3 fix set.

**`610158b`** — Three CI-observed races fixed:
1. Ping callback TOCTOU: `transport.isOpen` returns true but GOAWAY arrives before `transport.ping()` executes, throwing from a Timer callback as an unhandled Zone error.
2. Dispatch loop self-destruct: N pending calls times yield in dispatch loop exceeds `connectionTimeout`, causing `_refreshConnectionIfUnhealthy()` to abandon a fresh connection mid-dispatch via `socket.destroy()`. Fix: reset `_connectionLifeTimer` after each yield.
3. `connection.finish()` indefinite hang: if the client has not sent `END_STREAM`, `finish()` blocks forever. Fix: try `finish()` with 5-second grace period, then `terminate()`.

**CLAUDE.md timing rule violations found and fixed:** Rule 4 (never treat timeout as success) was violated by the original `finish()` call that blocked indefinitely. The fix introduces bounded waiting with explicit fallback — which is the rule-compliant pattern.

---

## Phase 5: March Regression Wave — Tests Expose Production Bugs (Mar 2, commits 51-58)

**Commits:** `d8a3b3d` through `8173116`

After a week gap, CI results from the 6-platform matrix reveal new failures. The March commits cluster around two distinct chains: named pipe isolate survival and keepalive stream leaks.

**`e0767c8`** — Windows CI hang: `Isolate.kill(beforeNextEvent)` cannot interrupt the accept loop mid-event if the timer callback has started executing (CreateNamedPipe -> ConnectNamedPipe). Changed to `Isolate.immediate` which fires at VM safepoints. Also adds retry logic to `_connectDummyClient`.

**`6bdc751`** — Dummy client approach upgraded: 3 retries with 1ms delays (~47ms window) proved insufficient on slow CI. Now uses `Isolate.addOnExitListener` for definitive termination confirmation, increases to 10 retries with 10ms delays (~156ms window), waits up to 200ms for exit confirmation per attempt.

**`cd5fa42`** — Converts handler-count and RST_STREAM tests from `serverStream` (self-completing) to bidi stream controllers (hold handlers alive until explicitly released). This eliminates the handler-drain race where `serverStream` handlers completed and were removed asynchronously via `.then()` before `waitForHandlers()` could observe peak count.

**`7ef7e2b`** — Production consolidation: parallel subscription cancel with 5-second timeout, `Future.wait` with `eagerError:false` on handler cancel, `logGrpcEvent` replaces `dart:developer log()`, `ERROR_NO_DATA` retry loops, `WaitNamedPipe` FFI binding, keepalive comparison fix (`server_keepalive.dart`).

**`0200ba6`** — Reverts the per-call `_connectionLifeTimer` reset from `610158b`. The reset caused a regression: holding the timer alive on every dispatch call prevented the natural refresh cycle. This is the only explicit revert in the PR, demonstrating the dispatch timer fix was wrong despite passing initial tests.

---

## Phase 6: Final Isolate Termination Campaign (Mar 3, commits 59-73)

**Commits:** `7e9d682` through `faada1a`

The isolate termination problem proves to be the hardest problem in the PR. Seven commits in a single day attack different aspects of the same root cause: `ConnectNamedPipe` is a synchronous FFI call that cannot be interrupted by any Dart-level mechanism.

**`7e9d682`** — Root cause of 30-minute VM hangs discovered: `onDataReceivedController` (a `StreamController<void>` in `serveConnection()`) was never closed during shutdown. Cancelling the incoming subscription does not fire `onDone`/`onError`, leaving the stream listener permanently pending, keeping the VM alive.

**`6da5217`** — Cooperative stop signal: adds `shouldStop` flag communicated via `SendPort/ReceivePort` bootstrap. After dummy client unblocks `ConnectNamedPipe`, the loop checks `shouldStop` and exits instead of re-entering the blocking FFI call.

**`a0cb945`** — Double yield: the single `await Future.delayed(Duration.zero)` can fire before the pending stop signal (ReceivePort event) from the main isolate. A second yield with an explicit `shouldStop` check between them guarantees the stop message is processed before the next blocking FFI call. Stopwatch-based 10-second deadline replaces fixed 10-attempt loop.

**`7f69465`** — `Isolate.exit()` in accept loop `finally` block: unconditionally terminates the isolate when the loop exits normally, regardless of open ReceivePorts or pending Timers. 20-second deadline and second `Isolate.kill()` after deadline.

**`89da018`** — Final architectural solution: replace blocking `ConnectNamedPipe` with `PIPE_NOWAIT` polling. After `CreateNamedPipe`, switch to non-blocking mode via `SetNamedPipeHandleState`. Poll `ConnectNamedPipe` in a loop (returns immediately with `ERROR_PIPE_LISTENING` when no client connected). Yield every 1ms between polls. After connection, switch back to `PIPE_WAIT`. This eliminates the need for the fragile dummy client workaround entirely. **This is the cleanest architectural solution in the PR** — converting from interrupt-based shutdown to cooperative polling.

**`d123219`**, **`faada1a`** — Final cleanup: `channel.terminate()` in teardown, `addTearDown` for NamedPipeServer loop tests.

---

## Bug Category Analysis

### Category 1: Synchronous FFI Blocking the Event Loop
Commits: `70e6c3b`, `4c722ac`, `89da018`

All three involve Win32 calls (`ReadFile`, `FlushFileBuffers`, `ConnectNamedPipe`) called synchronously in a Dart isolate, freezing the event loop. The final solution for `ConnectNamedPipe` (non-blocking PIPE_NOWAIT polling) is the most elegant because it makes the state machine cooperative rather than interrupt-driven.

### Category 2: Isolate/Stream Lifecycle Resource Leaks
Commits: `573d954`, `8cfa9c1`, `7e9d682`

Controllers, subscriptions, and isolates that were never explicitly closed or cancelled kept the Dart VM alive indefinitely. Each fix required tracing a specific ownership boundary: who owns the subscription, who closes the controller, who confirms isolate death.

### Category 3: Shutdown Ordering and Race Conditions
Commits: `5597a8b`, `7f65012`, `036c67f`, `e0767c8`, `6da5217`

Shutdown steps in the wrong order created races: port closed before isolate could send its final message; `Isolate.kill` queued after dummy client unblocked the accept loop; `close()` called during active `addStream()`.

### Category 4: HTTP/2 Transport Sink Guards
Commits: `2248981`, `7ef7e2b`, `630565d`

`add`/`addError`/`close` callbacks on `StreamController`s can be called after the sink is closed if RST_STREAM or connection teardown races with in-flight data. Guards (`try-catch`, `_isClosed` checks) prevent `"Cannot add event after closing"` crashes in production.

### Category 5: Timer and Dispatch Loop Races
Commits: `610158b`, `0200ba6`, `8173116`

The connection life timer reset in `dispatchCall()` was a fix that became a regression — it prevented the natural refresh cycle. The ping TOCTOU race required a `try-catch` on a Timer callback because transport state can change between the TOCTOU check and the ping call.

### Category 6: Test Infrastructure Gaps
Commits: `220d325`, `cd5fa42`, `9a66d18`, `60ec1cd`

`Stream.fromIterable` as a test producer creates synchronous event floods that bypass HTTP/2 flow control, deadlocking under real transports. Self-completing stream handlers (`serverStream`) cannot reliably signal peak handler count. Both are test design problems that masked production behavior.

---

## Key Architectural Decisions

1. **Two-isolate architecture (`5597a8b`):** Accept loop stays in isolate; all I/O moves to main isolate. This was not planned upfront — it was forced by the discovery that blocking FFI in any path freezes HTTP/2.

2. **`force` parameter on `close()` (`87ec00e`):** Differentiating graceful close (preserve buffered data) from forced shutdown (fast cleanup) reflects the fundamental tension between data integrity and shutdown speed in streaming protocols.

3. **PIPE_NOWAIT polling (`89da018`):** Converting from interrupt-based (dummy client + kill signal) to cooperative polling (isolate checks stop flag every 1ms) is the principled solution. The previous seven commits represent seven attempts to make interrupt-based shutdown reliable — the polling approach sidesteps the problem entirely.

4. **Bidi controllers as test synchronization (`cd5fa42`):** Using stream controllers to gate handler lifetime (instead of relying on server-side completion) converts a probabilistic assertion into a deterministic one. This directly enforces CLAUDE.md Rule 1 (no `Future.delayed` for synchronization).

---

## CLAUDE.md Timing Rule Compliance Assessment

The PR's test evolution generally moves toward compliance with the 10 timing rules:

- **Rule 1 (no arbitrary delays):** Early commits use `Future.delayed(1ms)` for polling (acceptable — it is a concrete predicate, not synchronization). Later commits replace `serverStream`-based assertions with `Completer`-based gating.
- **Rule 3 (no assertion weakening):** `9a66d18` explicitly tightens broad `Exception` matchers to specific types. `a0cb945` reduces `minCount` from 20 to 10 for arm64 CI — this is documented as infrastructure limitation, not assertion weakening.
- **Rule 4 (timeout is not success):** `610158b` introduces bounded `finish()` with explicit fallback, converting an indefinite hang into a timed grace period with logged escalation.
- **Rule 6 (await lifecycle):** The March wave enforces explicit `shutdown()` await, controller close, and isolate exit confirmation rather than fire-and-forget teardown.
- **Rule 9 (stability proof):** The CI matrix (6 platforms, multiple runners) provides empirical evidence across runs.
