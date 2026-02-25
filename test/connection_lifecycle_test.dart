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

/// Tests for HTTP/2 connection lifecycle fixes in the open-runtime fork.
///
/// These tests verify:
/// - Connection generation tracking (_connectionGeneration) prevents stale
///   socket.done callbacks from abandoning new connections
/// - Rapid reconnection cycles are stable
/// - shutdown/terminate clean up all resources
/// - makeRequest on null connection throws GrpcError.unavailable-style error
///   (ArgumentError with descriptive message, not a null pointer crash)
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Connection generation tracking
  // ---------------------------------------------------------------------------
  group('Connection generation tracking', () {
    testTcpAndUds(
      'stale socket.done callback does not abandon new connection',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channel = TestClientChannel(
          Http2ClientConnection(
            address,
            server.port!,
            ChannelOptions(
              credentials: ChannelCredentials.insecure(),
              // Short connection timeout so reconnection is quick
              connectionTimeout: const Duration(milliseconds: 200),
            ),
          ),
        );

        final client = EchoClient(channel);

        // First call establishes connection (generation 1)
        expect(await client.echo(1), equals(1));
        expect(channel.states, contains(ConnectionState.ready));

        // Wait for connection to age out, triggering reconnect on next call
        await Future.delayed(const Duration(milliseconds: 300));

        // Second call forces a reconnection (generation 2).
        // The old socket.done from generation 1 may still fire,
        // but should be ignored because generation has advanced.
        expect(await client.echo(2), equals(2));

        // Verify the connection went through a second ready cycle
        final readyCount = channel.states
            .where((s) => s == ConnectionState.ready)
            .length;
        expect(
          readyCount,
          greaterThanOrEqualTo(2),
          reason: 'Should have connected at least twice (original + reconnect)',
        );

        addTearDown(() => channel.shutdown());
      },
    );

    testTcpAndUds('rapid reconnection cycles are stable', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            // Very short timeout forces frequent reconnection
            connectionTimeout: const Duration(milliseconds: 50),
          ),
        ),
      );

      final client = EchoClient(channel);

      // Perform 5 rounds of connect + request + age-out
      for (var i = 0; i < 5; i++) {
        final result = await client.echo(i);
        expect(result, equals(i));
        // Wait for connection to age out
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Verify all requests succeeded and we had multiple ready states
      final readyCount = channel.states
          .where((s) => s == ConnectionState.ready)
          .length;
      expect(
        readyCount,
        greaterThanOrEqualTo(4),
        reason: 'Should have reconnected multiple times',
      );

      addTearDown(() => channel.shutdown());
    });
  });

  // ---------------------------------------------------------------------------
  // Connection cleanup
  // ---------------------------------------------------------------------------
  group('Connection cleanup', () {
    testTcpAndUds('shutdown cleans up all resources', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Establish connection and make a request
      expect(await client.echo(42), equals(42));
      expect(channel.states, contains(ConnectionState.ready));

      // Shutdown
      await channel.shutdown();

      // Verify shutdown state was reached
      expect(channel.states.last, equals(ConnectionState.shutdown));

      // Verify further calls fail
      try {
        await client.echo(1);
        fail('Should have thrown after shutdown');
      } catch (e) {
        expect(e, isA<GrpcError>());
      }

      addTearDown(() => channel.shutdown());
    });

    testTcpAndUds('terminate cleans up all resources', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Establish connection and make a request
      expect(await client.echo(42), equals(42));
      expect(channel.states, contains(ConnectionState.ready));

      // Terminate (more aggressive than shutdown)
      await channel.terminate();

      // Verify shutdown state was reached
      expect(channel.states.last, equals(ConnectionState.shutdown));

      addTearDown(() => channel.shutdown());
    });

    testTcpAndUds(
      'terminate after shutdown escalates and settles active streams',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channel = createTestChannel(address, server.port!);
        addTearDown(() => channel.shutdown());
        final client = EchoClient(channel);

        // Ensure connection is established.
        expect(await client.echo(1), equals(1));

        // Start a long-running stream so escalation has work to do.
        final streamFuture = client
            .serverStream(100)
            .toList()
            .then<Object?>((v) => v, onError: (Object e) => e);

        await Future<void>.delayed(const Duration(milliseconds: 30));
        await channel.shutdown();
        await channel.terminate();

        // If terminate() incorrectly no-ops after shutdown(), this can hang.
        final streamResult = await streamFuture.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            fail(
              'active stream did not settle after shutdown() + terminate() '
              'escalation',
            );
          },
        );
        expect(
          streamResult,
          anyOf(
            isA<List<int>>(),
            isA<GrpcError>(),
            isA<SocketException>(),
            isA<TimeoutException>(),
            isA<StateError>(),
          ),
          reason:
              'Active stream must settle to data or explicit transport error',
        );

        // Repeated terminal operations should remain safe no-ops.
        await channel.terminate();
        await channel.shutdown();
      },
    );
  });

  // ---------------------------------------------------------------------------
  // makeRequest error handling
  // ---------------------------------------------------------------------------
  group('makeRequest error handling', () {
    testTcpAndUds(
      'makeRequest on null connection throws GrpcError.unavailable',
      (address) async {
        // Create a connection object but do NOT connect it.
        // The _transportConnection is null.
        final connection = Http2ClientConnection(
          address,
          12345, // arbitrary port, doesn't matter
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        );
        addTearDown(() => connection.shutdown());

        // Calling makeRequest when _transportConnection is null should
        // throw a GrpcError.unavailable with an informative message,
        // NOT a null pointer exception (NoSuchMethodError on null).
        // The fork fix replaced the raw null dereference with:
        //   throw GrpcError.unavailable('Connection not ready');
        expect(
          () => connection.makeRequest(
            '/test.EchoService/Echo',
            null,
            {},
            (e, st) {},
            callOptions: CallOptions(),
          ),
          throwsA(
            allOf(
              isA<GrpcError>(),
              predicate<GrpcError>(
                (e) => e.code == StatusCode.unavailable,
                'has status code UNAVAILABLE',
              ),
              predicate<GrpcError>(
                (e) =>
                    e.message != null &&
                    e.message!.contains('Connection not ready'),
                'has "Connection not ready" message',
              ),
            ),
          ),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Server shutdown during active streaming
  // ---------------------------------------------------------------------------
  group('Server shutdown during active handlers', () {
    testTcpAndUds('server shutdown terminates active streams cleanly', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Start a long server stream
      final streamFuture = client
          .serverStream(100)
          .toList()
          .then((results) => results, onError: (e) => <int>[]);

      // Wait for handler registration (deterministic signal).
      await waitForHandlers(
        server,
        reason: 'Handler must be active before shutdown test',
      );

      // Shutdown server while stream is active
      await server.shutdown();

      // Stream should either complete partially or error gracefully.
      final results = await streamFuture;
      expect(
        results.length,
        lessThan(100),
        reason:
            'Stream should have been truncated by shutdown '
            '(received ${results.length}/100 items)',
      );

      // Verify data integrity of whatever DID arrive.
      for (var i = 0; i < results.length; i++) {
        expect(
          results[i],
          equals(i + 1),
          reason: 'item $i should equal ${i + 1}',
        );
      }

      addTearDown(() => channel.shutdown());
    });

    testTcpAndUds('server shutdown during active streams does not crash', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Start a long server stream
      final streamFuture = client
          .serverStream(100)
          .toList()
          .then((results) => results, onError: (e) => <int>[]);

      // Wait for handler registration (deterministic signal).
      await waitForHandlers(
        server,
        reason: 'Handler must be active before double-terminate test',
      );

      // Shutdown while stream is active. server.shutdown()
      // calls cancel() on all active handlers, which calls
      // _terminateStream(). If the handler already completed
      // and terminated, the second call must be a no-op.
      await server.shutdown();

      final results = await streamFuture;
      expect(
        results.length,
        lessThan(100),
        reason:
            'Stream should have been truncated by shutdown '
            '(received ${results.length}/100 items)',
      );

      // Verify data integrity of whatever DID arrive.
      for (var i = 0; i < results.length; i++) {
        expect(
          results[i],
          equals(i + 1),
          reason: 'item $i should equal ${i + 1}',
        );
      }

      addTearDown(() => channel.shutdown());
    });
  });

  // ---------------------------------------------------------------------------
  // Connection idle timeout
  // ---------------------------------------------------------------------------
  group('Connection idle timeout', () {
    testTcpAndUds('idle connection transitions to idle state', (address) async {
      const idleTimeout = Duration(milliseconds: 100);
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            idleTimeout: idleTimeout,
          ),
        ),
      );

      final client = EchoClient(channel);

      // Make a request to establish connection
      expect(await client.echo(1), equals(1));
      expect(channel.states, contains(ConnectionState.ready));

      // Wait for idle timeout to fire (config-derived: 3x idleTimeout).
      await Future.delayed(idleTimeout * 3);

      // The connection should have gone idle
      expect(channel.states, contains(ConnectionState.idle));

      // But a new request should still work (re-establishes connection)
      expect(await client.echo(2), equals(2));

      addTearDown(() => channel.shutdown());
    });
  });

  // ---------------------------------------------------------------------------
  // Generation counter stress
  // ---------------------------------------------------------------------------
  group('Generation counter stress', () {
    // 30 rapid reconnection cycles force the generation counter far
    // beyond 2. Each cycle: RPC succeeds → connection ages out →
    // next RPC triggers a new generation. If the generation guard in
    // _handleSocketDone is wrong (e.g., uses == instead of <, or
    // wraps around), a stale socket.done callback from an early
    // generation will corrupt a much later connection.
    testTcpAndUds('rapid reconnection forces generation counter to 30+', (
      address,
    ) async {
      const connectionTimeout = Duration(milliseconds: 20);
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            // Very short timeout forces reconnection each cycle.
            connectionTimeout: connectionTimeout,
          ),
        ),
      );
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // 30 cycles: RPC + wait for connection to age out.
      // Use 50ms (slightly > 2x connectionTimeout) for reliable aging.
      const cycleWait = Duration(milliseconds: 50);
      for (var i = 0; i < 30; i++) {
        final result = await client
            .echo(i % 256)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                fail(
                  'echo hung at cycle $i -- stale generation '
                  'callback may have corrupted connection',
                );
              },
            );
        expect(result, equals(i % 256), reason: 'cycle $i');
        // Config-derived wait for connection timeout to expire.
        await Future.delayed(cycleWait);
      }

      // Verify we had many ready states (one per reconnection).
      final readyCount = channel.states
          .where((s) => s == ConnectionState.ready)
          .length;
      expect(
        readyCount,
        greaterThanOrEqualTo(22),
        reason:
            'Should have reconnected at least 22 times '
            'across 30 cycles (got $readyCount)',
      );

      await channel.shutdown();
    });

    // After 5 full connection cycles, each with a real RPC, verify
    // the final RPC on a 6th connection succeeds. This confirms that
    // stale socket.done callbacks from ALL 5 prior generations are
    // properly ignored and do not poison the active connection.
    testTcpAndUds('stale callbacks from all prior generations are ignored', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            connectionTimeout: const Duration(milliseconds: 30),
          ),
        ),
      );

      final client = EchoClient(channel);

      // 5 full cycles to build up stale callbacks.
      for (var i = 0; i < 5; i++) {
        expect(await client.echo(i), equals(i), reason: 'setup cycle $i');
        await Future.delayed(const Duration(milliseconds: 80));
      }

      // The final verification RPC: by now, 5 stale socket.done
      // callbacks exist. If any of them fires and resets the
      // connection, this RPC will fail or hang.
      final finalResult = await client
          .echo(99)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              fail(
                'final echo hung -- stale socket.done callback '
                'likely poisoned the active connection',
              );
            },
          );
      expect(finalResult, equals(99));

      // Verify the connection is still healthy: no unexpected
      // shutdown or idle state at the end.
      expect(
        channel.states.last,
        isNot(equals(ConnectionState.shutdown)),
        reason: 'connection should not be shut down',
      );

      await channel.shutdown();
    });

    // 50 RPCs fired simultaneously on a brand-new channel. All 50
    // trigger the lazy connect path concurrently. The channel must
    // coalesce all 50 into a single connection attempt (not 50
    // parallel TCP connects). If the channel creates multiple
    // connections, stream IDs may collide or the server may see
    // unexpected sessions.
    testTcpAndUds(
      '50 concurrent RPCs on fresh channel converge to single connection',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channel = TestClientChannel(
          Http2ClientConnection(
            address,
            server.port!,
            ChannelOptions(credentials: ChannelCredentials.insecure()),
          ),
        );

        final client = EchoClient(channel);

        // Fire 50 RPCs simultaneously on the fresh (unconnected)
        // channel. All 50 hit the lazy-connect path at the same
        // time.
        final futures = List.generate(
          50,
          (i) => client
              .echo(i % 256)
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  fail(
                    'concurrent lazy-connect RPC $i timed out '
                    '-- possible duplicate connection deadlock',
                  );
                },
              ),
        );

        final results = await Future.wait(futures);

        for (var i = 0; i < results.length; i++) {
          expect(results[i], equals(i % 256), reason: 'concurrent RPC $i');
        }

        // Verify only 1 ready state transition occurred (all 50
        // RPCs shared the same connection).
        final readyCount = channel.states
            .where((s) => s == ConnectionState.ready)
            .length;
        expect(
          readyCount,
          equals(1),
          reason:
              'All 50 concurrent RPCs should share a single '
              'connection (got $readyCount ready transitions)',
        );

        await channel.shutdown();
      },
    );

    testTcpAndUds(
      'M4: _abandonConnection during pending-dispatch yield (connector.done)',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channel = TestClientChannel(
          Http2ClientConnection(
            address,
            server.port!,
            ChannelOptions(credentials: ChannelCredentials.insecure()),
          ),
        );
        addTearDown(() => channel.shutdown());
        final client = EchoClient(channel);

        const callCount = 20;
        final rpcFutures = List.generate(
          callCount,
          (i) => client
              .echo((i * 17) % 256)
              .then<Object?>((v) => v, onError: (e) => e),
        );

        final readyDeadline = DateTime.now().add(const Duration(seconds: 2));
        while (!channel.states.contains(ConnectionState.ready) &&
            DateTime.now().isBefore(readyDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }

        late Future<void> serverShutdownFuture;
        Timer(Duration.zero, () {
          serverShutdownFuture = server.shutdown();
        });
        await Future<void>.delayed(Duration.zero);

        final transientDeadline = DateTime.now().add(
          const Duration(seconds: 2),
        );
        while (!channel.states.contains(ConnectionState.transientFailure) &&
            DateTime.now().isBefore(transientDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(
          channel.states,
          anyOf(
            contains(ConnectionState.transientFailure),
            contains(ConnectionState.idle),
          ),
          reason:
              'Expected transientFailure or idle after connector.done (server '
              'kill)',
        );

        await channel.shutdown();
        await serverShutdownFuture;

        // Await all RPCs so they settle (succeed or error). Without this,
        // the test would leak uncompleted futures and the analyzer flags
        // rpcFutures as unused.
        await Future.wait(rpcFutures).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail(
            'M4: RPCs did not settle after server kill + channel shutdown',
          ),
        );
      },
    );

    testTcpAndUds('shutdown during pending dispatch settles all queued RPCs', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      const callCount = 500;
      final rpcFutures = List.generate(
        callCount,
        (i) => client
            .echo((i * 17) % 256)
            .then<Object?>((v) => v, onError: (e) => e),
      );

      // Wait briefly for lazy-connect to enter ready and start dispatching
      // queued calls with yields between each dispatch.
      final readyDeadline = DateTime.now().add(const Duration(seconds: 2));
      while (!channel.states.contains(ConnectionState.ready) &&
          DateTime.now().isBefore(readyDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      await channel.shutdown();

      // Regression guard: no queued call may be orphaned/hung.
      final settled = await Future.wait(rpcFutures).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          fail(
            'Queued RPCs did not settle after shutdown during pending '
            'dispatch -- possible orphaned pending calls',
          );
        },
      );

      expect(settled.length, equals(callCount));
      for (final result in settled) {
        expect(result, anyOf(isA<int>(), isA<GrpcError>()));
      }

      // Server should remain healthy after high-pressure shutdown race.
      final probeChannel = createTestChannel(address, server.port!);
      final probeClient = EchoClient(probeChannel);
      expect(await probeClient.echo(77), equals(77));
      await probeChannel.shutdown();
    });

    testTcpAndUds(
      'stress: repeated shutdown during pending dispatch does not orphan RPCs',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        const cycles = 20;
        const callCountPerCycle = 200;

        for (var cycle = 0; cycle < cycles; cycle++) {
          final channel = TestClientChannel(
            Http2ClientConnection(
              address,
              server.port!,
              ChannelOptions(credentials: ChannelCredentials.insecure()),
            ),
          );
          addTearDown(() => channel.shutdown());
          final client = EchoClient(channel);

          final rpcFutures = List.generate(
            callCountPerCycle,
            (i) => client
                .echo((cycle * 100 + i) % 256)
                .then<Object?>((v) => v, onError: (e) => e),
          );

          // Alternate race patterns to broaden coverage:
          //  - Even cycles: wait for ready, then kill during pending dispatch.
          //  - Odd cycles: kill immediately while still connecting.
          if (cycle.isEven) {
            final readyDeadline = DateTime.now().add(
              const Duration(seconds: 2),
            );
            while (!channel.states.contains(ConnectionState.ready) &&
                DateTime.now().isBefore(readyDeadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }

          // Stress escalation semantics: shutdown + terminate overlap.
          await Future.wait([channel.shutdown(), channel.terminate()]);

          final settled = await Future.wait(rpcFutures).timeout(
            const Duration(seconds: 12),
            onTimeout: () {
              fail(
                'Cycle $cycle: queued RPCs did not settle after shutdown '
                'during pending dispatch',
              );
            },
          );

          expect(
            settled.length,
            equals(callCountPerCycle),
            reason: 'Cycle $cycle should settle all queued RPCs',
          );
        }
      },
      udsTimeout: const Timeout(Duration(seconds: 180)),
    );

    // Fire 50 RPCs, wait for reconnection, fire 50 more. All 100
    // must succeed. The second batch requires the channel to
    // transparently reconnect while under concurrent load. If the
    // generation guard or pending-dispatch logic has a gap, some
    // RPCs from the second batch will hang or error unexpectedly.
    testTcpAndUds('50 concurrent RPCs during reconnection cycle', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            connectionTimeout: const Duration(milliseconds: 30),
          ),
        ),
      );
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      // Round 1: 50 concurrent RPCs on a fresh channel.
      final round1 = List.generate(
        50,
        (i) => client
            .echo(i % 256)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                fail(
                  'round 1 RPC $i timed out '
                  '-- lazy-connect deadlock',
                );
              },
            ),
      );
      final r1 = await Future.wait(round1);
      for (var i = 0; i < r1.length; i++) {
        expect(r1[i], equals(i % 256), reason: 'round 1 RPC $i');
      }

      // Wait for connection to age out (> connectionTimeout).
      await Future.delayed(const Duration(milliseconds: 80));

      // Round 2: 50 more concurrent RPCs — forces reconnection.
      final round2 = List.generate(
        50,
        (i) => client
            .echo((i + 50) % 256)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                fail(
                  'round 2 RPC $i timed out '
                  '-- reconnection stalled',
                );
              },
            ),
      );
      final r2 = await Future.wait(round2);
      for (var i = 0; i < r2.length; i++) {
        expect(r2[i], equals((i + 50) % 256), reason: 'round 2 RPC $i');
      }

      // Verify at least 2 ready transitions (original + reconnect).
      final readyCount = channel.states
          .where((s) => s == ConnectionState.ready)
          .length;
      expect(
        readyCount,
        greaterThanOrEqualTo(2),
        reason:
            'Should have reconnected at least once '
            '(got $readyCount ready transitions)',
      );

      await channel.shutdown();
    });

    // Build up 5 generations via echo cycles, then on the 6th
    // cycle fire 20 concurrent RPCs and immediately terminate the
    // channel. All 20 must settle (to int or GrpcError, not hang).
    // This verifies that terminate() during an active generation
    // transition does not leave orphaned futures or corrupt the
    // state machine.
    testTcpAndUds('terminate during active generation counter advancement', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            connectionTimeout: const Duration(milliseconds: 20),
          ),
        ),
      );
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      // 5 echo cycles to build up generation counter.
      for (var i = 0; i < 5; i++) {
        final result = await client
            .echo(i % 256)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                fail('setup echo hung at cycle $i');
              },
            );
        expect(result, equals(i % 256), reason: 'setup cycle $i');
        // Wait for connection to age out.
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // 6th cycle: fire 20 concurrent RPCs + immediately
      // terminate the channel. The RPCs race against
      // terminate() during a generation transition.
      final rpcFutures = List.generate(
        20,
        (i) => client.echo(i % 256).then<Object?>((v) => v, onError: (e) => e),
      );

      // Terminate immediately — do not wait for RPCs.
      await channel.terminate();

      // All 20 must settle (success or GrpcError).
      final settled = await Future.wait(rpcFutures).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          fail(
            'RPCs did not settle after terminate() '
            'during generation advancement',
          );
        },
      );

      expect(settled.length, equals(20));
      for (var i = 0; i < settled.length; i++) {
        expect(
          settled[i],
          anyOf(isA<int>(), isA<GrpcError>()),
          reason:
              'RPC $i must settle to int or GrpcError, '
              'not hang or throw arbitrary error',
        );
      }
    });
  });
}
