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
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

// ================================================================
// Helpers
// ================================================================

/// Encodes chunkCount and chunkSize as 8-byte big-endian
/// for the serverStreamBytes service method.
List<int> _encodeStreamBytesRequest(int chunkCount, int chunkSize) {
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
  // Group 1: Transport sink guard under server shutdown
  // ==============================================================

  group('Transport sink guard under server shutdown', () {
    testTcpAndUds('server shutdown during active bidi data flow'
        ' does not crash', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Start 10 bidi streams, each fed by a
      // controller so we can pump data freely.
      final controllers = List.generate(10, (_) => StreamController<int>());
      final futures = <Future<Object?>>[];
      for (final ctrl in controllers) {
        futures.add(
          settleRpc(
            client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v),
          ),
        );
      }

      // Pump ~20 items per stream with minimal delay
      // so data is in-flight when we shut down.
      for (var i = 0; i < 20; i++) {
        for (final ctrl in controllers) {
          if (!ctrl.isClosed) {
            ctrl.add(i % 128);
          }
        }
        await Future.delayed(const Duration(milliseconds: 1));
      }

      // Shut down the server while data is queued.
      await server.shutdown();

      // Close all controllers so streams can finish.
      for (final ctrl in controllers) {
        await ctrl.close().catchError((_) {});
      }

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out waiting for streams'),
      );

      expect(
        results.length,
        equals(10),
        reason: 'All 10 bidi streams must settle',
      );
    });

    testTcpAndUds('server shutdown during large payload transfer', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // 64 KB payloads exceed the HTTP/2 default flow
      // control window (65535 bytes) so they will be
      // queued in the outgoing pipeline.
      final payload = Uint8List(65536);
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 5; i++) {
        futures.add(
          settleRpc(client.echoBytes(payload).then<Object?>((v) => v)),
        );
      }

      // Give the RPCs a moment to start transmitting.
      await Future.delayed(const Duration(milliseconds: 20));

      // Shut down the server while large payloads
      // are in the outgoing buffer.
      await server.shutdown();

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out waiting for RPCs'),
      );

      expect(
        results.length,
        equals(5),
        reason: 'All 5 echoBytes RPCs must settle',
      );
    });

    testTcpAndUds('rapid terminate during bidiStreamBytes'
        ' with 32KB chunks', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // 32 KB chunks fed via pacedStream.
      final chunk = Uint8List(32768);
      final chunks = List.generate(10, (_) => chunk);

      final controllers = <StreamController<List<int>>>[];
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 10; i++) {
        final ctrl = StreamController<List<int>>();
        controllers.add(ctrl);
        futures.add(
          settleRpc(
            client
                .bidiStreamBytes(ctrl.stream)
                .toList()
                .then<Object?>((v) => v),
          ),
        );
      }

      // Feed each controller with paced chunks.
      final feedFutures = <Future<void>>[];
      for (final ctrl in controllers) {
        feedFutures.add(() async {
          await for (final c in pacedStream(chunks, yieldEvery: 1)) {
            if (ctrl.isClosed) break;
            ctrl.add(c);
          }
        }());
      }

      // Wait for first response on all 10 streams
      // by giving them a brief window.
      await Future.delayed(const Duration(milliseconds: 50));

      // Shut down while 32 KB chunks are in flight.
      await server.shutdown();

      // Close controllers so streams finish.
      for (final ctrl in controllers) {
        await ctrl.close().catchError((_) {});
      }

      // Wait for all feed futures too.
      await Future.wait(feedFutures).catchError((_) => <void>[]);

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out waiting for streams'),
      );

      expect(
        results.length,
        equals(10),
        reason: 'All 10 bidiStreamBytes streams must settle',
      );
    });

    testTcpAndUds('client sends data after server has initiated'
        ' shutdown', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Start 5 bidi streams via StreamControllers.
      final controllers = List.generate(5, (_) => StreamController<int>());
      final futures = <Future<Object?>>[];
      for (final ctrl in controllers) {
        futures.add(
          settleRpc(
            client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v),
          ),
        );
      }

      // Send 1 item per stream and wait for it to
      // be processed.
      for (final ctrl in controllers) {
        ctrl.add(1);
      }
      await Future.delayed(const Duration(milliseconds: 50));

      // Initiate server shutdown.
      final shutdownFuture = server.shutdown();

      // Immediately pump 10 more items into each
      // controller — data arriving at a transport
      // that is already shutting down.
      for (var i = 0; i < 10; i++) {
        for (final ctrl in controllers) {
          if (!ctrl.isClosed) {
            ctrl.add((i + 2) % 128);
          }
        }
      }

      await shutdownFuture;

      // Close controllers.
      for (final ctrl in controllers) {
        await ctrl.close().catchError((_) {});
      }

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out waiting for streams'),
      );

      expect(
        results.length,
        equals(5),
        reason:
            'All 5 bidi streams must settle '
            'without crash',
      );
    });
  });

  // ==============================================================
  // Group 2: Concurrent terminate races
  // ==============================================================

  group('Concurrent terminate races', () {
    testTcpAndUds('20 concurrent streams with interleaved server'
        ' and channel shutdown', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Start 20 server-streaming RPCs.
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 20; i++) {
        futures.add(
          settleRpc(client.serverStream(100).toList().then<Object?>((v) => v)),
        );
      }

      // Wait for first items on all 20.
      await Future.delayed(const Duration(milliseconds: 100));

      // Fire server.shutdown() AND channel.shutdown()
      // simultaneously — maximum terminate pressure.
      await Future.wait([server.shutdown(), channel.shutdown()]).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out during dual shutdown'),
      );

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out waiting for streams'),
      );

      expect(
        results.length,
        equals(20),
        reason:
            'All 20 server-streaming RPCs must '
            'settle without crashes',
      );
    });

    testTcpAndUds('channel.shutdown() while server is streaming'
        ' large payloads', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Each serverStreamBytes yields 50 chunks of 8 KB.
      // Request: 8-byte big-endian [chunkCount, chunkSize].
      final request = _encodeStreamBytesRequest(50, 8192);
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 10; i++) {
        futures.add(
          settleRpc(
            client.serverStreamBytes(request).toList().then<Object?>((v) => v),
          ),
        );
      }

      // Wait for first chunk on all 10.
      await Future.delayed(const Duration(milliseconds: 50));

      // Client-initiated teardown while the server
      // is still yielding data into the outgoing sink.
      await channel.shutdown().timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out during channel shutdown'),
      );

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out waiting for streams'),
      );

      expect(
        results.length,
        equals(10),
        reason:
            'All 10 serverStreamBytes RPCs must '
            'settle without StateError',
      );

      await server.shutdown();
    });

    testTcpAndUds('10 concurrent echoBytes with immediate channel'
        ' teardown', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Fire 10 echoBytes RPCs with 32 KB payloads.
      // Do NOT await — immediately tear down.
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 10; i++) {
        futures.add(
          settleRpc(client.echoBytes(Uint8List(32768)).then<Object?>((v) => v)),
        );
      }

      // Immediately shut down the channel — RPCs may
      // not even complete the HTTP/2 handshake.
      await channel.shutdown().timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out during channel shutdown'),
      );

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out waiting for RPCs'),
      );

      expect(
        results.length,
        equals(10),
        reason:
            'All 10 echoBytes RPCs must settle '
            '(success or error), no crashes',
      );

      await server.shutdown();
    });
  });

  // ==============================================================
  // Group 3: Error propagation through guarded sinks
  // ==============================================================

  group('Error propagation through guarded sinks', () {
    testTcpAndUds('RPC errors do not crash when sink is closing', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Start 10 bidi streams.
      final controllers = List.generate(10, (_) => StreamController<int>());
      final futures = <Future<Object?>>[];
      for (final ctrl in controllers) {
        futures.add(
          settleRpc(
            client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v),
          ),
        );
      }

      // Send some data.
      for (final ctrl in controllers) {
        ctrl.add(1);
        ctrl.add(2);
      }
      await Future.delayed(const Duration(milliseconds: 30));

      // Push an error into each controller AND
      // simultaneously shut down the server.
      final shutdownFuture = server.shutdown();
      for (final ctrl in controllers) {
        if (!ctrl.isClosed) {
          ctrl.addError(Exception('deliberate client error'));
          ctrl.close().ignore();
        }
      }

      await shutdownFuture;

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('Timed out waiting for streams'),
      );

      expect(
        results.length,
        equals(10),
        reason:
            'All 10 streams must settle without '
            'unhandled exceptions',
      );
    });

    testTcpAndUds('sustained throughput then abrupt terminate'
        ' (50 streams x 50 items)', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // 50 bidi streams, each fed with a pacedStream
      // of 50 items (values 0-127).
      final items = List.generate(50, (i) => i % 128);
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 50; i++) {
        final stream = pacedStream(items, yieldEvery: 1);
        futures.add(
          settleRpc(client.bidiStream(stream).toList().then<Object?>((v) => v)),
        );
      }

      // Let data flow for a bit.
      await Future.delayed(const Duration(milliseconds: 100));

      // Abrupt terminate while sustained throughput
      // is in progress.
      await server.shutdown();

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail('Timed out waiting for streams'),
      );

      expect(
        results.length,
        equals(50),
        reason: 'All 50 bidi streams must settle',
      );
    });

    testTcpAndUds('repeated connect-transfer-terminate cycles'
        ' (10 cycles)', (address) async {
      for (var cycle = 0; cycle < 10; cycle++) {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);

        final client = EchoClient(channel);

        // Start 5 bidi streams and pump 20 items
        // into each.
        final controllers = List.generate(5, (_) => StreamController<int>());
        final futures = <Future<Object?>>[];
        for (final ctrl in controllers) {
          futures.add(
            settleRpc(
              client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v),
            ),
          );
        }

        // Pump 20 items per stream.
        for (var i = 0; i < 20; i++) {
          for (final ctrl in controllers) {
            if (!ctrl.isClosed) {
              ctrl.add(i % 128);
            }
          }
          if (i % 5 == 0) {
            await Future.delayed(const Duration(milliseconds: 1));
          }
        }

        // Shut down server while data is flowing.
        await server.shutdown();

        // Close controllers.
        for (final ctrl in controllers) {
          await ctrl.close().catchError((_) {});
        }

        final results = await Future.wait(futures).timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('Timed out on cycle $cycle'),
        );

        expect(
          results.length,
          equals(5),
          reason: 'Cycle $cycle: all 5 streams must settle',
        );

        // Clean shutdown of the channel.
        await channel.shutdown();
      }
    });
  });
}
