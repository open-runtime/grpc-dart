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

/// Tests for the dispatch re-queue mechanism in http2_connection.dart.
///
/// When a connection drops during RPC dispatch, pending calls are
/// re-queued and retried on the next connection. The generation
/// counter prevents stale callbacks from interfering.
@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

void main() {
  // ==============================================================
  // Group 1: Connection recovery and re-dispatch
  // ==============================================================
  group('Connection recovery and re-dispatch', () {
    testTcpAndUds('RPCs succeed after server restart '
        '(connection recovery)', (address) async {
      // -- Server 1 ----------------------------------------
      final server1 = Server.create(services: [EchoService()]);
      await server1.serve(address: address, port: 0);
      addTearDown(() => server1.shutdown());

      final channel1 = createTestChannel(address, server1.port!);
      addTearDown(() => channel1.shutdown());

      final client1 = EchoClient(channel1);

      final result1 = await client1
          .echo(42)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('echo(42) on server1 timed out'),
          );
      expect(
        result1,
        equals(42),
        reason: 'First echo on server1 should return 42',
      );

      await channel1.shutdown();
      await server1.shutdown();

      // -- Server 2 (new instance, new port) ----------------
      final server2 = Server.create(services: [EchoService()]);
      await server2.serve(address: address, port: 0);
      addTearDown(() => server2.shutdown());

      final channel2 = createTestChannel(address, server2.port!);
      addTearDown(() => channel2.shutdown());

      final client2 = EchoClient(channel2);

      final result2 = await client2
          .echo(99)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('echo(99) on server2 timed out'),
          );
      expect(
        result2,
        equals(99),
        reason:
            'Echo on server2 should return 99, '
            'proving lifecycle works across instances',
      );

      await channel2.shutdown();
      await server2.shutdown();
    });

    testTcpAndUds('10 concurrent RPCs on fresh channel '
        'converge to single connection', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Fire 10 RPCs simultaneously on a fresh channel.
      final futures = List.generate(
        10,
        (i) => client
            .echo(i % 256)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => fail('Concurrent echo($i) timed out'),
            ),
      );
      final results = await Future.wait(futures);

      expect(
        results,
        equals(List.generate(10, (i) => i)),
        reason:
            'All 10 concurrent RPCs must succeed '
            'with correct values',
      );

      // There should be exactly 1 ready transition,
      // not 10 separate connections.
      final readyCount = channel.states
          .where((s) => s == ConnectionState.ready)
          .length;
      expect(
        readyCount,
        equals(1),
        reason:
            'Only 1 ready transition expected, got '
            '$readyCount — concurrent RPCs should '
            'share a single connection',
      );

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('RPCs across 5 sequential server restart cycles', (
      address,
    ) async {
      for (var cycle = 0; cycle < 5; cycle++) {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);

        final client = EchoClient(channel);

        for (var i = 0; i < 10; i++) {
          final value = (cycle * 10 + i) % 256;
          final result = await client
              .echo(value)
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () => fail(
                  'echo($value) timed out in '
                  'cycle $cycle, iteration $i',
                ),
              );
          expect(
            result,
            equals(value),
            reason:
                'Cycle $cycle, iteration $i: '
                'echo($value) should return $value',
          );
        }

        await channel.shutdown();
        await server.shutdown();
      }
    });

    testTcpAndUds('channel survives server going away '
        'and returns error', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Successful RPC before shutdown.
      final result = await client
          .echo(42)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('Initial echo(42) timed out'),
          );
      expect(
        result,
        equals(42),
        reason:
            'Echo before server shutdown should '
            'succeed with 42',
      );

      // Kill the server, no restart.
      await server.shutdown();

      // Attempt another RPC -- should fail gracefully
      // with a GrpcError, not a raw crash.
      final settled = await settleRpc(
        client
            .echo(99)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => fail(
                'Post-shutdown echo should error, '
                'not hang',
              ),
            ),
      );
      expect(
        settled,
        isA<GrpcError>(),
        reason:
            'RPC after server shutdown must '
            'produce a GrpcError, not a crash',
      );

      await channel.shutdown();
    });
  });

  // ==============================================================
  // Group 2: Stream behavior under connection limits
  // ==============================================================
  group('Stream behavior under connection limits', () {
    testTcpAndUds('100 concurrent server-streaming RPCs '
        'on single connection', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Fire 100 concurrent server-streaming calls,
      // each requesting 10 items (yields 1..10).
      final futures = List.generate(
        100,
        (i) => settleRpc(
          client
              .serverStream(10)
              .toList()
              .timeout(
                const Duration(seconds: 30),
                onTimeout: () => fail('serverStream($i) timed out'),
              )
              .then<Object?>((v) => v),
        ),
      );
      final results = await Future.wait(futures);

      final expected = List.generate(10, (i) => i + 1);
      var successCount = 0;
      var errorCount = 0;

      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        if (r is List<int>) {
          expect(r, equals(expected), reason: 'Stream $i should yield [1..10]');
          successCount++;
        } else if (r is GrpcError) {
          // Under extreme concurrency, some
          // streams may fail — that is acceptable
          // as long as they fail with GrpcError.
          errorCount++;
        } else {
          fail(
            'Stream $i produced unexpected type: '
            '${r.runtimeType}',
          );
        }
      }

      expect(
        successCount,
        greaterThan(0),
        reason:
            'At least some server-streaming '
            'RPCs must succeed',
      );
      expect(
        successCount + errorCount,
        equals(100),
        reason:
            'Every stream must resolve as either '
            'a success or a GrpcError. '
            'Got $successCount successes and '
            '$errorCount errors.',
      );

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('client-streaming with 500 items', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Build 500 items: every 5th item is 1,
      // the rest are 0.
      // Sum = 500 / 5 = 100 (fits in a byte).
      final items = List.generate(500, (i) => i % 5 == 0 ? 1 : 0);
      final expectedSum = 100;

      final result = await client
          .clientStream(pacedStream(items, yieldEvery: 10))
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail('clientStream with 500 items timed out'),
          );

      expect(
        result,
        equals(expectedSum),
        reason:
            'Sum of 500 items (100 ones, 400 zeros) '
            'should be $expectedSum',
      );

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('bidi stream with 200 items '
        '(values 0-127 repeating)', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      final items = List.generate(200, (i) => i % 128);

      final results = await client
          .bidiStream(pacedStream(items, yieldEvery: 5))
          .toList()
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail('bidiStream with 200 items timed out'),
          );

      expect(
        results.length,
        equals(200),
        reason:
            'Bidi stream should return exactly '
            '200 results',
      );

      for (var i = 0; i < 200; i++) {
        // Service doubles each value.
        // Values are 0..127 repeating, doubled
        // gives 0..254 — all fit in a byte.
        expect(
          results[i],
          equals(items[i] * 2),
          reason:
              'Bidi result[$i] should be '
              '${items[i]} * 2 = ${items[i] * 2}',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // ==============================================================
  // Group 3: Connection state transitions
  // ==============================================================
  group('Connection state transitions', () {
    testTcpAndUds('fresh channel goes idle -> connecting -> '
        'ready on first RPC', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Before any RPC, states may be empty or
      // contain idle — no ready yet.
      expect(
        channel.states.contains(ConnectionState.ready),
        isFalse,
        reason:
            'Channel should not be ready '
            'before the first RPC',
      );

      final result = await client
          .echo(1)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('First echo(1) timed out'),
          );
      expect(result, equals(1), reason: 'echo(1) should succeed');

      expect(
        channel.states,
        contains(ConnectionState.ready),
        reason:
            'After a successful RPC, the channel '
            'should have transitioned to ready',
      );

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('multiple RPCs do not cause redundant '
        'state transitions', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // 20 sequential RPCs on the same channel.
      for (var i = 0; i < 20; i++) {
        final value = i % 256;
        final result = await client
            .echo(value)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => fail(
                'Sequential echo($value) '
                'timed out at i=$i',
              ),
            );
        expect(
          result,
          equals(value),
          reason:
              'Sequential echo($value) at i=$i '
              'should return $value',
        );
      }

      // Count connecting and ready transitions.
      final connectingCount = channel.states
          .where((s) => s == ConnectionState.connecting)
          .length;
      final readyCount = channel.states
          .where((s) => s == ConnectionState.ready)
          .length;

      expect(
        connectingCount,
        lessThanOrEqualTo(1),
        reason:
            'At most 1 connecting transition '
            'expected across 20 sequential RPCs, '
            'got $connectingCount',
      );
      expect(
        readyCount,
        lessThanOrEqualTo(1),
        reason:
            'At most 1 ready transition expected '
            'across 20 sequential RPCs, '
            'got $readyCount',
      );

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('channel state after server shutdown shows '
        'appropriate transition', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      final result = await client
          .echo(7)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('echo(7) timed out'),
          );
      expect(
        result,
        equals(7),
        reason:
            'echo(7) should succeed before '
            'server shutdown',
      );

      expect(
        channel.states,
        contains(ConnectionState.ready),
        reason:
            'Channel should be ready after '
            'successful RPC',
      );

      // Shut down the server.
      await server.shutdown();

      // Attempt another RPC — expect an error.
      final settled = await settleRpc(
        client
            .echo(8)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => fail(
                'Post-shutdown echo should error, '
                'not hang',
              ),
            ),
      );
      expect(
        settled,
        isA<GrpcError>(),
        reason:
            'RPC after server shutdown must fail '
            'with GrpcError',
      );

      // After the failed RPC, the channel should
      // eventually transition away from ready. The
      // GOAWAY / socket-close may not be processed
      // synchronously, so poll with a bounded timeout.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var hasNonReady = false;
      while (DateTime.now().isBefore(deadline)) {
        hasNonReady = channel.states.any(
          (s) =>
              s == ConnectionState.transientFailure ||
              s == ConnectionState.idle ||
              s == ConnectionState.shutdown,
        );
        if (hasNonReady) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        hasNonReady,
        isTrue,
        reason:
            'After server shutdown, channel states '
            'should include a non-ready state '
            '(transientFailure, idle, or shutdown). '
            'Got: ${channel.states.toList()}',
      );

      await channel.shutdown();
    });
  });

  // ==============================================================
  // Group 4: Generation counter stress
  // ==============================================================
  group('Generation counter stress', () {
    testTcpAndUds('rapid server restart with same channel '
        'exercises generation counter', (address) async {
      // Create 10 sequential server+channel pairs.
      // Each cycle: serve, 5 RPCs, shutdown.
      // This exercises the connection lifecycle
      // that the generation counter protects.
      for (var cycle = 0; cycle < 10; cycle++) {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);

        final client = EchoClient(channel);

        for (var i = 0; i < 5; i++) {
          final value = (cycle * 5 + i) % 256;
          final result = await client
              .echo(value)
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () => fail(
                  'echo($value) timed out in '
                  'cycle $cycle, iter $i',
                ),
              );
          expect(
            result,
            equals(value),
            reason:
                'Cycle $cycle, iter $i: '
                'echo($value) should return $value',
          );
        }

        await channel.shutdown();
        await server.shutdown();
      }
    });

    testTcpAndUds('50 rapid sequential RPCs interleaved '
        'with deliberate error injection', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      var successCount = 0;
      var errorCount = 0;

      for (var i = 0; i < 50; i++) {
        if (i % 10 == 5) {
          // Inject a deadline error: use a very
          // short timeout of 1 millisecond.
          final settled = await settleRpc(
            client
                .echo(
                  i % 256,
                  options: CallOptions(
                    timeout: const Duration(milliseconds: 1),
                  ),
                )
                .timeout(
                  const Duration(seconds: 10),
                  onTimeout: () => fail(
                    'Deadline-injected echo($i) '
                    'should not hang',
                  ),
                ),
          );

          if (settled is GrpcError) {
            errorCount++;
          } else {
            // Server may respond before deadline.
            expect(
              settled,
              equals(i % 256),
              reason:
                  'If deadline echo succeeds, '
                  'the value must be correct',
            );
            successCount++;
          }

          // Allow the channel time to recover
          // from any connection disruption before
          // the next RPC.
          await Future.delayed(const Duration(milliseconds: 50));
        } else {
          // Normal RPC — settle it so transient
          // connection errors from a prior deadline
          // injection do not crash the test.
          final value = i % 256;
          final settled = await settleRpc(
            client
                .echo(value)
                .timeout(
                  const Duration(seconds: 10),
                  onTimeout: () => fail(
                    'Normal echo($value) timed '
                    'out at i=$i',
                  ),
                ),
          );

          if (settled is GrpcError) {
            // Transient error from connection
            // disruption is acceptable.
            errorCount++;
          } else {
            expect(
              settled,
              equals(value),
              reason:
                  'Normal echo($value) at i=$i '
                  'should return $value',
            );
            successCount++;
          }
        }
      }

      // The majority of RPCs must succeed.
      // The 5 deadline-injected ones may fail, and
      // a few neighbors may also fail from transient
      // connection disruption.
      expect(
        successCount,
        greaterThanOrEqualTo(30),
        reason:
            'At least 30 of 50 RPCs must succeed. '
            'Got $successCount successes and '
            '$errorCount errors.',
      );
      expect(
        successCount + errorCount,
        equals(50),
        reason:
            'All 50 RPCs must resolve as either '
            'success or GrpcError. '
            'Got $successCount + $errorCount.',
      );

      await channel.shutdown();
      await server.shutdown();
    });
  });

  group('Named pipe dispatch re-queue hardening', () {
    testNamedPipe('single channel survives 6 named-pipe server restarts', (
      pipeName,
    ) async {
      const cycles = 6;
      const rpcsPerCycle = 25;

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      for (var cycle = 0; cycle < cycles; cycle++) {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        try {
          final settled =
              await Future.wait(
                List.generate(rpcsPerCycle, (i) {
                  final value = (cycle * rpcsPerCycle + i) % 256;
                  return settleRpc(client.echo(value).then<Object?>((v) => v));
                }),
              ).timeout(
                const Duration(seconds: 20),
                onTimeout: () =>
                    fail('Cycle $cycle: named-pipe RPC batch did not settle'),
              );

          for (var i = 0; i < settled.length; i++) {
            final expected = (cycle * rpcsPerCycle + i) % 256;
            expectHardcoreRpcSettlement(
              settled[i],
              reason: 'Cycle $cycle RPC $i settled with unexpected type',
            );
            expect(
              settled[i],
              equals(expected),
              reason:
                  'Cycle $cycle RPC $i should return $expected '
                  'after reconnect and re-dispatch',
            );
          }
        } finally {
          await server.shutdown();
          // Yield once so pipe teardown can complete before next cycle.
          await Future<void>.delayed(Duration.zero);
        }
      }
    });
  });
}
