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
import 'dart:io';
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
  expect(server.handlers.values.every((list) => list.isEmpty), isTrue, reason: msg);
}

/// Waits until all handler lists are empty.
Future<void> waitForNoHandlers(
  ConnectionServer server, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'Handler map did not fully drain',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (totalHandlerCount(server) == 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail(reason);
}

/// Asserts that every settled RPC result is payload data or explicit GrpcError.
void expectHardcoreSettlements(List<Object?> results, {required String reasonPrefix}) {
  for (var i = 0; i < results.length; i++) {
    expectHardcoreRpcSettlement(results[i], reason: '$reasonPrefix (index=$i, type=${results[i].runtimeType})');
  }
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
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channel = createTestChannel(address, server.port!);

            final client = EchoClient(channel);
            final controllers = <StreamController<int>>[];

            // Start 50 bidi streams and keep controllers open so handlers remain
            // active until shutdown.
            final futures = <Future<Object?>>[];
            for (var i = 0; i < 50; i++) {
              final ctrl = StreamController<int>();
              controllers.add(ctrl);
              ctrl.add(i % 128);
              futures.add(settleRpc(client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v)));
            }

            await waitForHandlers(
              server,
              minCount: 50,
              timeout: const Duration(seconds: 30),
              reason: '50 handlers must be registered',
            );

            expect(totalHandlerCount(server), equals(50), reason: 'Handler map must track exactly 50 active handlers');

            await server.shutdown();

            for (final ctrl in controllers) {
              if (!ctrl.isClosed) {
                await ctrl.close();
              }
            }

            expectHandlersEmpty(
              server,
              reason:
                  'All handlers must be cleaned up '
                  'after shutdown with 50 streams',
            );

            // All 50 streams must settle.
            final results = await Future.wait(
              futures,
            ).timeout(const Duration(seconds: 10), onTimeout: () => fail('50 streams did not settle'));
            expect(results, hasLength(50));
            expectHardcoreSettlements(results, reasonPrefix: 'shutdown with 50 active streams');

            await channel.terminate();
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during 50-stream shutdown. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('shutdown with 3 clients x 20 streams = '
        '60 concurrent streams', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channels = <TestClientChannel>[];
            final clients = <EchoClient>[];
            for (var c = 0; c < 3; c++) {
              final ch = createTestChannel(address, server.port!);
              channels.add(ch);
              clients.add(EchoClient(ch));
            }
            final controllers = <StreamController<int>>[];

            final futures = <Future<Object?>>[];
            for (var clientIndex = 0; clientIndex < clients.length; clientIndex++) {
              final client = clients[clientIndex];
              for (var i = 0; i < 20; i++) {
                final ctrl = StreamController<int>();
                controllers.add(ctrl);
                ctrl.add((clientIndex * 20 + i) % 128);
                futures.add(settleRpc(client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v)));
              }
              // Let the server process each batch before creating the next one.
              await Future<void>.delayed(Duration.zero);
            }

            await waitForHandlers(
              server,
              minCount: 60,
              timeout: const Duration(seconds: 30),
              reason: '60 handlers must be registered',
            );

            expect(totalHandlerCount(server), equals(60), reason: 'Handler map must track exactly 60 active handlers');

            await server.shutdown();

            for (final ctrl in controllers) {
              if (!ctrl.isClosed) {
                await ctrl.close();
              }
            }

            expectHandlersEmpty(
              server,
              reason:
                  'Handler map must be empty after '
                  'multi-connection shutdown',
            );

            final results = await Future.wait(
              futures,
            ).timeout(const Duration(seconds: 10), onTimeout: () => fail('60 streams did not settle'));
            expect(results, hasLength(60));
            expectHardcoreSettlements(results, reasonPrefix: 'shutdown with 60 concurrent streams');

            for (final ch in channels) {
              await ch.terminate();
            }
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during 60-stream shutdown. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('shutdown propagates through mixed '
        'payload sizes', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channel = createTestChannel(address, server.port!);

            final client = EchoClient(channel);
            final futures = <Future<Object?>>[];

            // 10 tiny unary echo RPCs.
            for (var i = 0; i < 10; i++) {
              futures.add(settleRpc(client.echo(i % 256).then<Object?>((v) => v)));
            }

            // 5 echoBytes with 1KB payloads.
            for (var i = 0; i < 5; i++) {
              futures.add(settleRpc(client.echoBytes(Uint8List(1024)).then<Object?>((v) => v)));
            }

            // 5 echoBytes with 32KB payloads.
            for (var i = 0; i < 5; i++) {
              futures.add(settleRpc(client.echoBytes(Uint8List(32 * 1024)).then<Object?>((v) => v)));
            }

            // 5 echoBytes with 64KB payloads (exceeds
            // HTTP/2 default window).
            for (var i = 0; i < 5; i++) {
              futures.add(settleRpc(client.echoBytes(Uint8List(64 * 1024)).then<Object?>((v) => v)));
            }

            // 5 server-streaming RPCs.
            for (var i = 0; i < 5; i++) {
              futures.add(settleRpc(client.serverStream(100).toList().then<Object?>((v) => v)));
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
            final results = await Future.wait(
              futures,
            ).timeout(const Duration(seconds: 10), onTimeout: () => fail('Mixed payload RPCs did not settle'));
            expect(results, hasLength(30));
            expectHardcoreSettlements(results, reasonPrefix: 'mixed payload shutdown propagation');

            await channel.terminate();
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during mixed payload shutdown. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('shutdown during serverStreamBytes with '
        'sustained data flow', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channel = createTestChannel(address, server.port!);

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

            final results = await Future.wait(
              futures,
            ).timeout(const Duration(seconds: 10), onTimeout: () => fail('serverStreamBytes RPCs did not settle'));
            expect(results, hasLength(10));
            expectHardcoreSettlements(results, reasonPrefix: 'serverStreamBytes sustained data flow');

            await channel.terminate();
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during serverStreamBytes shutdown. '
              'Got: $error',
        );
      }
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

      if (address.type != InternetAddressType.unix) {
        expect(
          server2.port,
          isNotNull,
          reason:
              'Second TCP server must expose a port '
              'after first server shutdown',
        );
      }
      await server2.shutdown();
    });

    testTcpAndUds('shutdown during connection handshake', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channel = createTestChannel(address, server.port!);

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
            final results = await Future.wait(
              futures,
            ).timeout(const Duration(seconds: 10), onTimeout: () => fail('Handshake-phase RPCs did not settle'));
            expect(results, hasLength(20));
            expectHardcoreSettlements(results, reasonPrefix: 'shutdown during connection handshake');

            await channel.terminate();
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during handshake shutdown. '
              'Got: $error',
        );
      }
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

      await waitForNoHandlers(server, reason: 'Unary-only handlers should drain without timing sleeps');

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
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channel = createTestChannel(address, server.port!);

            final client = EchoClient(channel);

            // Start 30 streams that yield only 5 items
            // each (~5ms total).
            final futures = <Future<Object?>>[];
            for (var i = 0; i < 30; i++) {
              futures.add(settleRpc(client.serverStream(5).toList().then<Object?>((v) => v)));
            }

            // Wait 20ms — some may have completed already,
            // some still active.
            await Future<void>.delayed(const Duration(milliseconds: 20));

            await server.shutdown();

            final results = await Future.wait(
              futures,
            ).timeout(const Duration(seconds: 10), onTimeout: () => fail('Race-with-completion RPCs did not settle'));
            expect(results, hasLength(30));
            expectHardcoreSettlements(results, reasonPrefix: 'shutdown races with RPC completion');

            await channel.terminate();
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during RPC completion race. '
              'Got: $error',
        );
      }
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
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
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
                futures.add(settleRpc(client.serverStream(50).toList().then<Object?>((v) => v)));
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

              await Future.wait(
                futures,
              ).timeout(const Duration(seconds: 10), onTimeout: () => fail('Cycle $cycle: streams did not settle'));

              await channel.terminate();
            }
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during rapid shutdown cycles. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('shutdown with data flowing in both '
        'directions simultaneously', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channel = createTestChannel(address, server.port!);

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

              futures.add(settleRpc(client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v)));
            }

            await waitForHandlers(
              server,
              minCount: 20,
              timeout: const Duration(seconds: 10),
              reason: 'All 20 bidi handlers must be active before shutdown',
            );

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
            expectHardcoreSettlements(results, reasonPrefix: 'bidi data flow during shutdown');

            await channel.terminate();
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during bidirectional data flow shutdown. '
              'Got: $error',
        );
      }
    });
  });

  // ==============================================================
  // Group 4: Handler map integrity
  // ==============================================================
  group('Handler map integrity', () {
    testTcpAndUds('handler map tracks all RPC types correctly', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channel = createTestChannel(address, server.port!);

            final client = EchoClient(channel);

            final futures = <Future<Object?>>[];

            // 5 unary echo RPCs.
            for (var i = 0; i < 5; i++) {
              futures.add(settleRpc(client.echo(i % 256).then<Object?>((v) => v)));
            }

            // 5 server-streaming RPCs.
            for (var i = 0; i < 5; i++) {
              futures.add(settleRpc(client.serverStream(255).toList().then<Object?>((v) => v)));
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
              futures.add(settleRpc(client.clientStream(ctrl.stream).then<Object?>((v) => v)));
            }

            // 5 bidi RPCs (via controllers, send 1 item).
            final bidiControllers = <StreamController<int>>[];
            for (var i = 0; i < 5; i++) {
              final ctrl = StreamController<int>();
              bidiControllers.add(ctrl);
              ctrl.add(i % 128);
              futures.add(settleRpc(client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v)));
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

            // waitForHandlers above already proved >= 15 registered.
            // Tighten to match that floor instead of vacuous > 0.
            expect(
              totalHandlerCount(server),
              greaterThanOrEqualTo(15),
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

            final results = await Future.wait(
              futures,
            ).timeout(const Duration(seconds: 10), onTimeout: () => fail('Mixed RPC types did not settle'));
            expect(results, hasLength(20));
            expectHardcoreSettlements(results, reasonPrefix: 'handler map tracks mixed RPC types');

            await channel.terminate();
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during mixed RPC type shutdown. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('handler map empty after 100 sequential RPCs', (address) async {
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

      await waitForNoHandlers(server, reason: 'Sequential unary handlers should fully drain before assertion');

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
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(
        () async {
          try {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channels = <TestClientChannel>[];
            final clients = <EchoClient>[];
            for (var c = 0; c < 5; c++) {
              final ch = createTestChannel(address, server.port!);
              channels.add(ch);
              clients.add(EchoClient(ch));
            }
            final controllers = <StreamController<int>>[];

            final futures = <Future<Object?>>[];
            for (var clientIndex = 0; clientIndex < clients.length; clientIndex++) {
              final client = clients[clientIndex];
              for (var i = 0; i < 10; i++) {
                final ctrl = StreamController<int>();
                controllers.add(ctrl);
                ctrl.add((clientIndex * 10 + i) % 128);
                futures.add(settleRpc(client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v)));
              }
              await Future<void>.delayed(Duration.zero);
            }

            // 5 clients x 10 streams = 50 total.
            await waitForHandlers(
              server,
              minCount: 50,
              timeout: const Duration(seconds: 30),
              reason:
                  '50 handlers across 5 connections '
                  'must be registered',
            );

            expect(totalHandlerCount(server), equals(50), reason: 'Handler map must track exactly 50 active handlers');

            // Verify handlers are spread across all 5 client connections.
            expect(server.handlers.keys.length, equals(5), reason: 'Handler map must have exactly 5 connection keys');

            await server.shutdown();

            for (final ctrl in controllers) {
              if (!ctrl.isClosed) {
                await ctrl.close();
              }
            }

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

            final results = await Future.wait(
              futures,
            ).timeout(const Duration(seconds: 10), onTimeout: () => fail('Multi-connection streams did not settle'));
            expect(results, hasLength(50));
            expectHardcoreSettlements(results, reasonPrefix: 'handler map tracks multi-connection streams');

            for (final ch in channels) {
              await ch.terminate();
            }
            done.complete();
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
        (error, stack) {
          http2InternalErrors.add(error);
        },
      );
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having((e) => e.message, 'message', contains('Cannot add event after closing')),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during multi-connection shutdown. '
              'Got: $error',
        );
      }
    });
  });

  group('Named pipe shutdown propagation', () {
    testNamedPipe('shutdown with 30 active bidi streams empties handler map', (pipeName) async {
      const streamCount = 30;

      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() async {
        try {
          await server.shutdown();
        } catch (e, st) {
          fail('TearDown: named-pipe server.shutdown failed: $e\n$st');
        }
      });

      final channel = NamedPipeClientChannel(pipeName, options: const NamedPipeChannelOptions());
      addTearDown(() async {
        try {
          await channel.shutdown();
        } catch (e, st) {
          fail('TearDown: named-pipe channel.shutdown failed: $e\n$st');
        }
      });
      final client = EchoClient(channel);
      final controllers = <StreamController<int>>[];
      addTearDown(() async {
        for (final ctrl in controllers) {
          if (!ctrl.isClosed) {
            try {
              await ctrl.close();
            } catch (e, st) {
              fail('TearDown: named-pipe StreamController.close failed: $e\n$st');
            }
          }
        }
      });

      // Start 30 bidi streams and keep controllers open so handlers
      // remain active until shutdown.
      final futures = <Future<Object?>>[];
      for (var i = 0; i < streamCount; i++) {
        final ctrl = StreamController<int>();
        controllers.add(ctrl);
        ctrl.add(i % 128);
        futures.add(settleRpc(client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v)));
      }

      await waitForHandlers(
        server,
        minCount: streamCount,
        timeout: const Duration(seconds: 30),
        reason: 'Named-pipe bidi handlers must be registered before shutdown',
      );

      expect(
        totalHandlerCount(server),
        equals(streamCount),
        reason:
            'Handler map must track exactly $streamCount '
            'active named-pipe handlers',
      );

      await server.shutdown();

      for (final ctrl in controllers) {
        if (!ctrl.isClosed) {
          await ctrl.close();
        }
      }

      expectHandlersEmpty(server, reason: 'Named-pipe handler map should be empty after shutdown');

      final results = await Future.wait(futures).timeout(
        const Duration(seconds: 20),
        onTimeout: () => fail('Named-pipe bidi streams did not settle after shutdown'),
      );
      expect(results, hasLength(streamCount));
      expectHardcoreSettlements(results, reasonPrefix: 'named pipe shutdown with active bidi streams');
    });
  });
}
