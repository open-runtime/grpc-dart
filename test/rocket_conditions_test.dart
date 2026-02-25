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

@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

void main() {
  // ==============================================================
  // Group 1: Rocket-grade concurrent unary RPCs
  // ==============================================================

  group('Rocket-grade concurrent unary RPCs', () {
    testTcpAndUds('200 concurrent unary RPCs on single channel', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown();
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() async {
        await channel.shutdown();
      });

      final client = EchoClient(channel);

      final futures = List.generate(200, (i) => client.echo(i % 256));

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail(
          '200 concurrent unary RPCs timed out '
          'after 30 seconds',
        ),
      );

      for (var i = 0; i < 200; i++) {
        expect(
          results[i],
          equals(i % 256),
          reason:
              'RPC $i returned ${results[i]} '
              'but expected ${i % 256}',
        );
      }
    });

    testTcpAndUds('1000 sequential unary RPCs on single channel', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown();
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() async {
        await channel.shutdown();
      });

      final client = EchoClient(channel);

      for (var i = 0; i < 1000; i++) {
        final result = await client.echo(i % 256);
        expect(
          result,
          equals(i % 256),
          reason:
              'Sequential RPC $i returned '
              '$result but expected ${i % 256}',
        );
      }
    });

    testTcpAndUds('5 channels x 50 concurrent RPCs = '
        '250 concurrent RPCs', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown();
      });

      final channels = List.generate(
        5,
        (_) => createTestChannel(address, server.port!),
      );
      for (final ch in channels) {
        addTearDown(() async {
          await ch.shutdown();
        });
      }

      final clients = channels.map((ch) => EchoClient(ch)).toList();

      final allFutures = <Future<int>>[];
      final expectedValues = <int>[];

      for (var c = 0; c < 5; c++) {
        for (var r = 0; r < 50; r++) {
          final value = (c * 50 + r) % 256;
          allFutures.add(clients[c].echo(value));
          expectedValues.add(value);
        }
      }

      expect(
        allFutures.length,
        equals(250),
        reason: 'Should have 250 futures queued',
      );

      final results = await Future.wait(allFutures).timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail(
          '250 concurrent RPCs across 5 channels '
          'timed out after 30 seconds',
        ),
      );

      for (var i = 0; i < 250; i++) {
        expect(
          results[i],
          equals(expectedValues[i]),
          reason:
              'Multi-channel RPC $i returned '
              '${results[i]} but expected '
              '${expectedValues[i]}',
        );
      }
    });
  });

  // ==============================================================
  // Group 2: Rocket-grade concurrent streaming RPCs
  // ==============================================================

  group('Rocket-grade concurrent streaming RPCs', () {
    testTcpAndUds('50 concurrent server-streaming RPCs', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown();
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() async {
        await channel.shutdown();
      });

      final client = EchoClient(channel);

      final streamFutures = List.generate(
        50,
        (_) => client.serverStream(50).toList(),
      );

      final allResults = await Future.wait(streamFutures).timeout(
        const Duration(seconds: 60),
        onTimeout: () => fail(
          '50 concurrent server-streaming RPCs '
          'timed out after 60 seconds',
        ),
      );

      final expected = List.generate(50, (i) => i + 1);

      for (var s = 0; s < 50; s++) {
        expect(
          allResults[s].length,
          equals(50),
          reason:
              'Server stream $s produced '
              '${allResults[s].length} items '
              'instead of 50',
        );
        expect(
          allResults[s],
          equals(expected),
          reason:
              'Server stream $s values '
              'do not match 1..50',
        );
      }
    });

    testTcpAndUds('20 concurrent bidi streams with '
        '100 items each', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown();
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() async {
        await channel.shutdown();
      });

      final client = EchoClient(channel);

      final inputValues = List.generate(100, (i) => i % 128);

      final streamFutures = List.generate(
        20,
        (_) =>
            client.bidiStream(pacedStream(inputValues, yieldEvery: 5)).toList(),
      );

      final allResults = await Future.wait(streamFutures).timeout(
        const Duration(seconds: 60),
        onTimeout: () => fail(
          '20 concurrent bidi streams timed out '
          'after 60 seconds',
        ),
      );

      final expectedValues = inputValues.map((v) => (v * 2) % 256).toList();

      for (var s = 0; s < 20; s++) {
        expect(
          allResults[s].length,
          equals(100),
          reason:
              'Bidi stream $s produced '
              '${allResults[s].length} items '
              'instead of 100',
        );
        expect(
          allResults[s],
          equals(expectedValues),
          reason:
              'Bidi stream $s values do not '
              'match expected doubled values',
        );
      }
    });

    testTcpAndUds('mixed RPC types: 30 unary + '
        '10 server-stream + 10 bidi concurrent', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown();
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() async {
        await channel.shutdown();
      });

      final client = EchoClient(channel);

      // 30 unary RPCs
      final unaryFutures = List.generate(
        30,
        (i) => settleRpc(client.echo(i % 256).then<Object?>((v) => v)),
      );

      // 10 server-streaming RPCs
      final serverStreamFutures = List.generate(
        10,
        (_) =>
            settleRpc(client.serverStream(20).toList().then<Object?>((v) => v)),
      );

      // 10 bidi-streaming RPCs
      final bidiInputValues = List.generate(20, (i) => i % 128);
      final bidiFutures = List.generate(
        10,
        (_) => settleRpc(
          client
              .bidiStream(pacedStream(bidiInputValues, yieldEvery: 5))
              .toList()
              .then<Object?>((v) => v),
        ),
      );

      final allSettled =
          await Future.wait([
            ...unaryFutures,
            ...serverStreamFutures,
            ...bidiFutures,
          ]).timeout(
            const Duration(seconds: 60),
            onTimeout: () => fail(
              'Mixed concurrent RPCs timed out '
              'after 60 seconds',
            ),
          );

      // Verify unary results (first 30)
      for (var i = 0; i < 30; i++) {
        expect(
          allSettled[i],
          isA<int>(),
          reason:
              'Unary RPC $i should return int, '
              'got ${allSettled[i]}',
        );
        expect(
          allSettled[i] as int,
          equals(i % 256),
          reason:
              'Unary RPC $i returned '
              '${allSettled[i]} but expected '
              '${i % 256}',
        );
      }

      // Verify server-stream results (next 10)
      final expectedServerStream = List.generate(20, (i) => i + 1);
      for (var i = 30; i < 40; i++) {
        expect(
          allSettled[i],
          isA<List>(),
          reason:
              'Server-stream RPC ${i - 30} '
              'should return List, '
              'got ${allSettled[i]}',
        );
        final list = allSettled[i] as List;
        expect(
          list.length,
          equals(20),
          reason:
              'Server-stream RPC ${i - 30} '
              'produced ${list.length} items '
              'instead of 20',
        );
        expect(
          list,
          equals(expectedServerStream),
          reason:
              'Server-stream RPC ${i - 30} '
              'values do not match 1..20',
        );
      }

      // Verify bidi results (last 10)
      final expectedBidi = bidiInputValues.map((v) => (v * 2) % 256).toList();
      for (var i = 40; i < 50; i++) {
        expect(
          allSettled[i],
          isA<List>(),
          reason:
              'Bidi RPC ${i - 40} should '
              'return List, '
              'got ${allSettled[i]}',
        );
        final list = allSettled[i] as List;
        expect(
          list.length,
          equals(20),
          reason:
              'Bidi RPC ${i - 40} produced '
              '${list.length} items '
              'instead of 20',
        );
        expect(
          list,
          equals(expectedBidi),
          reason:
              'Bidi RPC ${i - 40} values do '
              'not match expected doubled '
              'values',
        );
      }
    });
  });

  // ==============================================================
  // Group 3: Rapid server restart under load
  // ==============================================================

  group('Rapid server restart under load', () {
    testTcpAndUds('5 rapid server restart cycles with '
        '20 concurrent RPCs each', (address) async {
      for (var cycle = 0; cycle < 5; cycle++) {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);

        final client = EchoClient(channel);

        final futures = List.generate(20, (i) => client.echo(i % 256));

        final results = await Future.wait(futures).timeout(
          const Duration(seconds: 15),
          onTimeout: () => fail(
            'Restart cycle $cycle: 20 concurrent '
            'RPCs timed out after 15 seconds',
          ),
        );

        for (var i = 0; i < 20; i++) {
          expect(
            results[i],
            equals(i % 256),
            reason:
                'Restart cycle $cycle, '
                'RPC $i returned ${results[i]} '
                'but expected ${i % 256}',
          );
        }

        await channel.shutdown();
        await server.shutdown();
      }
    });

    testTcpAndUds('server restart while 30 streams are active', (
      address,
    ) async {
      var server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel1 = createTestChannel(address, server.port!);

      final client1 = EchoClient(channel1);

      // Start 30 server-streaming RPCs that each
      // request 255 items (long-running).
      final streamControllers = <StreamSubscription<int>>[];
      final firstItemCompleters = List.generate(30, (_) => Completer<int>());
      final streamSettled = List.generate(30, (_) => Completer<Object?>());

      for (var s = 0; s < 30; s++) {
        final idx = s;
        final sub = client1
            .serverStream(255)
            .listen(
              (value) {
                if (!firstItemCompleters[idx].isCompleted) {
                  firstItemCompleters[idx].complete(value);
                }
              },
              onError: (Object error) {
                if (!firstItemCompleters[idx].isCompleted) {
                  firstItemCompleters[idx].completeError(error);
                }
                if (!streamSettled[idx].isCompleted) {
                  streamSettled[idx].complete(error);
                }
              },
              onDone: () {
                if (!streamSettled[idx].isCompleted) {
                  streamSettled[idx].complete(null);
                }
              },
            );
        streamControllers.add(sub);
      }

      // Wait for first items on all 30 streams.
      final firstItems =
          await Future.wait(
            firstItemCompleters.map(
              (c) => settleRpc(c.future.then<Object?>((v) => v)),
            ),
          ).timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail(
              'Waiting for first items on 30 streams '
              'timed out after 30 seconds',
            ),
          );

      // Verify at least some first items arrived.
      final successfulFirst = firstItems.whereType<int>().length;
      expect(
        successfulFirst,
        greaterThan(0),
        reason:
            'At least one stream should have '
            'received its first item before '
            'shutdown',
      );

      // Shut down the server while streams active.
      await server.shutdown();

      // All 30 streams must settle (not hang).
      await Future.wait(streamSettled.map((c) => c.future)).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail(
          'Streams did not settle within '
          '15 seconds after server shutdown',
        ),
      );

      // Cancel all subscriptions.
      for (final sub in streamControllers) {
        await sub.cancel();
      }
      await channel1.shutdown();

      // Restart server on same address.
      server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown();
      });

      final channel2 = createTestChannel(address, server.port!);
      addTearDown(() async {
        await channel2.shutdown();
      });

      final client2 = EchoClient(channel2);

      // Fire 10 fresh unary RPCs.
      final freshFutures = List.generate(10, (i) => client2.echo(i % 256));
      final freshResults = await Future.wait(freshFutures).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail(
          'Fresh RPCs after restart timed out '
          'after 15 seconds',
        ),
      );

      for (var i = 0; i < 10; i++) {
        expect(
          freshResults[i],
          equals(i % 256),
          reason:
              'Post-restart RPC $i returned '
              '${freshResults[i]} but expected '
              '${i % 256}',
        );
      }
    });
  });

  // ==============================================================
  // Group 4: Sustained throughput stress
  // ==============================================================

  group('Sustained throughput stress', () {
    testTcpAndUds('500 rapid sequential RPCs with '
        'varying payload', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown();
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() async {
        await channel.shutdown();
      });

      final client = EchoClient(channel);

      for (var i = 0; i < 500; i++) {
        if (i % 3 == 0) {
          // Unary echo
          final result = await client.echo(i % 256);
          expect(
            result,
            equals(i % 256),
            reason:
                'Throughput RPC $i (echo) '
                'returned $result but expected '
                '${i % 256}',
          );
        } else if (i % 3 == 1) {
          // Client stream with 3 values (sum must fit in a
          // single byte since EchoClient serializes int as [value]).
          final values = [(i % 80), ((i + 1) % 80), ((i + 2) % 80)];
          final result = await client.clientStream(Stream.fromIterable(values));
          final expectedSum = values.fold<int>(0, (a, b) => a + b);
          expect(
            result,
            equals(expectedSum),
            reason:
                'Throughput RPC $i '
                '(clientStream) returned '
                '$result but expected '
                '$expectedSum',
          );
        } else {
          // Echo bytes with varying size
          final size = (i % 50 + 1) * 100;
          final payload = Uint8List(size);
          for (var b = 0; b < size; b++) {
            payload[b] = b % 256;
          }
          final result = await client.echoBytes(payload);
          expect(
            result.length,
            equals(size),
            reason:
                'Throughput RPC $i '
                '(echoBytes) returned '
                '${result.length} bytes but '
                'expected $size',
          );
          for (var b = 0; b < size; b++) {
            expect(
              result[b],
              equals(b % 256),
              reason:
                  'Throughput RPC $i '
                  '(echoBytes) byte $b '
                  'mismatch: ${result[b]} '
                  'vs ${b % 256}',
            );
          }
        }
      }
    });

    testTcpAndUds('100 concurrent large payload echoes '
        '(10KB each)', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown();
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() async {
        await channel.shutdown();
      });

      final client = EchoClient(channel);

      final payloads = List.generate(100, (i) {
        final data = Uint8List(10240);
        for (var b = 0; b < 10240; b++) {
          data[b] = i % 256;
        }
        return data;
      });

      final futures = List.generate(100, (i) => client.echoBytes(payloads[i]));

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 60),
        onTimeout: () => fail(
          '100 concurrent 10KB echoes timed out '
          'after 60 seconds',
        ),
      );

      for (var i = 0; i < 100; i++) {
        expect(
          results[i].length,
          equals(10240),
          reason:
              'Large echo $i returned '
              '${results[i].length} bytes but '
              'expected 10240',
        );
        for (var b = 0; b < 10240; b++) {
          if (results[i][b] != i % 256) {
            fail(
              'Large echo $i byte $b mismatch: '
              '${results[i][b]} vs ${i % 256}',
            );
          }
        }
      }
    });
  });

  group('Named pipe rocket-grade stress', () {
    testNamedPipe('mixed high-concurrency workloads stay lossless', (
      pipeName,
    ) async {
      const unaryCount = 120;
      const serverStreamCount = 24;
      const bidiCount = 24;
      const streamItems = 40;

      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      final unarySettled = List.generate(
        unaryCount,
        (i) => settleRpc(client.echo(i % 256).then<Object?>((v) => v)),
      );
      final serverStreamSettled = List.generate(
        serverStreamCount,
        (_) => settleRpc(
          client.serverStream(streamItems).toList().then<Object?>((v) => v),
        ),
      );
      final bidiInput = List.generate(streamItems, (i) => i % 128);
      final bidiSettled = List.generate(
        bidiCount,
        (_) => settleRpc(
          client
              .bidiStream(pacedStream(bidiInput, yieldEvery: 4))
              .toList()
              .then<Object?>((v) => v),
        ),
      );

      final settled =
          await Future.wait([
            ...unarySettled,
            ...serverStreamSettled,
            ...bidiSettled,
          ]).timeout(
            const Duration(seconds: 90),
            onTimeout: () =>
                fail('Named-pipe mixed rocket workload did not settle in time'),
          );

      for (var i = 0; i < unaryCount; i++) {
        expectHardcoreRpcSettlement(
          settled[i],
          reason: 'Named-pipe unary RPC $i settled unexpectedly',
        );
        expect(
          settled[i],
          equals(i % 256),
          reason:
              'Named-pipe unary RPC $i returned ${settled[i]}, '
              'expected ${i % 256}',
        );
      }

      final expectedServerStream = List.generate(streamItems, (i) => i + 1);
      for (var i = 0; i < serverStreamCount; i++) {
        final idx = unaryCount + i;
        expectHardcoreRpcSettlement(
          settled[idx],
          reason: 'Named-pipe server-stream RPC $i settled unexpectedly',
        );
        expect(
          settled[idx],
          equals(expectedServerStream),
          reason: 'Named-pipe server-stream RPC $i returned bad payload',
        );
      }

      final expectedBidi = bidiInput.map((v) => (v * 2) % 256).toList();
      for (var i = 0; i < bidiCount; i++) {
        final idx = unaryCount + serverStreamCount + i;
        expectHardcoreRpcSettlement(
          settled[idx],
          reason: 'Named-pipe bidi RPC $i settled unexpectedly',
        );
        expect(
          settled[idx],
          equals(expectedBidi),
          reason: 'Named-pipe bidi RPC $i returned bad payload',
        );
      }
    });
  });
}
