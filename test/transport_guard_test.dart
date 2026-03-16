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
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
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

          // Close all controllers — do NOT await (see comment in
          // "client sends data after server has initiated shutdown").
          for (final ctrl in controllers) {
            if (!ctrl.isClosed) {
              ctrl.close();
            }
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
          for (final r in results) {
            expectHardcoreRpcSettlement(
              r,
              reason:
                  'Each RPC must settle as '
                  'success or known error type',
            );
          }

          await channel.terminate();
          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during bidi shutdown. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('server shutdown during large payload transfer', (
      address,
    ) async {
      // Known upstream issue: when server.shutdown() terminates the
      // connection, the http2 package's ConnectionMessageQueueOut may
      // fire _trySendMessages via Timer.run on a microtask scheduled
      // before the socket's StreamController was closed. This throws
      // "Bad state: Cannot add event after closing" from FrameWriter.
      //
      // IMPORTANT: The entire test body — including server, channel,
      // and RPC creation — must run inside runZonedGuarded so ALL
      // timers scheduled by the http2 Connection inherit the guarded
      // zone, ensuring the StateError is always captured.
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
          final client = EchoClient(channel);

          // Pre-warm: establish the HTTP/2 connection so
          // subsequent RPCs are dispatched immediately.
          await client.echo(0);

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

          // Yield to the event loop so the queued RPC
          // request frames are sent over the pre-warmed
          // connection. echoBytes handlers complete instantly
          // (unary RPC) so waitForHandlers cannot observe them;
          // the pre-warm + yield guarantees data is in-flight.
          await Future.delayed(Duration.zero);

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
          for (final r in results) {
            expectHardcoreRpcSettlement(
              r,
              reason:
                  'Each RPC must settle as '
                  'success or known error type',
            );
          }

          await channel.terminate();
          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      // Verify any captured errors are the known http2-internal race.
      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during large payload shutdown. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('rapid terminate during bidiStreamBytes'
        ' with 32KB chunks', (address) async {
      // Known upstream issue: when server.shutdown() calls
      // connection.terminate(), the http2 package's internal
      // ConnectionMessageQueueOut._trySendMessages may fire on a
      // microtask that was already scheduled before the socket's
      // StreamController was closed. This throws
      // "Bad state: Cannot add event after closing" inside the
      // http2 package (FrameWriter._writeData → BufferedBytesWriter.add
      // → _StreamController.add). The error escapes as an unhandled
      // async exception because it originates in a http2-internal
      // microtask, not in any of our try/catch boundaries.
      //
      // IMPORTANT: The entire test body — including server, channel, and
      // RPC creation — must run inside runZonedGuarded. If the HTTP/2
      // connection is created outside the guarded zone, microtasks from
      // that connection run in the outer (test) zone and escape the guard.
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
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

          // Wait for all 10 bidiStreamBytes handlers to be
          // registered, proving streams have started processing.
          await waitForHandlers(
            server,
            minCount: 10,
            timeout: const Duration(seconds: 10),
            reason: 'Expected 10 bidiStreamBytes handlers before shutdown',
          );

          // Shut down while 32 KB chunks are in flight.
          await server.shutdown();

          // Close controllers — do NOT await (see comment in
          // "client sends data after server has initiated shutdown").
          for (final ctrl in controllers) {
            if (!ctrl.isClosed) {
              ctrl.close();
            }
          }

          // Wait for all feed futures too.
          final feedResults = await Future.wait(
            feedFutures.map(
              (future) =>
                  future.then<Object?>((_) => null, onError: (Object e) => e),
            ),
          );
          for (var i = 0; i < feedResults.length; i++) {
            expect(
              feedResults[i],
              isNull,
              reason:
                  'Chunk feeder $i should not fail while transport is '
                  'shutting down',
            );
          }

          final results = await Future.wait(futures).timeout(
            const Duration(seconds: 15),
            onTimeout: () => fail('Timed out waiting for streams'),
          );

          expect(
            results.length,
            equals(10),
            reason: 'All 10 bidiStreamBytes streams must settle',
          );
          for (final r in results) {
            expectHardcoreRpcSettlement(
              r,
              reason:
                  'Each RPC must settle as '
                  'success or known error type',
            );
          }

          await channel.terminate();
          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      // Verify any captured errors are the known http2-internal race.
      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during rapid terminate. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('client sends data after server has initiated'
        ' shutdown', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
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

          // Send 1 item per stream and wait for handlers
          // to be registered (proves data has been received).
          for (final ctrl in controllers) {
            ctrl.add(1);
          }
          await waitForHandlers(
            server,
            minCount: 5,
            timeout: const Duration(seconds: 10),
            reason: 'Expected 5 bidi handlers before shutdown',
          );

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

          // Close controllers — do NOT await.
          for (final ctrl in controllers) {
            if (!ctrl.isClosed) {
              ctrl.close();
            }
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
          for (final r in results) {
            expectHardcoreRpcSettlement(
              r,
              reason:
                  'Each RPC must settle as '
                  'success or known error type',
            );
          }

          await channel.terminate();
          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during post-shutdown data. '
              'Got: $error',
        );
      }
    });
  });

  // ==============================================================
  // Group 2: Concurrent terminate races
  // ==============================================================

  group('Concurrent terminate races', () {
    testTcpAndUds('20 concurrent streams with interleaved server'
        ' and channel shutdown', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
          final client = EchoClient(channel);

          // Start 20 server-streaming RPCs.
          final futures = <Future<Object?>>[];
          for (var i = 0; i < 20; i++) {
            futures.add(
              settleRpc(
                client.serverStream(100).toList().then<Object?>((v) => v),
              ),
            );
          }

          // Wait for all 20 server-streaming handlers to be
          // registered, proving RPCs are actively streaming.
          await waitForHandlers(
            server,
            minCount: 20,
            timeout: const Duration(seconds: 10),
            reason: 'Expected 20 server-streaming handlers before dual shutdown',
          );

          // Fire server.shutdown() AND channel.shutdown()
          // simultaneously — maximum terminate pressure.
          await Future.wait([server.shutdown(), channel.terminate()]).timeout(
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
          for (final r in results) {
            expectHardcoreRpcSettlement(
              r,
              reason:
                  'Each RPC must settle as '
                  'success or known error type',
            );
          }

          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during dual shutdown. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('channel.shutdown() while server is streaming'
        ' large payloads', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
          final client = EchoClient(channel);

          // Pre-warm: establish the HTTP/2 connection so
          // subsequent RPCs are dispatched immediately.
          await client.echo(0);

          // Each serverStreamBytes yields 50 chunks of 8 KB.
          // Request: 8-byte big-endian [chunkCount, chunkSize].
          final request = encodeStreamBytesRequest(50, 8192);
          final futures = <Future<Object?>>[];
          for (var i = 0; i < 10; i++) {
            futures.add(
              settleRpc(
                client
                    .serverStreamBytes(request)
                    .toList()
                    .then<Object?>((v) => v),
              ),
            );
          }

          // Yield to the event loop so the queued RPC requests
          // are sent over the pre-warmed connection. The handler
          // yields all 50 chunks synchronously (yieldEvery=200),
          // but 400KB of response data is buffered in the HTTP/2
          // transport pipeline behind flow control windows.
          await Future.delayed(Duration.zero);

          // Client-initiated teardown while the server
          // is still yielding data into the outgoing sink.
          await channel.terminate().timeout(
            const Duration(seconds: 15),
            onTimeout: () => fail('Timed out during channel terminate'),
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
          for (final r in results) {
            expectHardcoreRpcSettlement(
              r,
              reason:
                  'Each RPC must settle as '
                  'success or known error type',
            );
          }

          await server.shutdown();
          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during large payload shutdown. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('10 concurrent echoBytes with immediate channel'
        ' teardown', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
          final client = EchoClient(channel);

          // Fire 10 echoBytes RPCs with 32 KB payloads.
          // Do NOT await — immediately tear down.
          final futures = <Future<Object?>>[];
          for (var i = 0; i < 10; i++) {
            futures.add(
              settleRpc(
                client.echoBytes(Uint8List(32768)).then<Object?>((v) => v),
              ),
            );
          }

          // Immediately terminate the channel — RPCs may
          // not even complete the HTTP/2 handshake.
          await channel.terminate().timeout(
            const Duration(seconds: 15),
            onTimeout: () => fail('Timed out during channel terminate'),
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
          for (final r in results) {
            expectHardcoreRpcSettlement(
              r,
              reason:
                  'Each RPC must settle as '
                  'success or known error type',
            );
          }

          await server.shutdown();
          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during immediate teardown. '
              'Got: $error',
        );
      }
    });
  });

  // ==============================================================
  // Group 3: Error propagation through guarded sinks
  // ==============================================================

  group('Error propagation through guarded sinks', () {
    testTcpAndUds('RPC errors do not crash when sink is closing', (
      address,
    ) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
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

          // Send some data and wait for handlers to confirm
          // the server is processing each stream.
          for (final ctrl in controllers) {
            ctrl.add(1);
            ctrl.add(2);
          }
          await waitForHandlers(
            server,
            minCount: 10,
            timeout: const Duration(seconds: 10),
            reason: 'Expected 10 bidi handlers before error+shutdown',
          );

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
          for (final r in results) {
            expectHardcoreRpcSettlement(
              r,
              reason:
                  'Each RPC must settle as '
                  'success or known error type',
            );
          }

          await channel.terminate();
          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during error+shutdown. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('sustained throughput then abrupt terminate'
        ' (50 streams x 50 items)', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
          final client = EchoClient(channel);

          // 50 bidi streams, each fed with a pacedStream
          // of 50 items (values 0-127).
          final items = List.generate(50, (i) => i % 128);
          final futures = <Future<Object?>>[];
          final firstResponses = List.generate(50, (_) => Completer<void>());
          for (var i = 0; i < 50; i++) {
            final idx = i;
            final stream = pacedStream(items, yieldEvery: 1);
            futures.add(
              settleRpc(
                client
                    .bidiStream(stream)
                    .map((value) {
                      if (!firstResponses[idx].isCompleted) {
                        firstResponses[idx].complete();
                      }
                      return value;
                    })
                    .toList()
                    .then<Object?>((v) => v),
              ),
            );
          }

          await Future.wait(firstResponses.map((c) => c.future)).timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail(
              'All sustained-throughput streams must emit a first response '
              'before shutdown',
            ),
          );

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
          for (final r in results) {
            expectHardcoreRpcSettlement(
              r,
              reason:
                  'Each RPC must settle as '
                  'success or known error type',
            );
          }

          await channel.terminate();
          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during sustained throughput. '
              'Got: $error',
        );
      }
    });

    testTcpAndUds('repeated connect-transfer-terminate cycles'
        ' (10 cycles)', (address) async {
      final http2InternalErrors = <Object>[];
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          for (var cycle = 0; cycle < 10; cycle++) {
            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channel = createTestChannel(address, server.port!);
            final client = EchoClient(channel);

            // Start 5 bidi streams and pump 20 items
            // into each.
            final controllers =
                List.generate(5, (_) => StreamController<int>());
            final futures = <Future<Object?>>[];
            for (final ctrl in controllers) {
              futures.add(
                settleRpc(
                  client
                      .bidiStream(ctrl.stream)
                      .toList()
                      .then<Object?>((v) => v),
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

            // Close controllers — do NOT await.
            for (final ctrl in controllers) {
              if (!ctrl.isClosed) {
                ctrl.close();
              }
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
            for (final r in results) {
              expectHardcoreRpcSettlement(
                r,
                reason:
                    'Each RPC must settle as '
                    'success or known error type',
              );
            }

            // Clean terminate of the channel.
            await channel.terminate();
          }

          done.complete();
        } catch (e, st) {
          done.completeError(e, st);
        }
      }, (error, stack) {
        http2InternalErrors.add(error);
      });
      await done.future;

      for (final error in http2InternalErrors) {
        expect(
          error,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot add event after closing'),
          ),
          reason:
              'Only the known http2 FrameWriter race is expected '
              'as an unhandled async error during cycle teardown. '
              'Got: $error',
        );
      }
    });
  });

  group('Named pipe transport guard', () {
    testNamedPipe(
      'server shutdown during active bidi data flow does not crash',
      (pipeName) async {
        const streamCount = 12;
        const itemsPerStream = 40;

        final server = NamedPipeServer.create(services: [EchoService()]);
        addTearDown(() => server.shutdown());
        await server.serve(pipeName: pipeName);

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );
        addTearDown(() => channel.terminate());
        final client = EchoClient(channel);

        final controllers = List.generate(
          streamCount,
          (_) => StreamController<int>(),
        );
        final futures = <Future<Object?>>[];

        for (final ctrl in controllers) {
          futures.add(
            settleRpc(
              client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v),
            ),
          );
        }

        for (var i = 0; i < itemsPerStream; i++) {
          for (final ctrl in controllers) {
            if (!ctrl.isClosed) {
              ctrl.add(i % 128);
            }
          }
          if (i % 4 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }

        await waitForHandlers(
          server,
          minCount: streamCount,
          timeout: const Duration(seconds: 10),
          reason: 'Named-pipe bidi handlers must be active before shutdown',
        );

        await server.shutdown();

        // Close controllers — do NOT await (see comment in
        // "client sends data after server has initiated shutdown").
        for (final ctrl in controllers) {
          if (!ctrl.isClosed) {
            ctrl.close();
          }
        }

        final results = await Future.wait(futures).timeout(
          const Duration(seconds: 20),
          onTimeout: () =>
              fail('Named-pipe bidi streams did not settle after shutdown'),
        );

        expect(results, hasLength(streamCount));
        for (var i = 0; i < results.length; i++) {
          expectHardcoreRpcSettlement(
            results[i],
            reason: 'Named-pipe stream $i settled with invalid result type',
          );
        }

        expect(
          server.handlers.values.every((list) => list.isEmpty),
          isTrue,
          reason: 'Named-pipe handler map should be empty after shutdown',
        );

        await channel.shutdown();
      },
    );
  });
}
