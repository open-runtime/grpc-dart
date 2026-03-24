// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba.,
// Pieces.app. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Adversarial concurrency tests for the Windows named-pipe gRPC transport.
///
/// These tests target specific race conditions, resource leaks, and crash
/// vectors that the happy-path stress tests in `named_pipe_stress_test.dart`
/// do NOT cover. Each test is designed to be maximally adversarial: it
/// deliberately creates the conditions under which the transport is most
/// likely to deadlock, double-free handles, leak isolates, or corrupt
/// streams.
///
/// Every test is Windows-only (via [testNamedPipe]) and uses a unique pipe
/// name derived from the test description to prevent cross-test interference.
@TestOn('vm')
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/http2_connection.dart' show Http2ClientConnection;
import 'package:grpc/src/http2/transport.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

/// Connector that returns a pre-built transport (used to verify post-shutdown
/// transport is not usable).
class _SingleTransportConnector implements ClientTransportConnector {
  final ClientTransportConnection transport;
  final Completer<void> _done = Completer<void>();

  _SingleTransportConnector(this.transport);

  @override
  Future<ClientTransportConnection> connect() async => transport;

  @override
  Future<void> get done => _done.future;

  @override
  void shutdown() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  String get authority => 'localhost';
}

/// Asserts that [transport] is NOT usable for RPCs after a shutdown race.
///
/// Pre-fix post-guard race: connect() could return a transport after
/// shutdown() ran; without proper cleanup that transport would appear live
/// and RPCs would succeed. This helper attempts multiple RPCs and fails if
/// any succeeds.
///
/// [rpcAttempts]: number of unary RPC attempts (catches intermittent live
/// behavior). [timeout]: per-RPC timeout.
Future<void> _assertTransportNotUsableForRpc(
  ClientTransportConnection transport, {
  int rpcAttempts = 3,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final wrapper = _SingleTransportConnector(transport);
  final connection = Http2ClientConnection.fromClientTransportConnector(
    wrapper,
    const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  final channel = TestClientChannel(connection);
  final client = EchoClient(channel);

  // CRITICAL: terminate() MUST run even if fail() throws TestFailure.
  // Without try/finally, a successful RPC triggers fail() which skips
  // terminate(), leaking reconnect Timers that keep the Dart VM alive
  // (observed as 44-minute CI hangs on Windows x64 between test files).
  try {
    for (var i = 0; i < rpcAttempts; i++) {
      try {
        final value = await client.echo(100 + i).timeout(timeout, onTimeout: () => throw TimeoutException('RPC hung'));
        // If we reach here without throwing, the RPC completed — fail.
        fail(
          'Post-shutdown transport must not be usable; '
          'echo(${100 + i}) returned $value (attempt ${i + 1}/$rpcAttempts)',
        );
      } on GrpcError {
        // Expected: transport correctly reports failure.
      } on TimeoutException {
        // Also acceptable: transport may hang rather than fail cleanly.
      }
    }
  } finally {
    // CRITICAL: terminate the channel to break any reconnect loop.
    // Without this, orphaned ClientCalls (whose .timeout() fired but whose
    // underlying call was never cancelled) stay in _pendingCalls, causing
    // _abandonConnection() → reconnect Timer → infinite loop with exponential
    // backoff. Those Timers keep the Dart VM event loop alive, preventing
    // `dart test` from exiting.
    await channel.terminate();
  }
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  // ===========================================================================
  // 1. Shutdown-During-Connect Races
  // ===========================================================================

  group('Shutdown-During-Connect Races', () {
    // -------------------------------------------------------------------------
    // Test 0: Raw connector connect() racing with shutdown()
    // -------------------------------------------------------------------------
    // RACE TARGETED: NamedPipeTransportConnector.connect() is in progress
    // (CreateFile, SetNamedPipeHandleState, stream setup) when shutdown() is
    // called. shutdown() calls _disposeCurrentPipeResources() which closes
    // handles and completes _doneCompleter. A connect() that wins the race
    // may return a transport; one that loses may throw or return a transport
    // that is immediately invalid. Either way: no hang, no crash, done
    // completes.
    //
    // EXPECTED: All connect/shutdown futures settle within timeout. No
    // deadlock. connector.done completes.
    //
    // REGRESSION: If connect() returns a transport after shutdown without
    // cleanup, that transport must NOT be usable for RPCs. We assert that
    // any returned transport fails when used (not a live connection).
    testNamedPipe(
      'connector connect racing with shutdown settles without hang',
      timeout: const Timeout(Duration(seconds: 30)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        final connector = NamedPipeTransportConnector(pipeName);
        addTearDown(() => connector.shutdown());

        // Fire connect() and shutdown() concurrently. Multiple connect
        // attempts increase race surface (post-guard race: more in-flight
        // connects increase chance of returning a transport before shutdown).
        final connectFutures = <Future<Object?>>[];
        for (var i = 0; i < 8; i++) {
          connectFutures.add(
            connector.connect().then<Object?>(
              (ClientTransportConnection t) => t,
              onError: (Object e, StackTrace _) => e,
            ),
          );
        }
        // shutdown() is synchronous; call it immediately to race with connect.
        connector.shutdown();

        // All connect futures and done must settle within timeout — no hang.
        final connectResults = await Future.wait(
          connectFutures,
        ).timeout(const Duration(seconds: 10), onTimeout: () => fail('connect() futures did not settle within 10s'));
        await connector.done.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('connector.done did not complete after shutdown'),
        );

        // connect() either returned a transport or threw. Either is valid.
        // Typed assertions: success yields ClientTransportConnection; failure
        // yields Exception or Error (e.g. GrpcError, NamedPipeException).
        for (final r in connectResults) {
          expect(
            r,
            anyOf(
              isA<ClientTransportConnection>(),
              isA<NamedPipeException>(),
              isA<TimeoutException>(),
              isA<StateError>(),
            ),
            reason:
                'each connect() must return ClientTransportConnection or '
                'throw Exception/Error',
          );
        }

        // CRITICAL: Any transport returned from the race must NOT be usable.
        // Post-guard race: connect() could return a transport after shutdown()
        // ran; without proper cleanup that transport would appear live and RPCs
        // would succeed. We assert every returned transport fails when used,
        // with multiple RPC attempts to catch intermittent live behavior.
        for (final r in connectResults) {
          if (r is! ClientTransportConnection) continue;
          await _assertTransportNotUsableForRpc(r);
        }

        await server.shutdown();
      },
    );

    // -------------------------------------------------------------------------
    // Test 0b: Post-shutdown transport must not be usable for RPCs
    // -------------------------------------------------------------------------
    // REGRESSION TARGETED: If connect() returns a ClientTransportConnection
    // after shutdown() has run (race where connect wins but resources are
    // already disposed), that transport must NOT allow successful RPCs.
    // Without proper cleanup, the transport could appear "live" and succeed,
    // leading to use-after-close or orphaned connections.
    //
    // ASSERTION: Attempt RPC on any transport returned from connect/shutdown
    // race. RPC must fail (GrpcError) or hang (timeout), never succeed.
    testNamedPipe(
      'post-shutdown connect race: returned transport is not usable for RPC',
      timeout: const Timeout(Duration(seconds: 30)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        final connector = NamedPipeTransportConnector(pipeName);
        addTearDown(() => connector.shutdown());

        // Single connect + immediate shutdown to maximize race window.
        final connectFuture = connector.connect().then<Object?>((t) => t, onError: (e, _) => e);
        connector.shutdown();

        final result = await connectFuture.timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('connect() did not settle within 10s'),
        );
        await connector.done.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('connector.done did not complete after shutdown'),
        );

        // When connect() threw, onError returned the exception — no transport.
        if (result is! ClientTransportConnection) {
          await server.shutdown();
          return;
        }

        // Transport returned: must NOT be usable. Multiple RPC attempts
        // catch intermittent live behavior (post-guard race regression).
        await _assertTransportNotUsableForRpc(result);

        await server.shutdown();
      },
    );

    // -------------------------------------------------------------------------
    // Test 0c: Connect-then-shutdown ordered (deterministic transport test)
    // -------------------------------------------------------------------------
    // DETERMINISTIC: Connect first, await, then shutdown. Guarantees we get
    // a transport to test. Post-guard race: without proper cleanup, shutdown()
    // would not invalidate the returned transport and RPCs could succeed.
    //
    // ASSERTION: After shutdown, the transport must NOT be usable. No sleeps;
    // ordering is explicit and bounded.
    testNamedPipe(
      'connect-then-shutdown ordered: returned transport is not usable',
      timeout: const Timeout(Duration(seconds: 30)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        final connector = NamedPipeTransportConnector(pipeName);
        addTearDown(() => connector.shutdown());

        // Deterministic: connect first, then shutdown. Guarantees transport.
        final transport = await connector.connect().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('connect() did not complete within 10s'),
        );
        connector.shutdown();
        await connector.done.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('connector.done did not complete after shutdown'),
        );

        // Post-shutdown: transport must NOT be usable. Pre-fix would allow
        // successful RPC here (use-after-close).
        await _assertTransportNotUsableForRpc(transport);

        await server.shutdown();
      },
    );

    // -------------------------------------------------------------------------
    // Test 1: Server shutdown while client is mid-CreateFile handshake
    // -------------------------------------------------------------------------
    // RACE TARGETED: The client calls CreateFile() to open the pipe, then
    // calls SetNamedPipeHandleState(). Between those two Win32 calls, the
    // server calls shutdown(), kills its isolate, and closes all pipe handles.
    // The client's SetNamedPipeHandleState (or the subsequent ReadFile) then
    // operates on an invalid/closed handle.
    //
    // EXPECTED: The client RPC fails with a GrpcError (not a hang or crash).
    // Both server and client shut down cleanly.
    //
    // NOTE: On Windows CI, the client channels can deadlock waiting for a
    // connection response that will never come (the server is dead). We use
    // aggressive timeout guards on RPCs and channel cleanup to prevent the
    // test from hanging. The test succeeds if nothing crashes — the timeout
    // guards are safety nets, not assertions.
    testNamedPipe(
      'server shutdown racing client connect does not hang or crash',
      timeout: const Timeout(Duration(seconds: 90)),
      (pipeName) async {
        final sw = Stopwatch()..start();
        void log(String msg) => print('[Test1 ${sw.elapsedMilliseconds}ms] $msg');

        log('Creating server...');
        final server = NamedPipeServer.create(services: [EchoService()]);
        addTearDown(() => server.shutdown());
        log('Starting server on pipe: $pipeName');
        await server.serve(pipeName: pipeName);
        log('Server started.');

        // Start many clients connecting simultaneously. Some will be mid-
        // handshake when we kill the server.
        log('Creating 5 client channels...');
        final channels = List.generate(
          5,
          (_) => NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions()),
        );
        // Safety net: terminate all channels even if the finally block below
        // throws mid-cleanup (e.g., a single channel's terminate times out and
        // fail() aborts the loop before reaching the remaining channels).
        addTearDown(() async {
          for (final ch in channels) {
            await ch.terminate().timeout(
              const Duration(seconds: 2),
              onTimeout: () async {
                // Channel terminate hung for 2s — safety-net teardown
                // cannot block indefinitely. The channel will be GC'd.
                // Log for CI visibility (Rule 4: never treat timeout as
                // success).
                print(
                  'WARNING: channel.terminate() timed out during '
                  'addTearDown — channel will be GC\'d',
                );
              },
            );
          }
        });
        final clients = channels.map(EchoClient.new).toList();
        log('Clients created.');

        // Fire RPCs without awaiting -- they race against shutdown.
        log('Firing RPCs...');
        final rpcFutures = <Future<Object?>>[];
        for (var i = 0; i < clients.length; i++) {
          rpcFutures.add(
            settleRpc(
              clients[i].echo(i, options: CallOptions(timeout: const Duration(seconds: 3))).then<Object?>((v) => v),
            ).then((result) {
              if (result is int) {
                log('RPC $i succeeded: $result');
              } else {
                log('RPC $i failed: $result');
              }
              return result;
            }),
          );
        }
        log('All RPCs fired.');

        // Immediately shut down the server while clients are connecting.
        // Do NOT await the RPCs first -- the race IS the test.
        log('Shutting down server...');
        await server.shutdown();
        log('Server shutdown complete.');

        Object? settleFailure;
        StackTrace? settleFailureStack;
        try {
          // Wait for all RPCs to settle (succeed or fail). A stuck client is a
          // regression and must fail this test, but cleanup must still run.
          log('Waiting for RPCs to settle (12s timeout)...');
          final results = await Future.wait(rpcFutures).timeout(
            const Duration(seconds: 12),
            onTimeout: () => throw TimeoutException('RPCs did not settle within 12s'),
          );
          log('RPCs settled (${results.length}/${clients.length}).');
        } catch (e, st) {
          settleFailure = e;
          settleFailureStack = st;
          log('RPC settle phase failed: $e');
        } finally {
          // Clean up channels. Dead channels may hang on shutdown() because
          // it waits for in-flight RPCs to complete (which never happens when
          // the server is dead). Use terminate() as a fallback — it force-
          // closes the connection without waiting for RPCs.
          //
          // CRITICAL: If channels aren't cleaned up, their underlying isolates
          // (blocked on ConnectNamedPipe/ReadFile FFI) keep the dart test
          // process alive indefinitely, blocking all subsequent test files.
          for (var i = 0; i < channels.length; i++) {
            log('Shutting down channel $i...');
            await channels[i].shutdown().timeout(
              const Duration(seconds: 3),
              onTimeout: () async {
                log('Channel $i shutdown timed out — force terminating.');
                await channels[i].terminate().timeout(
                  const Duration(seconds: 2),
                  onTimeout: () => fail('Channel $i terminate timed out during cleanup'),
                );
              },
            );
            log('Channel $i done.');
          }
          log('Test complete. Total time: ${sw.elapsedMilliseconds}ms');
        }

        if (settleFailure != null) {
          Error.throwWithStackTrace(settleFailure, settleFailureStack!);
        }
      },
    );

    // -------------------------------------------------------------------------
    // Test 2: Concurrent connect + shutdown on the SAME channel
    // -------------------------------------------------------------------------
    // RACE TARGETED: A single channel's first RPC triggers connect(). If
    // channel.shutdown() is called before connect() returns, the transport
    // connector's _pipeHandle may be null when shutdown() tries to
    // FlushFileBuffers + CloseHandle. Or the connect() may complete and
    // assign _pipeHandle AFTER shutdown() already checked it.
    //
    // EXPECTED: No hang, no double-close, no unhandled exception.
    testNamedPipe('channel shutdown concurrent with first RPC connect', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel.terminate());
      final client = EchoClient(channel);

      // Fire the RPC (triggers lazy connect) and immediately shut down.
      final rpcFuture = settleRpc(client.echo(42));

      // Race: shut down while the RPC is in-flight.
      await channel.shutdown();

      // The RPC either succeeded or failed gracefully.
      final result = await rpcFuture;
      expect(
        result,
        anyOf(equals(42), isA<GrpcError>(), isA<NamedPipeException>(), isA<TimeoutException>(), isA<StateError>()),
      );

      await server.shutdown();
    });
  });

  // ===========================================================================
  // 2. Bidirectional Streaming Under Shutdown
  // ===========================================================================

  group('Bidirectional Streaming Under Shutdown', () {
    // -------------------------------------------------------------------------
    // Test 3: Server shutdown during active bidi stream with interleaved
    //         read/write
    // -------------------------------------------------------------------------
    // RACE TARGETED: The server's _startPipeReader is in a ReadFile loop
    // while the client is simultaneously writing via _writeToPipe. When
    // shutdown() kills the server isolate, the _PipeClosed message may
    // never arrive (isolate killed before it sends), leaving the client's
    // incoming StreamController open forever (resource leak / hang).
    //
    // EXPECTED: The bidi stream terminates (with error or short data) within
    // the test timeout. No hang.
    testNamedPipe('server shutdown during active bidi stream terminates cleanly', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel.terminate());
      final client = EchoClient(channel);

      // Create a long-lived bidi stream: the client sends 200 items with
      // small delays, keeping the stream active for ~2 seconds.
      final inputController = StreamController<int>();
      final responseStream = client.bidiStream(inputController.stream);

      // Collect responses (with error tolerance).
      final received = <int>[];
      final streamDone = Completer<void>();
      final unexpectedStreamErrors = <Object>[];
      responseStream.listen(
        received.add,
        onError: (Object error) {
          if (error is! GrpcError) {
            unexpectedStreamErrors.add(error);
          }
          if (!streamDone.isCompleted) streamDone.complete();
        },
        onDone: () {
          if (!streamDone.isCompleted) streamDone.complete();
        },
      );

      // Send a burst of data to saturate the pipe's read/write interleave.
      // Values stay ≤127 so that doubled bidi results fit in a single byte.
      for (var i = 0; i < 100; i++) {
        inputController.add(i % 128);
        // Tiny delay so writes interleave with reads on the server side.
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // Kill the server while the bidi stream is mid-flight.
      await server.shutdown();

      // The stream must terminate within a reasonable time -- not hang.
      await streamDone.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          fail('bidi stream did not terminate after server shutdown');
        },
      );
      expect(unexpectedStreamErrors, isEmpty, reason: 'Unexpected non-gRPC stream errors during shutdown race');

      // Close the client side.
      await inputController.close();
      await channel.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 4: Client-stream with server shutdown before final response
    // -------------------------------------------------------------------------
    // RACE TARGETED: The client sends a stream of values via clientStream().
    // The server accumulates them and returns a single sum. If the server is
    // killed mid-accumulation, the client is waiting on ResponseFuture.single
    // which may hang forever if the pipe's incoming controller never closes.
    //
    // EXPECTED: The client-stream RPC fails with GrpcError within the
    // timeout. No hang.
    testNamedPipe('client-stream RPC fails cleanly when server dies mid-accumulation', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel.terminate());
      final client = EchoClient(channel);

      // Create a slow client stream that sends values over ~2 seconds.
      final inputController = StreamController<int>();

      // Start the client-stream RPC (returns when server sends response).
      final resultFuture = settleRpc(client.clientStream(inputController.stream));

      // Send a few values.
      for (var i = 1; i <= 5; i++) {
        inputController.add(i);
        await Future.delayed(const Duration(milliseconds: 20));
      }

      // Kill the server before closing the client stream.
      await server.shutdown();

      // Close the input so the RPC can settle (even if the response is
      // already dead).
      await inputController.close();

      // The result must arrive (success or error) within the timeout.
      final result = await resultFuture.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          fail('clientStream RPC hung after server shutdown');
        },
      );

      // If server died, we get -1 (error). If it somehow completed, sum
      // of 1..5 = 15. Either is acceptable.
      expect(
        result,
        anyOf(equals(15), isA<GrpcError>(), isA<NamedPipeException>(), isA<TimeoutException>(), isA<StateError>()),
      );

      await channel.shutdown();
    });
  });

  // ===========================================================================
  // 3. Concurrent Shutdown + RPC
  // ===========================================================================

  group('Concurrent Shutdown + RPC', () {
    // -------------------------------------------------------------------------
    // Test 5: Server shutdown() racing with in-flight RPCs from multiple
    //         clients
    // -------------------------------------------------------------------------
    // RACE TARGETED: Multiple clients are hammering the server with RPCs.
    // shutdown() is called on the server while RPCs are being processed by
    // the server handler. The handler's serveConnection() has already
    // dispatched to _echo, but the response path goes through an outgoing
    // StreamController whose pipe handle is being closed by shutdown().
    // This can cause "Cannot add event after closing" on the server side.
    //
    // EXPECTED: All RPCs either succeed or fail with GrpcError. The server
    // shuts down without unhandled async exceptions. No hang.
    testNamedPipe('server shutdown racing 100 concurrent RPCs from 3 clients', (pipeName) async {
      // Wrap in runZonedGuarded to catch http2 FrameWriter StateErrors
      // that escape via Timer.run() when server.shutdown() closes the
      // transport while the http2 Connection still has queued DATA frames.
      final http2InternalErrors = <Object>[];
      final testDone = Completer<void>();

      runZonedGuarded(
        () async {
          try {
            final server = NamedPipeServer.create(services: [EchoService()]);
            await server.serve(pipeName: pipeName);
            addTearDown(() => server.shutdown());

            // Spin up 3 independent channels.
            final channels = List.generate(
              3,
              (_) => NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions()),
            );
            addTearDown(() async {
              for (final ch in channels) {
                await ch.terminate();
              }
            });
            final clients = channels.map(EchoClient.new).toList();

            // Warm up: ensure all 3 channels are connected.
            // On Windows arm64 CI, pipe connection setup can be slow —
            // wrap in settleRpc so a transient UNAVAILABLE during startup
            // doesn't abort the test before the actual shutdown race.
            final warmUpResults = await Future.wait([
              settleRpc(clients[0].echo(0).then<Object?>((v) => v)),
              settleRpc(clients[1].echo(0).then<Object?>((v) => v)),
              settleRpc(clients[2].echo(0).then<Object?>((v) => v)),
            ]).timeout(const Duration(seconds: 15), onTimeout: () => fail('Warm-up echoes did not settle in 15s'));
            // At least one channel must have connected for the test to be meaningful.
            // If zero channels connect after server.serve() completed, that is a
            // real bug — the server should be ready. A silent return hides failures
            // in CI.
            final warmUpSuccesses = warmUpResults.whereType<int>().length;
            if (warmUpSuccesses == 0) {
              fail(
                'All 3 warm-up channels failed to connect — server may not '
                'be ready. Warm-up results: $warmUpResults',
              );
            }

            // Fire 100 RPCs spread across all 3 clients, without awaiting.
            // Values are i & 0xFF to stay within single-byte echo encoding.
            final rpcFutures = <Future<Object?>>[];
            for (var i = 0; i < 100; i++) {
              final client = clients[i % 3];
              rpcFutures.add(settleRpc(client.echo(i & 0xFF)));
            }

            // After a tiny delay (to let some RPCs be mid-processing), shut down.
            await Future.delayed(const Duration(milliseconds: 10));
            await server.shutdown();

            // All RPCs must settle — no hangs, no unhandled exceptions.
            final settled = await Future.wait(rpcFutures).timeout(
              const Duration(seconds: 15),
              onTimeout: () {
                fail('RPCs hung after server.shutdown()');
              },
            );
            // During a shutdown race, RPCs may succeed (int), fail with a gRPC
            // transport error (UNAVAILABLE, CANCELLED), fail with a pipe-level
            // error, or time out. All are valid outcomes. The test verifies that
            // NO unexpected error types appear (no crashes, no unhandled
            // exceptions, no hangs).
            for (final result in settled) {
              expect(
                result,
                anyOf(
                  isA<int>(),
                  isA<GrpcError>(),
                  isA<NamedPipeException>(),
                  isA<TimeoutException>(),
                  isA<StateError>(),
                ),
                reason: 'Unexpected named-pipe concurrent-shutdown settlement: $result',
              );
            }

            for (final ch in channels) {
              await ch.shutdown().timeout(
                const Duration(seconds: 3),
                onTimeout: () async {
                  await ch.terminate().timeout(
                    const Duration(seconds: 2),
                    onTimeout: () => fail('Channel terminate timed out after shutdown timeout'),
                  );
                },
              );
            }

            if (!testDone.isCompleted) testDone.complete();
          } catch (e, s) {
            if (!testDone.isCompleted) {
              testDone.completeError(e, s);
            }
          }
        },
        (error, stack) {
          // Collect zone-escaping errors (http2 FrameWriter StateError).
          http2InternalErrors.add(error);
        },
      );

      await testDone.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail('test timed out in guarded zone'),
      );

      // Verify any zone-escaping errors are the known http2 FrameWriter race.
      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during concurrent shutdown. '
              'Got: $error',
        );
      }
    });

    // -------------------------------------------------------------------------
    // Test 6: Channel shutdown while server-streaming RPC is yielding
    // -------------------------------------------------------------------------
    // RACE TARGETED: The server is mid-yield in _serverStream (inside the
    // async* generator). The client calls channel.shutdown(), which triggers
    // FlushFileBuffers + CloseHandle on the pipe handle. The server's
    // _writeToPipe then writes to a closed handle, causing ERROR_BROKEN_PIPE.
    // The server must handle this without crashing or leaking.
    //
    // EXPECTED: Channel shutdown completes. Server remains healthy for
    // subsequent clients.
    testNamedPipe('channel shutdown during server-streaming RPC, server survives', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      // Client 1: Start a long server stream, then kill the channel.
      final channel1 = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel1.terminate());
      final client1 = EchoClient(channel1);

      // Request 255 items (~255ms of streaming). 255 is the maximum
      // valid single-byte value — the EchoClient serializer encodes
      // int as `[value]`, so values >255 are truncated via & 0xFF.
      //
      // Use a first-item Completer as a concrete readiness barrier
      // instead of an arbitrary delay (Rule 1: never use arbitrary
      // Future.delayed as synchronization).
      final firstItemReceived = Completer<void>();
      final responseStream = client1.serverStream(255);
      final streamFuture = settleRpc(
        responseStream.map((item) {
          if (!firstItemReceived.isCompleted) {
            firstItemReceived.complete();
          }
          return item;
        }).toList(),
      );

      // Wait for the server to actually start streaming (first item
      // arrives), proving the server is actively yielding. Timeout
      // guards against a connect failure that prevents any data.
      await firstItemReceived.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'Server stream did not emit first item within 5s — '
          'connection may have failed before streaming started',
        ),
      );

      // Kill the client channel while the server is actively streaming.
      await channel1.shutdown();
      final streamResult = await streamFuture; // Must settle, not hang.
      expect(
        streamResult,
        anyOf(
          isA<List<int>>(),
          isA<GrpcError>(),
          isA<NamedPipeException>(),
          isA<TimeoutException>(),
          isA<StateError>(),
        ),
      );

      // Client 2: Verify the server is still alive after the rude
      // disconnection.
      final channel2 = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel2.terminate());
      final client2 = EchoClient(channel2);
      // Value must be ≤255 — the echo service serializes int as a single
      // byte ([value]), so values >255 are truncated by Uint8List.
      final result = await client2.echo(99);
      expect(result, equals(99));

      await channel2.shutdown();
      await server.shutdown();
    });
  });

  // ===========================================================================
  // 4. Client Reconnect After Server Restart
  // ===========================================================================

  group('Client Reconnect After Server Restart', () {
    // -------------------------------------------------------------------------
    // Test 7: Fresh channel on same pipe name after server restart
    // -------------------------------------------------------------------------
    // RACE TARGETED: The OS may not immediately release the pipe namespace
    // entry after server shutdown. A new server trying to CreateNamedPipe on
    // the same name could get ERROR_ACCESS_DENIED or ERROR_ALREADY_EXISTS if
    // the old server's isolate cleanup is not complete. The client connecting
    // to the restarted server may hit the stale pipe instance from the old
    // server.
    //
    // EXPECTED: After a brief delay, the new server starts successfully and
    // the new client connects and completes RPCs. 8 cycles with no failures.
    testNamedPipe('8 rapid server restart cycles with fresh client each time', (pipeName) async {
      // Track all servers/channels so addTearDown can clean up leaked
      // resources if the test times out mid-cycle. Without this, a leaked
      // NamedPipeServer's ReceivePort and accept-loop Isolate keep the
      // Dart VM alive indefinitely, hanging the dart test process.
      final servers = <NamedPipeServer>[];
      final channels = <NamedPipeClientChannel>[];
      addTearDown(() async {
        // Use terminate() not shutdown() — if the test timed out,
        // shutdown() hangs waiting for RPCs that will never settle.
        for (final ch in channels) {
          try {
            await ch.terminate();
          } on GrpcError {
            // Channel already dead — expected during teardown.
          } on StateError {
            // Channel already shut down — expected during teardown.
          } on NamedPipeException {
            // Pipe handle already closed — expected during teardown.
          }
        }
        for (final s in servers) {
          try {
            await s.shutdown();
          } on GrpcError {
            // Server already dead — expected during teardown.
          } on StateError {
            // Server already shut down — expected during teardown.
          } on NamedPipeException {
            // Pipe handle already closed — expected during teardown.
          }
        }
      });

      for (var cycle = 0; cycle < 8; cycle++) {
        final server = NamedPipeServer.create(services: [EchoService()]);
        servers.add(server);
        await server.serve(pipeName: pipeName);

        final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        channels.add(channel);
        final client = EchoClient(channel);

        // Verify the cycle works. Values must be ≤255 because the echo
        // service serializes int as a single byte ([value]).
        final result = await client.echo(cycle * 25);
        expect(result, equals(cycle * 25), reason: 'cycle $cycle');

        await channel.shutdown();
        await server.shutdown();

        // Minimal delay -- we WANT to stress the OS pipe cleanup.
        // 100ms is tight enough to catch race conditions but enough
        // for the OS to reclaim the pipe name most of the time.
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ===========================================================================
  // 5. Large Payload Stress
  // ===========================================================================

  group('Large Payload Stress', () {
    // -------------------------------------------------------------------------
    // Test 8: Messages near the 65536-byte buffer boundary
    // -------------------------------------------------------------------------
    // RACE TARGETED: The pipe's read buffer (_kBufferSize) is 65536 bytes.
    // Sending a message whose serialized HTTP/2 frame is exactly at, just
    // below, or just above this boundary exercises the ReadFile partial-read
    // and WriteFile partial-write paths. If the buffer management is wrong,
    // ReadFile returns a partial read that gets reassembled incorrectly,
    // corrupting the HTTP/2 frame and causing a protocol error or hang.
    //
    // The EchoService serializes int as a single-element List<int>, so the
    // gRPC frame overhead dominates. To stress the buffer boundary we use
    // server-streaming with a large count, causing many back-to-back frames
    // that saturate the pipe buffer.
    //
    // EXPECTED: Items arrive in correct order with correct values. No data
    // corruption. No deadlock.
    //
    // Use serverStreamBytes request encoding (8-byte count+size) so the
    // request count is not truncated to a single byte.
    testNamedPipe('high-throughput server stream saturating pipe buffer', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel.terminate());
      final client = EchoClient(channel);

      // Request 1000 chunks of 64 bytes (64KB total): enough to saturate the
      // named-pipe buffer boundary while preserving deterministic integrity
      // checks on every chunk.
      final request = encodeStreamBytesRequest(1000, 64);
      final chunks = await client.serverStreamBytes(request).toList();

      expect(
        chunks.length,
        equals(1000),
        reason:
            'Expected all 1000 chunks but got ${chunks.length}. '
            'No shutdown races this stream; full delivery is required.',
      );

      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].length, equals(64), reason: 'chunk $i size');
        for (var j = 0; j < 64; j++) {
          expect(chunks[i][j], equals((i + j) & 0xFF), reason: 'chunk $i byte $j');
        }
      }

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 9: Many concurrent bidi streams saturating the pipe
    // -------------------------------------------------------------------------
    // RACE TARGETED: Multiple bidi streams on the SAME channel means
    // multiple HTTP/2 streams multiplexed over a single pipe. The pipe's
    // ReadFile/WriteFile calls are serialized per-direction, but the HTTP/2
    // framing layer interleaves frames from different streams. If the frame
    // reassembly or stream demux is wrong, data leaks between streams.
    //
    // EXPECTED: Each bidi stream independently echoes its values doubled.
    // No cross-stream contamination.
    testNamedPipe('5 concurrent bidi streams on one channel, no cross-stream leaks', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel.terminate());
      final client = EchoClient(channel);

      // Launch 5 bidi streams in parallel, each sending 100 items.
      final streamFutures = <Future<List<int>>>[];
      final controllers = <StreamController<int>>[];

      for (var s = 0; s < 5; s++) {
        final controller = StreamController<int>();
        controllers.add(controller);

        final responseFuture = client.bidiStream(controller.stream).toList();
        streamFutures.add(responseFuture);
      }

      // Feed data into all 5 streams concurrently.
      for (var i = 0; i < 100; i++) {
        for (var s = 0; s < 5; s++) {
          // Each stream gets unique values ≤127 so that doubled results
          // are still ≤254 (single-byte echo encoding).
          // Formula: (s * 100 + i) % 128 ensures all values are in [0,127].
          controllers[s].add((s * 100 + i) % 128);
        }
        // Tiny yield so writes interleave across streams.
        await Future.delayed(Duration.zero);
      }

      // Close all input streams.
      for (final c in controllers) {
        await c.close();
      }

      // Collect results.
      final results = await Future.wait(streamFutures);

      // Verify each stream got its own data back, doubled.
      for (var s = 0; s < 5; s++) {
        final expected = List.generate(100, (i) => ((s * 100 + i) % 128) * 2);
        expect(results[s], equals(expected), reason: 'stream $s data mismatch');
      }

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // ===========================================================================
  // 6. Large Payload Integrity
  // ===========================================================================

  group('Large Payload Integrity', () {
    // -------------------------------------------------------------------------
    // Test 11: 100KB echo via named pipe (exceeds 64KB pipe buffer)
    // -------------------------------------------------------------------------
    // RACE TARGETED: A 100KB payload exceeds the 64KB default pipe buffer,
    // forcing the transport to handle partial writes and reads at the OS
    // level. If the HTTP/2 framing or pipe buffer management reassembles
    // partial reads incorrectly, the payload will be corrupted.
    //
    // EXPECTED: The echoed payload matches the original byte-for-byte.
    testNamedPipe(
      '100KB echo payload exceeding 64KB pipe buffer boundary',
      timeout: const Timeout(Duration(seconds: 90)),
      (pipeName) async {
        final sw = Stopwatch()..start();
        void log(String msg) => print('[Test11 ${sw.elapsedMilliseconds}ms] $msg');

        log('Creating server...');
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());
        log('Server started.');

        log('Creating client channel...');
        final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => channel.terminate());
        final client = EchoClient(channel);

        // Create a 100KB payload with a repeating pattern.
        final payloadSize = 100 * 1024; // 100KB
        final payload = Uint8List(payloadSize);
        for (var i = 0; i < payloadSize; i++) {
          payload[i] = i & 0xFF;
        }
        log('Sending 100KB payload...');

        // Send and receive the payload.
        final response = await client.echoBytes(payload);
        log('Received response: ${response.length} bytes.');

        // Verify the response matches exactly.
        expect(response.length, equals(payloadSize), reason: 'Response length mismatch');
        expect(response, equals(payload), reason: '100KB payload corrupted during echo');

        log('Shutting down channel...');
        await channel.shutdown();
        log('Shutting down server...');
        await server.shutdown();
        log('Test complete. Total time: ${sw.elapsedMilliseconds}ms');
      },
    );

    // -------------------------------------------------------------------------
    // Test 12: Large server-stream bytes (10 chunks x 10KB = 100KB total)
    // -------------------------------------------------------------------------
    // RACE TARGETED: The server streams 10 chunks of 10KB each. Each chunk
    // is a separate gRPC message, but the combined 100KB exceeds the pipe
    // buffer. This exercises the transport's ability to handle many
    // back-to-back large frames without corrupting, reordering, or dropping
    // any chunks.
    //
    // EXPECTED: Exactly 10 chunks received, each 10KB, with correct fill
    // pattern: byte j in chunk i = (i + j) & 0xFF.
    testNamedPipe('10x10KB server-stream chunks totalling 100KB', timeout: const Timeout(Duration(seconds: 90)), (
      pipeName,
    ) async {
      final sw = Stopwatch()..start();
      void log(String msg) => print('[Test12 ${sw.elapsedMilliseconds}ms] $msg');

      log('Creating server...');
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());
      log('Server started.');

      log('Creating client channel...');
      final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel.terminate());
      final client = EchoClient(channel);

      // Build request: 8 bytes big-endian [chunkCount(4), chunkSize(4)].
      final bd = ByteData(8);
      bd.setUint32(0, 10); // chunkCount
      bd.setUint32(4, 10240); // chunkSize = 10KB
      final request = bd.buffer.asUint8List();

      log('Requesting 10x10KB stream...');
      // Collect all streamed chunks.
      final chunks = await client.serverStreamBytes(request).toList();
      log('Received ${chunks.length} chunks.');

      // Verify correct number of chunks.
      expect(chunks.length, equals(10), reason: 'Expected 10 chunks but got ${chunks.length}');

      // Verify each chunk has the correct size and fill pattern.
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].length, equals(10240), reason: 'Chunk $i size mismatch');
        for (var j = 0; j < chunks[i].length; j++) {
          expect(chunks[i][j], equals((i + j) & 0xFF), reason: 'Chunk $i byte $j mismatch');
        }
      }

      log('Shutting down channel...');
      await channel.shutdown();
      log('Shutting down server...');
      await server.shutdown();
      log('Test complete. Total time: ${sw.elapsedMilliseconds}ms');
    });

    // -------------------------------------------------------------------------
    // Test 12a: 10MB echo via named pipe
    // -------------------------------------------------------------------------
    // Exercises sustained throughput at a scale representative of image or
    // document transfer. The 10MB payload spans ~150+ HTTP/2 DATA frames
    // and requires hundreds of partial-read/write cycles through the 64KB
    // pipe buffer. Verifies byte-for-byte integrity after the round trip.
    testNamedPipe('10MB echo payload (sustained throughput)', timeout: const Timeout(Duration(minutes: 3)), (
      pipeName,
    ) async {
      final sw = Stopwatch()..start();
      void log(String msg) => print('[Test12a ${sw.elapsedMilliseconds}ms] $msg');

      log('Creating server...');
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      log('Creating client channel...');
      final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel.terminate());
      final client = EchoClient(channel);

      final payloadSize = 10 * 1024 * 1024;
      final payload = Uint8List(payloadSize);
      for (var i = 0; i < payloadSize; i++) {
        payload[i] = i & 0xFF;
      }
      log('Sending 10MB payload...');

      final response = await client.echoBytes(payload);
      log('Received response: ${response.length} bytes in ${sw.elapsedMilliseconds}ms.');

      expect(response.length, equals(payloadSize), reason: '10MB response length mismatch');
      expect(response, equals(payload), reason: '10MB payload corrupted during echo');

      final throughputMBps = (payloadSize * 2) / (sw.elapsedMilliseconds / 1000) / (1024 * 1024);
      log('Round-trip throughput: ${throughputMBps.toStringAsFixed(1)} MB/s');

      await channel.shutdown();
      await server.shutdown();
      log('Test complete. Total time: ${sw.elapsedMilliseconds}ms');
    });

    // -------------------------------------------------------------------------
    // Test 12b: 30MB echo via named pipe
    // -------------------------------------------------------------------------
    // Stress-tests the transport at a scale matching large binary assets
    // (high-resolution images, serialized model weights, etc.). At 30MB the
    // payload exceeds the pipe buffer by ~470x, exercising every layer of
    // chunking, flow control, and reassembly. A corruption or deadlock at
    // this scale would indicate a fundamental transport defect.
    testNamedPipe('30MB echo payload (large binary asset scale)', timeout: const Timeout(Duration(minutes: 5)), (
      pipeName,
    ) async {
      final sw = Stopwatch()..start();
      void log(String msg) => print('[Test12b ${sw.elapsedMilliseconds}ms] $msg');

      log('Creating server...');
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      log('Creating client channel...');
      final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() => channel.terminate());
      final client = EchoClient(channel);

      final payloadSize = 30 * 1024 * 1024;
      final payload = Uint8List(payloadSize);
      for (var i = 0; i < payloadSize; i++) {
        payload[i] = i & 0xFF;
      }
      log('Sending 30MB payload...');

      final response = await client.echoBytes(payload);
      log('Received response: ${response.length} bytes in ${sw.elapsedMilliseconds}ms.');

      expect(response.length, equals(payloadSize), reason: '30MB response length mismatch');
      expect(response, equals(payload), reason: '30MB payload corrupted during echo');

      final throughputMBps = (payloadSize * 2) / (sw.elapsedMilliseconds / 1000) / (1024 * 1024);
      log('Round-trip throughput: ${throughputMBps.toStringAsFixed(1)} MB/s');

      await channel.shutdown();
      await server.shutdown();
      log('Test complete. Total time: ${sw.elapsedMilliseconds}ms');
    });

    // -------------------------------------------------------------------------
    // Test 13: Deferred close safety net cleans up stalled outgoing stream
    // -------------------------------------------------------------------------
    // RACE TARGETED: Start a large server-stream response, then abruptly
    // terminate the client channel before consuming any response frames.
    // This drives normal close down the deferred path where _onOutgoingDone
    // may never fire if outgoing transport drain stalls.
    //
    // EXPECTED: activePipeStreamCount returns to 0 within the deferred-close
    // safety window (5s + buffer), and the server remains usable.
    testNamedPipe(
      'deferred close timeout cleans up stalled stream after abrupt disconnect',
      timeout: const Timeout(Duration(seconds: 90)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => channel.terminate());
        final client = EchoClient(channel);

        // Request a large server-stream and intentionally do not listen to
        // the response stream. This can stall flow control on the outgoing
        // transport when the client is later terminated.
        final bd = ByteData(8)
          ..setUint32(0, 256) // chunkCount
          ..setUint32(4, 65536); // chunkSize (64KB)
        client.serverStreamBytes(bd.buffer.asUint8List());

        Future<void> waitForActiveStreams({
          required int expected,
          required Duration timeout,
          required String onTimeoutMessage,
        }) async {
          final deadline = DateTime.now().add(timeout);
          while (DateTime.now().isBefore(deadline)) {
            if (server.activePipeStreamCount == expected) return;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          fail(
            '$onTimeoutMessage (activePipeStreamCount='
            '${server.activePipeStreamCount})',
          );
        }

        await waitForActiveStreams(
          expected: 1,
          timeout: const Duration(seconds: 3),
          onTimeoutMessage: 'Server never observed active stream',
        );

        // Abrupt client teardown (RST-like) while server may still be writing.
        await channel.terminate();

        await waitForActiveStreams(
          expected: 0,
          timeout: const Duration(seconds: 8),
          onTimeoutMessage: 'Deferred close safety net failed to clean up stalled stream',
        );

        // Verify server remains healthy for new clients after cleanup.
        final recoveryChannel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => recoveryChannel.terminate());
        final recoveryClient = EchoClient(recoveryChannel);
        expect(await recoveryClient.echo(7), equals(7));

        await recoveryChannel.shutdown();
        await server.shutdown();
      },
    );

    // -------------------------------------------------------------------------
    // Test 14: Server shutdown during deferred close (timer not yet fired)
    // -------------------------------------------------------------------------
    // RACE TARGETED: Enter the deferred close path (read loop exits, outgoing
    // subscription still draining or stalled, 5s safety timer armed), then
    // invoke server.shutdown() before the timer naturally fires. shutdown()
    // must force-close streams, cancelling the timer and cleaning up without
    // waiting for the full 5s window.
    //
    // EXPECTED: No hang. shutdown() completes within a short timeout (well
    // under 5s). activePipeStreamCount returns to 0. Server remains usable
    // for new clients until shutdown completes.
    testNamedPipe(
      'server shutdown during deferred close completes without hang',
      timeout: const Timeout(Duration(seconds: 30)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => channel.terminate());
        final client = EchoClient(channel);

        // Request a large server-stream and do not consume the response.
        // Client terminate triggers deferred close: read loop exits, timer
        // armed (5s). We call shutdown() before the timer fires.
        final bd = ByteData(8)
          ..setUint32(0, 256) // chunkCount
          ..setUint32(4, 65536); // chunkSize (64KB)
        client.serverStreamBytes(bd.buffer.asUint8List());

        Future<void> waitForActiveStreams({
          required int expected,
          required Duration timeout,
          required String onTimeoutMessage,
        }) async {
          final deadline = DateTime.now().add(timeout);
          while (DateTime.now().isBefore(deadline)) {
            if (server.activePipeStreamCount == expected) return;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          fail(
            '$onTimeoutMessage (activePipeStreamCount='
            '${server.activePipeStreamCount})',
          );
        }

        await waitForActiveStreams(
          expected: 1,
          timeout: const Duration(seconds: 3),
          onTimeoutMessage: 'Server never observed active stream',
        );

        // Abrupt client teardown — enters deferred close path.
        await channel.terminate();

        // Brief delay to let read loop exit and deferred timer arm.
        // Platform timing varies; 200ms is enough for the path to be entered
        // but well before the 5s timer.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Shutdown must complete without waiting for the 5s deferred timer.
        // Assert no hang: shutdown finishes within 3s (well under 5s).
        await server.shutdown().timeout(
          const Duration(seconds: 3),
          onTimeout: () => fail('server.shutdown() hung during deferred close race'),
        );

        // Verify server is fully shut down.
        expect(server.isRunning, isFalse);
      },
    );
  });

  // ===========================================================================
  // 7. Pipe Name Collision
  // ===========================================================================

  group('Pipe Name Collision', () {
    // -------------------------------------------------------------------------
    // Test 10: Two servers trying to serve the same pipe name simultaneously
    // -------------------------------------------------------------------------
    // RACE TARGETED: CreateNamedPipe with PIPE_UNLIMITED_INSTANCES means the
    // second server CAN successfully create a new instance of the same pipe.
    // This is dangerous: two server isolates would both call ConnectNamedPipe
    // on the same pipe namespace, leading to undefined behavior where client
    // connections are non-deterministically routed to either server. The
    // second serve() should ideally detect this and fail, OR if it succeeds,
    // both servers must be independently functional.
    //
    // EXPECTED: Either the second serve() throws an error (ideal), OR both
    // servers work independently. In either case, no hang and no crash. We
    // verify that at least one server is functional.
    testNamedPipe(
      'two servers on same pipe name: either fails or both work',
      timeout: const Timeout(Duration(seconds: 90)),
      (pipeName) async {
        final sw = Stopwatch()..start();
        void log(String msg) => print('[Test10 ${sw.elapsedMilliseconds}ms] $msg');

        log('Creating server1...');
        final server1 = NamedPipeServer.create(services: [EchoService()]);
        await server1.serve(pipeName: pipeName);
        log('Server1 started.');
        addTearDown(() async {
          log('addTearDown: shutting down server1...');
          await server1.shutdown();
          log('addTearDown: server1 done.');
        });

        log('Creating server2...');
        final server2 = NamedPipeServer.create(services: [EchoService()]);
        var server2Started = false;

        try {
          await server2.serve(pipeName: pipeName);
          server2Started = true;
          log('Server2 started (dual-server scenario).');
        } catch (e) {
          // This is the IDEAL outcome: the second server detects the
          // collision and refuses to start.
          log('Server2 failed to start (expected): $e');
        }
        addTearDown(() async {
          if (server2Started) {
            log('addTearDown: shutting down server2...');
            await server2.shutdown();
            log('addTearDown: server2 done.');
          }
        });

        // Regardless of whether server2 started, server1 must still work.
        log('Creating client channel...');
        final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => channel.terminate());
        final client = EchoClient(channel);
        log('Calling echo(42)...');
        final result = await client.echo(42);
        expect(result, equals(42));
        log('Echo succeeded: $result');

        log('Shutting down client channel...');
        await channel.shutdown();
        log('Client channel shutdown done.');

        // Clean up — use addTearDown above instead of explicit shutdown
        // to avoid double-shutdown issues.
        log('Test complete. Total time: ${sw.elapsedMilliseconds}ms');
      },
    );
  });

  // ===========================================================================
  // 8. ERROR_NO_DATA (Win32 232) Retry Coverage
  // ===========================================================================
  //
  // Win32 ERROR_NO_DATA (code 232) occurs when PeekNamedPipe or ReadFile
  // is called on a pipe whose peer is in a transitional closing state —
  // the handle is still valid, but no data is available because the peer
  // has initiated disconnect without completing it. This is distinct from
  // ERROR_BROKEN_PIPE (109), which indicates the peer has fully closed.
  //
  // In production, ERROR_NO_DATA manifests during:
  //   (a) Server shutdown while client read loops are polling PeekNamedPipe
  //   (b) Client disconnect while server read loops are polling PeekNamedPipe
  //   (c) Rapid connect/disconnect cycling that maximizes time in the
  //       transitional state
  //
  // The retry logic (NoDataRetryState, 500 retries * 1ms = 500ms window)
  // exists in both:
  //   - _ServerPipeStream._readLoop (server-side)
  //   - _NamedPipeStream._readLoop  (client-side)
  //
  // These tests exercise the production paths where ERROR_NO_DATA is most
  // likely. They cannot directly inject the error (Win32 FFI cannot be
  // mocked), but they create the exact conditions that produce it: rapid
  // shutdown/disconnect during active data transfer.
  //
  // Unit tests for the NoDataRetryState state machine itself are in
  // named_pipe_stress_test.dart (group 'NoData Retry State').

  group('ERROR_NO_DATA Retry Coverage', () {
    // -----------------------------------------------------------------------
    // Test 15: Server shutdown during sustained client read —
    //          ERROR_NO_DATA on client-side PeekNamedPipe
    // -----------------------------------------------------------------------
    // PRODUCTION SCENARIO: The server is streaming a large response. The
    // server shuts down (DisconnectNamedPipe + CloseHandle) while the
    // client's _readLoop is between PeekNamedPipe polls. The client sees
    // ERROR_NO_DATA on the next PeekNamedPipe call because the pipe is
    // in the transitional "disconnecting but not yet broken" state. The
    // retry loop must either recover (if data becomes available) or
    // cleanly terminate (when the pipe transitions to BROKEN_PIPE).
    //
    // VERIFICATION: The client-side stream terminates without hanging,
    // data received before shutdown is intact (no corruption), and the
    // client channel shuts down cleanly.
    testNamedPipe(
      'server shutdown during sustained read triggers clean '
      'client-side read loop termination',
      timeout: const Timeout(Duration(seconds: 60)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => channel.terminate());
        final client = EchoClient(channel);

        // Request a server stream of 255 items (~255ms at 1ms each).
        // 255 is the maximum valid single-byte value — the EchoClient
        // serializer encodes int as `[value]`, so values >255 are
        // truncated via & 0xFF. We shut down the server before the
        // stream completes, forcing the client read loop through the
        // ERROR_NO_DATA -> ERROR_BROKEN_PIPE transition.
        final received = <int>[];
        final streamDone = Completer<void>();
        final unexpectedErrors = <Object>[];

        final subscription = client
            .serverStream(255)
            .listen(
              (value) {
                received.add(value);
              },
              onError: (Object e) {
                // GrpcError is expected when server shuts down mid-stream.
                if (e is! GrpcError) {
                  unexpectedErrors.add(e);
                }
                if (!streamDone.isCompleted) streamDone.complete();
              },
              onDone: () {
                if (!streamDone.isCompleted) streamDone.complete();
              },
            );

        // Wait until we have received some items, proving the stream
        // is active and the pipe is in steady-state data transfer.
        final receiveDeadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(receiveDeadline)) {
          if (received.length >= 10) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        if (received.length < 10) {
          fail(
            'Stream did not receive 10 items within 5s '
            '(got ${received.length}) — stream may not be active',
          );
        }

        // Now shut down the server. This calls DisconnectNamedPipe on
        // all active streams, which is the primary trigger for
        // ERROR_NO_DATA on the client side.
        await server.shutdown();

        // The client stream must terminate (not hang). The read
        // loop's ERROR_NO_DATA retry logic should eventually see the
        // pipe transition to BROKEN_PIPE and exit cleanly.
        await streamDone.future.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            fail(
              'Client stream did not terminate after server '
              'shutdown (received ${received.length} items). '
              'The client-side read loop may be stuck in the '
              'ERROR_NO_DATA retry path.',
            );
          },
        );

        await subscription.cancel();

        // Data integrity: items received before shutdown must be
        // correct. Server-stream values are 0, 1, 2, ... sequential.
        for (var i = 0; i < received.length; i++) {
          expect(
            received[i],
            equals(i),
            reason:
                'Data corruption at index $i: ERROR_NO_DATA retry '
                'may have caused partial read reassembly error',
          );
        }

        // Soft: exact count depends on shutdown vs. delivery race;
        // at least 1 must arrive to prove the stream was active.
        expect(received.length, greaterThanOrEqualTo(1), reason: 'Should have received items before shutdown');
        expect(received.length, lessThan(255), reason: 'Stream should be truncated by server shutdown');

        // No unexpected (non-gRPC) errors from the transport layer.
        expect(
          unexpectedErrors,
          isEmpty,
          reason:
              'ERROR_NO_DATA must be handled by retry logic, not '
              'propagated as raw transport errors',
        );

        await channel.shutdown();
      },
    );

    // -----------------------------------------------------------------------
    // Test 16: Client abrupt disconnect during server read —
    //          ERROR_NO_DATA on server-side PeekNamedPipe
    // -----------------------------------------------------------------------
    // PRODUCTION SCENARIO: A client is sending a bidi stream. The client
    // abruptly terminates (channel.terminate) while the server's
    // _ServerPipeStream._readLoop is polling PeekNamedPipe. The server
    // sees ERROR_NO_DATA because the client's handle closure puts the
    // pipe in the transitional state. The server's retry loop must
    // handle this and eventually exit cleanly.
    //
    // VERIFICATION: The server remains healthy after the abrupt client
    // disconnect (can serve new clients). activePipeStreamCount returns
    // to 0 (no leaked streams). No unhandled async exceptions.
    testNamedPipe(
      'client abrupt disconnect during bidi stream triggers clean '
      'server-side read loop termination',
      timeout: const Timeout(Duration(seconds: 60)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => channel.terminate());
        final client = EchoClient(channel);

        // Open a bidi stream and send data to establish active I/O.
        final inputController = StreamController<int>();
        final responseStream = client.bidiStream(inputController.stream);

        // Collect responses to keep the stream alive.
        final received = <int>[];
        final streamDone = Completer<void>();
        final unexpectedErrors = <Object>[];
        responseStream.listen(
          received.add,
          onError: (Object e) {
            if (e is GrpcError) {
              // Expected when client terminates mid-stream.
            } else {
              unexpectedErrors.add(e);
            }
            if (!streamDone.isCompleted) streamDone.complete();
          },
          onDone: () {
            if (!streamDone.isCompleted) streamDone.complete();
          },
          cancelOnError: false,
        );

        // Send enough data to establish a steady-state bidi exchange.
        // Values ≤127 so doubled results fit in single byte.
        for (var i = 0; i < 50; i++) {
          inputController.add(i % 128);
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }

        // Soft: at least some responses must arrive to prove the
        // bidi stream was active before the disconnect test.
        expect(received.length, greaterThanOrEqualTo(1), reason: 'Bidi stream must be active before disconnect test');

        // Abruptly terminate the client channel. This closes the pipe
        // handle without graceful shutdown, maximizing the chance of
        // the server hitting ERROR_NO_DATA.
        await channel.terminate();

        // Wait for the server's pipe stream to clean up. The server-
        // side read loop should handle ERROR_NO_DATA retries and
        // eventually see ERROR_BROKEN_PIPE, then close the stream.
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          if (server.activePipeStreamCount == 0) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          server.activePipeStreamCount,
          equals(0),
          reason:
              'Server pipe stream was not cleaned up after client '
              'disconnect. The server-side ERROR_NO_DATA retry loop '
              'may be stuck or leaked the stream.',
        );

        expect(
          unexpectedErrors,
          isEmpty,
          reason:
              'Bidi stream onError must only receive GrpcError when '
              'client terminates; unexpectedErrors must be empty; '
              'got $unexpectedErrors',
        );

        // Verify server is still healthy — can serve a new client.
        final channel2 = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => channel2.terminate());
        final client2 = EchoClient(channel2);
        final result = await client2.echo(42);
        expect(result, equals(42));

        await channel2.shutdown();
        await inputController.close();
        await server.shutdown();
      },
    );

    // -----------------------------------------------------------------------
    // Test 17: Rapid connect/disconnect cycling — maximizes ERROR_NO_DATA
    //          window on both server and client sides
    // -----------------------------------------------------------------------
    // PRODUCTION SCENARIO: Under load, clients rapidly connect, send a
    // few RPCs, and disconnect. Each disconnect creates a brief
    // ERROR_NO_DATA window on the server side. Rapid reconnection means
    // the server is simultaneously handling ERROR_NO_DATA retries on old
    // connections and accepting new connections on fresh pipe instances.
    //
    // This is the highest-frequency ERROR_NO_DATA production scenario:
    // short-lived connections with rapid turnover.
    //
    // VERIFICATION: All RPCs succeed or fail with expected errors.
    // Server remains healthy throughout. No resource leaks
    // (activePipeStreamCount returns to 0 after all cycles). No hangs.
    testNamedPipe(
      'rapid connect/disconnect cycling exercises ERROR_NO_DATA '
      'retry on both sides',
      timeout: const Timeout(Duration(seconds: 60)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        // 12 rapid cycles. Each cycle: connect, fire RPC, terminate
        // (not graceful shutdown — terminate is harsher, more likely
        // to produce ERROR_NO_DATA on server side).
        final cycleChannels = <NamedPipeClientChannel>[];
        addTearDown(() async {
          for (final ch in cycleChannels) {
            try {
              await ch.terminate();
            } on GrpcError {
              // Channel already dead — expected during teardown.
            } on StateError {
              // Channel already shut down — expected during teardown.
            } on NamedPipeException {
              // Pipe handle already closed — expected during teardown.
            }
          }
        });
        for (var cycle = 0; cycle < 12; cycle++) {
          final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
          cycleChannels.add(channel);
          final client = EchoClient(channel);

          // Fire RPC and settle (allow error).
          final result = await settleRpc(client.echo(cycle % 256)).timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail(
              'RPC hung on rapid cycle $cycle — possible '
              'ERROR_NO_DATA retry deadlock',
            ),
          );

          // RPC either succeeded or failed with expected error.
          // StateError not included: rapid cycling uses terminate();
          // failures are GrpcError, NamedPipeException, or TimeoutException.
          expect(
            result,
            anyOf(equals(cycle % 256), isA<GrpcError>(), isA<NamedPipeException>(), isA<TimeoutException>()),
            reason:
                'Unexpected error type on rapid cycle '
                '$cycle: $result',
          );

          // Abrupt terminate (not graceful shutdown) to maximize
          // ERROR_NO_DATA probability on the server side.
          await channel.terminate();

          // Minimal delay — just enough to avoid overwhelming the
          // accept loop, but short enough to keep the ERROR_NO_DATA
          // window open.
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // After all cycles, wait for server to clean up all streams.
        // This verifies the server's ERROR_NO_DATA retry logic didn't
        // leak any pipe streams.
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          if (server.activePipeStreamCount == 0) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          server.activePipeStreamCount,
          equals(0),
          reason:
              'Server leaked pipe streams after rapid connect/'
              'disconnect cycling. ERROR_NO_DATA retry logic may '
              'not be cleaning up properly.',
        );

        // Final health check: server can still serve new clients.
        final verifyChannel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => verifyChannel.terminate());
        final verifyClient = EchoClient(verifyChannel);
        expect(await verifyClient.echo(99), equals(99));

        await verifyChannel.shutdown();
        await server.shutdown();
      },
    );

    // -----------------------------------------------------------------------
    // Test 18: Overlapping client disconnects — concurrent ERROR_NO_DATA
    //          on multiple server-side read loops
    // -----------------------------------------------------------------------
    // PRODUCTION SCENARIO: Multiple clients are connected simultaneously.
    // All clients disconnect at nearly the same time (e.g., load balancer
    // drains connections). Each client disconnect triggers ERROR_NO_DATA
    // on the server's read loop for that connection. All retry loops run
    // concurrently on the server's main isolate event loop, competing
    // for event loop time.
    //
    // This tests that concurrent ERROR_NO_DATA retry loops don't starve
    // each other or the event loop, causing timeouts or resource leaks.
    //
    // VERIFICATION: All server pipe streams clean up. Server remains
    // healthy for new clients.
    testNamedPipe(
      'concurrent client disconnects trigger parallel '
      'ERROR_NO_DATA retry on server',
      timeout: const Timeout(Duration(seconds: 60)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        // Connect 5 clients and verify they all work.
        final channels = <NamedPipeClientChannel>[];
        addTearDown(() async {
          for (final ch in channels) {
            try {
              await ch.terminate();
            } on GrpcError {
              // Channel already dead — expected during teardown.
            } on StateError {
              // Channel already shut down — expected during teardown.
            } on NamedPipeException {
              // Pipe handle already closed — expected during teardown.
            }
          }
        });
        for (var i = 0; i < 5; i++) {
          final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
          channels.add(channel);
          final client = EchoClient(channel);
          expect(await client.echo(i), equals(i), reason: 'Channel $i warmup failed');
        }

        // Verify server has 5 active pipe streams.
        expect(server.activePipeStreamCount, equals(5), reason: 'Expected 5 active streams after warmup');

        // Terminate all 5 clients nearly simultaneously. Each
        // terminate() triggers abrupt handle closure, creating
        // concurrent ERROR_NO_DATA conditions on the server.
        await Future.wait([for (final ch in channels) ch.terminate()]);

        // Wait for all server pipe streams to clean up.
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          if (server.activePipeStreamCount == 0) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          server.activePipeStreamCount,
          equals(0),
          reason:
              'Server leaked pipe streams after concurrent '
              'client disconnects. Concurrent ERROR_NO_DATA retry '
              'loops may be starving each other.',
        );

        // Server health check: can still accept and serve new
        // clients.
        final verifyChannel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => verifyChannel.terminate());
        final verifyClient = EchoClient(verifyChannel);
        expect(await verifyClient.echo(77), equals(77));

        await verifyChannel.shutdown();
        await server.shutdown();
      },
    );

    // -----------------------------------------------------------------------
    // Test 19: Server shutdown during high-throughput stream — exercises
    //          ERROR_NO_DATA at maximum pipe buffer pressure
    // -----------------------------------------------------------------------
    // PRODUCTION SCENARIO: A server is streaming large payloads that
    // saturate the 64KB pipe buffer. Server shutdown during this state
    // means DisconnectNamedPipe is called while the pipe buffer still
    // contains unread data. The client's read loop encounters
    // ERROR_NO_DATA because the pipe transitions through: data available
    // -> disconnecting (NO_DATA) -> broken (BROKEN_PIPE).
    //
    // This is the highest-risk ERROR_NO_DATA scenario because the retry
    // loop must handle the transition correctly despite the pipe buffer
    // being full of data that will never be fully delivered.
    //
    // VERIFICATION: Client stream terminates cleanly (no hang). Data
    // received before shutdown is intact. Channel shuts down without
    // resource leaks.
    testNamedPipe(
      'server shutdown during buffer-saturating stream exercises '
      'ERROR_NO_DATA at pipe buffer boundary',
      timeout: const Timeout(Duration(seconds: 60)),
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
        addTearDown(() => channel.terminate());
        final client = EchoClient(channel);

        // Request 500 chunks of 1KB each (500KB total — well exceeds
        // the 64KB pipe buffer). This saturates the pipe buffer,
        // ensuring there is pending data when we shut down.
        final request = encodeStreamBytesRequest(500, 1024);
        final received = <List<int>>[];
        final streamDone = Completer<void>();
        final unexpectedErrors = <Object>[];

        final subscription = client
            .serverStreamBytes(request)
            .listen(
              (chunk) {
                received.add(chunk);
              },
              onError: (Object e) {
                if (e is! GrpcError) {
                  unexpectedErrors.add(e);
                }
                if (!streamDone.isCompleted) {
                  streamDone.complete();
                }
              },
              onDone: () {
                if (!streamDone.isCompleted) {
                  streamDone.complete();
                }
              },
            );

        // Wait until we've received enough chunks to prove the pipe
        // buffer has been saturated at least once (> 64 chunks of
        // 1KB = 64KB = buffer size).
        final bufferDeadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(bufferDeadline)) {
          if (received.length >= 64) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        if (received.length < 64) {
          fail(
            'Stream did not receive 64 chunks within 10s '
            '(got ${received.length}) — pipe buffer may not be saturated',
          );
        }

        // Shut down the server while the pipe buffer is full of
        // pending data. DisconnectNamedPipe discards unread data,
        // creating the ERROR_NO_DATA -> ERROR_BROKEN_PIPE
        // transition.
        await server.shutdown();

        // Client stream must terminate — not hang in ERROR_NO_DATA
        // retry loop.
        await streamDone.future.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            fail(
              'Client stream did not terminate after server '
              'shutdown during buffer-saturating transfer '
              '(received ${received.length} chunks). '
              'ERROR_NO_DATA retry loop may be stuck.',
            );
          },
        );

        await subscription.cancel();

        // Data integrity on received chunks.
        for (var i = 0; i < received.length; i++) {
          expect(received[i].length, equals(1024), reason: 'Chunk $i has wrong size');
          // Verify fill pattern: byte j in chunk i = (i+j) & 0xFF.
          for (var j = 0; j < received[i].length; j++) {
            expect(received[i][j], equals((i + j) & 0xFF), reason: 'Chunk $i byte $j corrupted');
          }
        }

        // Soft: shutdown races chunk delivery; at least 1 chunk
        // must arrive to prove the stream was active.
        expect(received.length, greaterThanOrEqualTo(1), reason: 'Should have received chunks before shutdown');
        expect(received.length, lessThan(500), reason: 'Stream should be truncated by server shutdown');

        expect(
          unexpectedErrors,
          isEmpty,
          reason:
              'ERROR_NO_DATA must be handled internally by the '
              'retry loop, not propagated as transport errors',
        );

        await channel.shutdown();
      },
    );
  });
}
