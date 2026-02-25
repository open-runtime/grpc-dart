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

// ================================================================
// Helpers (unique to this file)
// ================================================================

/// Returns the total handler count across all connections.
int totalHandlerCount(ConnectionServer server) {
  return server.handlers.values.fold<int>(0, (sum, list) => sum + list.length);
}

/// Asserts every handler list in the map is empty.
void expectHandlersEmpty(ConnectionServer server, {String? reason}) {
  final msg = reason ?? 'All handler lists must be empty after shutdown';
  expect(
    server.handlers.values.every((list) => list.isEmpty),
    isTrue,
    reason: msg,
  );
}

/// Encodes chunkCount and chunkSize as 8-byte big-endian.
List<int> encodeStreamBytesRequest(int chunkCount, int chunkSize) {
  final bd = ByteData(8);
  bd.setUint32(0, chunkCount);
  bd.setUint32(4, chunkSize);
  return bd.buffer.asUint8List();
}

// ================================================================
// Tests
// ================================================================

void main() {
  // ==============================================================
  // Group 1: Shutdown propagation at scale
  // ==============================================================
  group('Shutdown propagation at scale', () {
    testTcpAndUds('shutdown with 50 active streams empties '
        'handler map completely', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Start 50 server-streaming RPCs.
      // serverStream(255) yields 255 items with 1ms
      // delays = ~255ms, plenty of time.
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 50; i++) {
        futures.add(
          settleRpc(client.serverStream(255).toList().then<Object?>((v) => v)),
        );
      }

      await waitForHandlers(
        server,
        minCount: 50,
        timeout: const Duration(seconds: 10),
        reason: '50 handlers must be registered',
      );

      expect(
        totalHandlerCount(server),
        greaterThanOrEqualTo(50),
        reason: 'Handler map must track >= 50 entries',
      );

      await server.shutdown();

      expectHandlersEmpty(
        server,
        reason:
            'All handlers must be cleaned up '
            'after shutdown with 50 streams',
      );

      // All 50 streams must settle.
      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('50 streams did not settle'),
      );
      expect(results, hasLength(50));
    });

    testTcpAndUds('shutdown with 3 clients x 20 streams = '
        '60 concurrent streams', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channels = <TestClientChannel>[];
      final clients = <EchoClient>[];
      for (var c = 0; c < 3; c++) {
        final ch = createTestChannel(address, server.port!);
        channels.add(ch);
        clients.add(EchoClient(ch));
      }
      addTearDown(() async {
        for (final ch in channels) {
          await ch.shutdown();
        }
      });

      final futures = <Future<Object?>>[];
      for (final client in clients) {
        for (var i = 0; i < 20; i++) {
          futures.add(
            settleRpc(
              client.serverStream(255).toList().then<Object?>((v) => v),
            ),
          );
        }
      }

      await waitForHandlers(
        server,
        minCount: 60,
        timeout: const Duration(seconds: 10),
        reason: '60 handlers must be registered',
      );

      await server.shutdown();

      expectHandlersEmpty(
        server,
        reason:
            'Handler map must be empty after '
            'multi-connection shutdown',
      );

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('60 streams did not settle'),
      );
      expect(results, hasLength(60));
    });

    testTcpAndUds('shutdown propagates through mixed '
        'payload sizes', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);
      final futures = <Future<Object?>>[];

      // 10 tiny unary echo RPCs.
      for (var i = 0; i < 10; i++) {
        futures.add(settleRpc(client.echo(i % 256).then<Object?>((v) => v)));
      }

      // 5 echoBytes with 1KB payloads.
      for (var i = 0; i < 5; i++) {
        futures.add(
          settleRpc(client.echoBytes(Uint8List(1024)).then<Object?>((v) => v)),
        );
      }

      // 5 echoBytes with 32KB payloads.
      for (var i = 0; i < 5; i++) {
        futures.add(
          settleRpc(
            client.echoBytes(Uint8List(32 * 1024)).then<Object?>((v) => v),
          ),
        );
      }

      // 5 echoBytes with 64KB payloads (exceeds
      // HTTP/2 default window).
      for (var i = 0; i < 5; i++) {
        futures.add(
          settleRpc(
            client.echoBytes(Uint8List(64 * 1024)).then<Object?>((v) => v),
          ),
        );
      }

      // 5 server-streaming RPCs.
      for (var i = 0; i < 5; i++) {
        futures.add(
          settleRpc(client.serverStream(100).toList().then<Object?>((v) => v)),
        );
      }

      // Wait for streaming handlers. Unary RPCs (echo, echoBytes) may
      // complete before the handler map is checked, so only the 5 long-
      // running serverStream RPCs are reliably present.
      await waitForHandlers(
        server,
        minCount: 5,
        timeout: const Duration(seconds: 10),
        reason:
            'At least 5 streaming handlers required '
            'for mixed payload test',
      );

      await server.shutdown();

      // All 30 must settle without crashes.
      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('Mixed payload RPCs did not settle'),
      );
      expect(results, hasLength(30));
    });

    testTcpAndUds('shutdown during serverStreamBytes with '
        'sustained data flow', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Request: 100 chunks of 4KB each.
      final request = encodeStreamBytesRequest(100, 4096);

      // Start 10 streaming RPCs, each sending
      // 100 x 4KB chunks.
      final firstChunkCompleters = List.generate(10, (_) => Completer<void>());
      final futures = <Future<Object?>>[];

      for (var i = 0; i < 10; i++) {
        final idx = i;
        futures.add(
          settleRpc(
            client
                .serverStreamBytes(request)
                .fold(0, (count, chunk) {
                  if (!firstChunkCompleters[idx].isCompleted) {
                    firstChunkCompleters[idx].complete();
                  }
                  return count + 1;
                })
                .then<Object?>((v) => v),
          ),
        );
      }

      // Wait for first chunk on all 10 streams.
      await Future.wait(firstChunkCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'First chunks not received on all 10 '
          'streams',
        ),
      );

      await server.shutdown();

      expectHandlersEmpty(
        server,
        reason:
            'Handler map must be empty after '
            'serverStreamBytes shutdown',
      );

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('serverStreamBytes RPCs did not settle'),
      );
      expect(results, hasLength(10));
    });
  });

  // ==============================================================
  // Group 2: Shutdown timing edge cases
  // ==============================================================
  group('Shutdown timing edge cases', () {
    testTcpAndUds('immediate shutdown after serve (no RPCs)', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      // Immediately shut down — no RPCs issued.
      await server.shutdown().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Immediate shutdown timed out'),
      );

      // Prove we can start a new server on the
      // same address. For TCP, port 0 assigns a new
      // port; for UDS, rebinding the same socket path
      // proves the old server released it.
      final server2 = Server.create(services: [EchoService()]);
      await server2.serve(address: address, port: 0);
      addTearDown(() => server2.shutdown());

      expect(
        server2.port,
        isNotNull,
        reason:
            'Second server must start successfully '
            'after first server shutdown',
      );
      await server2.shutdown();
    });

    testTcpAndUds('shutdown during connection handshake', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Fire 20 RPCs on a fresh channel without
      // waiting for any to complete.
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 20; i++) {
        futures.add(settleRpc(client.echo(i % 256).then<Object?>((v) => v)));
      }

      // Shut down immediately — some RPCs may be
      // in handshake, some may have started.
      await server.shutdown();

      // All 20 must settle (succeed or error).
      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('Handshake-phase RPCs did not settle'),
      );
      expect(results, hasLength(20));
    });

    testTcpAndUds('shutdown with only completed RPCs '
        '(no active handlers)', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // 10 sequential unary RPCs, all complete.
      for (var i = 0; i < 10; i++) {
        final result = await client.echo(i % 256);
        expect(result, equals(i % 256));
      }

      // Give handlers time to be removed.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        totalHandlerCount(server),
        equals(0),
        reason:
            'All unary RPCs completed; handler '
            'map must be empty',
      );

      // Shutdown should complete instantly.
      await server.shutdown().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'Shutdown after completed RPCs '
          'timed out',
        ),
      );
    });

    testTcpAndUds('shutdown races with RPC completion', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Start 30 streams that yield only 5 items
      // each (~5ms total).
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 30; i++) {
        futures.add(
          settleRpc(client.serverStream(5).toList().then<Object?>((v) => v)),
        );
      }

      // Wait 20ms — some may have completed already,
      // some still active.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await server.shutdown();

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('Race-with-completion RPCs did not settle'),
      );
      expect(results, hasLength(30));
    });
  });

  // ==============================================================
  // Group 3: Cascading shutdown scenarios
  // ==============================================================
  group('Cascading shutdown scenarios', () {
    testTcpAndUds('server shutdown then client reconnect to '
        'new server then success', (address) async {
      // --- Server 1 ---
      final server1 = Server.create(services: [EchoService()]);
      await server1.serve(address: address, port: 0);

      final channel1 = createTestChannel(address, server1.port!);
      final client1 = EchoClient(channel1);

      for (var i = 0; i < 10; i++) {
        final result = await client1.echo(i % 256);
        expect(result, equals(i % 256));
      }

      await channel1.shutdown();
      await server1.shutdown();

      // --- Server 2 on same address, new port ---
      final server2 = Server.create(services: [EchoService()]);
      await server2.serve(address: address, port: 0);

      final channel2 = createTestChannel(address, server2.port!);
      final client2 = EchoClient(channel2);

      for (var i = 0; i < 10; i++) {
        final result = await client2.echo(i % 256);
        expect(result, equals(i % 256));
      }

      await channel2.shutdown();
      await server2.shutdown();
    });

    testTcpAndUds('12 rapid shutdown cycles with increasing '
        'stream counts', (address) async {
      for (var cycle = 0; cycle < 12; cycle++) {
        final streamCount = () {
          final raw = 2 << cycle; // 2,4,8,...4096
          return raw > 64 ? 64 : raw;
        }();

        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);
        final client = EchoClient(channel);

        // Start streams.
        final futures = <Future<Object?>>[];
        for (var s = 0; s < streamCount; s++) {
          futures.add(
            settleRpc(client.serverStream(50).toList().then<Object?>((v) => v)),
          );
        }

        // Wait for at least one chunk of data.
        await waitForHandlers(
          server,
          minCount: 1,
          timeout: const Duration(seconds: 10),
          reason:
              'Cycle $cycle: at least 1 handler '
              'must be registered',
        );

        await server.shutdown();

        expectHandlersEmpty(
          server,
          reason:
              'Cycle $cycle ($streamCount streams'
              '): handler map must be empty',
        );

        await Future.wait(futures).timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Cycle $cycle: streams did not settle'),
        );

        await channel.shutdown();
      }
    });

    testTcpAndUds('shutdown with data flowing in both '
        'directions simultaneously', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      final controllers = <StreamController<int>>[];
      final timers = <Timer>[];
      final futures = <Future<Object?>>[];

      // Start 20 bidi streams.
      for (var i = 0; i < 20; i++) {
        final ctrl = StreamController<int>();
        controllers.add(ctrl);

        // Pump items every 2ms.
        var counter = 0;
        final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
          if (!ctrl.isClosed) {
            ctrl.add(counter % 128);
            counter++;
          }
        });
        timers.add(timer);

        futures.add(
          settleRpc(
            client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v),
          ),
        );
      }

      // Let data flow for 50ms.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Shutdown while data is in flight.
      await server.shutdown();

      // Cancel all timers and close controllers.
      for (final t in timers) {
        t.cancel();
      }
      for (final c in controllers) {
        if (!c.isClosed) {
          await c.close();
        }
      }

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'Bidi streams did not settle after '
          'shutdown',
        ),
      );
      expect(results, hasLength(20));
    });
  });

  // ==============================================================
  // Group 4: Handler map integrity
  // ==============================================================
  group('Handler map integrity', () {
    testTcpAndUds('handler map tracks all RPC types correctly', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      final futures = <Future<Object?>>[];

      // 5 unary echo RPCs.
      for (var i = 0; i < 5; i++) {
        futures.add(settleRpc(client.echo(i % 256).then<Object?>((v) => v)));
      }

      // 5 server-streaming RPCs.
      for (var i = 0; i < 5; i++) {
        futures.add(
          settleRpc(client.serverStream(255).toList().then<Object?>((v) => v)),
        );
      }

      // 5 client-streaming RPCs (via controllers,
      // don't close yet).
      final clientStreamControllers = <StreamController<int>>[];
      for (var i = 0; i < 5; i++) {
        final ctrl = StreamController<int>();
        clientStreamControllers.add(ctrl);
        // Send at least one item so the handler
        // gets created.
        ctrl.add(i % 256);
        futures.add(
          settleRpc(client.clientStream(ctrl.stream).then<Object?>((v) => v)),
        );
      }

      // 5 bidi RPCs (via controllers, send 1 item).
      final bidiControllers = <StreamController<int>>[];
      for (var i = 0; i < 5; i++) {
        final ctrl = StreamController<int>();
        bidiControllers.add(ctrl);
        ctrl.add(i % 128);
        futures.add(
          settleRpc(
            client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v),
          ),
        );
      }

      // Wait for at least 15 streaming handlers.
      await waitForHandlers(
        server,
        minCount: 15,
        timeout: const Duration(seconds: 10),
        reason:
            'At least 15 handlers for mixed '
            'RPC types',
      );

      expect(
        totalHandlerCount(server),
        greaterThan(0),
        reason:
            'Handler map must have entries before '
            'shutdown',
      );

      await server.shutdown();

      expectHandlersEmpty(
        server,
        reason:
            'Handler map must be completely empty '
            'after mixed-type shutdown',
      );

      // Close all controllers.
      for (final c in clientStreamControllers) {
        if (!c.isClosed) {
          await c.close();
        }
      }
      for (final c in bidiControllers) {
        if (!c.isClosed) {
          await c.close();
        }
      }

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('Mixed RPC types did not settle'),
      );
      expect(results, hasLength(20));
    });

    testTcpAndUds('handler map empty after 100 sequential RPCs', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // 100 sequential unary echo RPCs.
      for (var i = 0; i < 100; i++) {
        final result = await client.echo(i % 256);
        expect(result, equals(i % 256));
      }

      // Give time for handler cleanup.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        totalHandlerCount(server),
        equals(0),
        reason:
            'Handler map must be empty after 100 '
            'completed sequential RPCs',
      );

      await server.shutdown();
    });

    testTcpAndUds('handler map tracks concurrent streams '
        'from multiple connections', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() async {
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Server shutdown timed out'),
        );
      });

      final channels = <TestClientChannel>[];
      final clients = <EchoClient>[];
      for (var c = 0; c < 5; c++) {
        final ch = createTestChannel(address, server.port!);
        channels.add(ch);
        clients.add(EchoClient(ch));
      }
      addTearDown(() async {
        for (final ch in channels) {
          await ch.shutdown();
        }
      });

      final futures = <Future<Object?>>[];
      for (final client in clients) {
        for (var i = 0; i < 10; i++) {
          futures.add(
            settleRpc(client.serverStream(50).toList().then<Object?>((v) => v)),
          );
        }
      }

      // 5 clients x 10 streams = 50 total.
      await waitForHandlers(
        server,
        minCount: 50,
        timeout: const Duration(seconds: 10),
        reason:
            '50 handlers across 5 connections '
            'must be registered',
      );

      // Verify handler map has entries under
      // multiple connection keys.
      expect(
        server.handlers.keys.length,
        greaterThan(0),
        reason:
            'Handler map must have connection '
            'keys',
      );

      await server.shutdown();

      // ALL entries under ALL connection keys empty.
      for (final entry in server.handlers.entries) {
        expect(
          entry.value,
          isEmpty,
          reason:
              'Handler list for connection '
              '${entry.key} must be empty after '
              'shutdown',
        );
      }

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('Multi-connection streams did not settle'),
      );
      expect(results, hasLength(50));
    });
  });
}
