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

/// Tests for RST_STREAM propagation during server.shutdown().
///
/// The fix under test adds `await Future.delayed(Duration.zero)`
/// between handler.cancel() and connection.finish() in
/// shutdownActiveConnections(). Without this fix, RST_STREAM
/// frames are dropped because GOAWAY and socket-close happen
/// before the http2 outgoing queue flushes.
///
/// CRITICAL CONSTRAINT: None of these tests call
/// channel.shutdown() BEFORE asserting stream termination.
/// The entire point is to verify that server.shutdown() ALONE
/// propagates RST_STREAM frames correctly.
@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

void main() {
  group('RST_STREAM propagation without channel.shutdown() crutch', () {
    testTcpAndUds('50 concurrent server-streaming RPCs terminate '
        'on server.shutdown() alone', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      final doneCompleters = List.generate(50, (_) => Completer<void>());
      final itemCounts = List.filled(50, 0);
      final errors = <Object>[];
      final firstItemCompleters = List.generate(50, (_) => Completer<void>());

      for (var i = 0; i < 50; i++) {
        final idx = i;
        final stream = client.serverStream(255);
        stream.listen(
          (item) {
            itemCounts[idx]++;
            if (!firstItemCompleters[idx].isCompleted) {
              firstItemCompleters[idx].complete();
            }
          },
          onError: (Object e) {
            if (e is! GrpcError) {
              errors.add(e);
            }
            if (!firstItemCompleters[idx].isCompleted) {
              firstItemCompleters[idx].complete();
            }
            if (!doneCompleters[idx].isCompleted) {
              doneCompleters[idx].complete();
            }
          },
          onDone: () {
            if (!doneCompleters[idx].isCompleted) {
              doneCompleters[idx].complete();
            }
          },
        );
      }

      // Wait for first item on all 50 streams.
      await Future.wait(firstItemCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail(
          'Timed out waiting for first items on '
          'all 50 streams',
        ),
      );

      // server.shutdown() — NO channel.shutdown() here.
      await server.shutdown();

      // All 50 done completers must fire within 10s.
      await Future.wait(doneCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'Timed out: not all 50 streams terminated '
          'after server.shutdown()',
        ),
      );

      expect(
        errors,
        isEmpty,
        reason: 'No unexpected non-GrpcError errors expected',
      );

      for (var i = 0; i < 50; i++) {
        expect(
          itemCounts[i],
          lessThan(255),
          reason:
              'Stream $i should be truncated by shutdown '
              '(got ${itemCounts[i]} items)',
        );
      }

      // Cleanup AFTER all assertions.
      await channel.shutdown();
    });

    testTcpAndUds('20 concurrent bidi streams terminate '
        'on server.shutdown() alone', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      final controllers = List.generate(20, (_) => StreamController<int>());
      final doneCompleters = List.generate(20, (_) => Completer<void>());
      final firstResponseCompleters = List.generate(
        20,
        (_) => Completer<void>(),
      );
      final errors = <Object>[];

      for (var i = 0; i < 20; i++) {
        final idx = i;
        final stream = client.bidiStream(controllers[idx].stream);
        stream.listen(
          (item) {
            if (!firstResponseCompleters[idx].isCompleted) {
              firstResponseCompleters[idx].complete();
            }
          },
          onError: (Object e) {
            if (e is! GrpcError) {
              errors.add(e);
            }
            if (!firstResponseCompleters[idx].isCompleted) {
              firstResponseCompleters[idx].complete();
            }
            if (!doneCompleters[idx].isCompleted) {
              doneCompleters[idx].complete();
            }
          },
          onDone: () {
            if (!doneCompleters[idx].isCompleted) {
              doneCompleters[idx].complete();
            }
          },
        );

        // Send one item on each (value 1-20, all <=127).
        controllers[idx].add(idx + 1);
      }

      // Wait for first response on all 20 streams.
      await Future.wait(firstResponseCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('Timed out waiting for first bidi responses'),
      );

      // server.shutdown() — NO channel.shutdown().
      await server.shutdown();

      // All 20 streams must settle within 10s.
      await Future.wait(doneCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'Timed out: not all 20 bidi streams '
          'terminated after server.shutdown()',
        ),
      );

      expect(
        errors,
        isEmpty,
        reason: 'No unexpected non-GrpcError errors expected',
      );

      // Close all controllers, then cleanup.
      for (final c in controllers) {
        await c.close();
      }
      await channel.shutdown();
    });

    testTcpAndUds('mixed 30 RPCs (10 unary + 10 server-stream + '
        '10 bidi) all settle on server.shutdown()', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      final settled = <Future<Object?>>[];
      final bidiControllers = <StreamController<int>>[];

      // 10 unary RPCs.
      for (var i = 0; i < 10; i++) {
        settled.add(settleRpc(client.echo(i).then<Object?>((v) => v)));
      }

      // 10 server-streaming RPCs.
      for (var i = 0; i < 10; i++) {
        settled.add(
          settleRpc(client.serverStream(255).toList().then<Object?>((v) => v)),
        );
      }

      // 10 bidi RPCs.
      for (var i = 0; i < 10; i++) {
        final ctrl = StreamController<int>();
        bidiControllers.add(ctrl);
        ctrl.add(i + 1);
        settled.add(
          settleRpc(
            client.bidiStream(ctrl.stream).toList().then<Object?>((v) => v),
          ),
        );
      }

      // Wait for at least 20 handlers (streaming RPCs)
      // to be registered on the server side.
      await waitForHandlers(
        server,
        minCount: 20,
        timeout: const Duration(seconds: 10),
        reason:
            'Expected at least 20 handlers '
            'for streaming RPCs',
      );

      // server.shutdown() — NO channel.shutdown().
      await server.shutdown();

      // All 30 must settle within 10s.
      final results = await Future.wait(settled).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'Timed out: not all 30 mixed RPCs settled '
          'after server.shutdown()',
        ),
      );

      // Unary RPCs may have completed before shutdown;
      // streaming ones must have terminated (possibly
      // with GrpcError).
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        if (r is Error && r is! GrpcError) {
          fail('RPC $i settled with unexpected Error: $r');
        }
      }

      // Close bidi controllers, then cleanup.
      for (final c in bidiControllers) {
        await c.close();
      }
      await channel.shutdown();
    });

    testTcpAndUds('server.shutdown() terminates streams even with '
        'sustained client data flow', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      final controllers = List.generate(10, (_) => StreamController<int>());
      final doneCompleters = List.generate(10, (_) => Completer<void>());
      final errors = <Object>[];
      final timers = <Timer>[];

      for (var i = 0; i < 10; i++) {
        final idx = i;
        final stream = client.bidiStream(controllers[idx].stream);
        stream.listen(
          (_) {},
          onError: (Object e) {
            if (e is! GrpcError) {
              errors.add(e);
            }
            if (!doneCompleters[idx].isCompleted) {
              doneCompleters[idx].complete();
            }
          },
          onDone: () {
            if (!doneCompleters[idx].isCompleted) {
              doneCompleters[idx].complete();
            }
          },
        );

        // Pump data every 5ms (value 1, always safe).
        var counter = 0;
        timers.add(
          Timer.periodic(const Duration(milliseconds: 5), (_) {
            if (!controllers[idx].isClosed) {
              counter = (counter + 1) % 128;
              controllers[idx].add(counter);
            }
          }),
        );
      }

      // Let data flow for 100ms, then shut down.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await server.shutdown();

      // Cancel all timers immediately.
      for (final t in timers) {
        t.cancel();
      }

      // All 10 streams must settle within 10s.
      await Future.wait(doneCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'Timed out: not all 10 bidi streams '
          'terminated after server.shutdown() with '
          'sustained data flow',
        ),
      );

      expect(
        errors,
        isEmpty,
        reason:
            'No "Cannot add event after closing" '
            'or other unexpected errors expected',
      );

      // Close controllers, then cleanup.
      for (final c in controllers) {
        await c.close();
      }
      await channel.shutdown();
    });

    testTcpAndUds('client-streaming RPCs settle on '
        'server.shutdown() without channel crutch', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      final controllers = List.generate(20, (_) => StreamController<int>());
      final settled = <Future<Object?>>[];

      for (var i = 0; i < 20; i++) {
        // Send 3 values on each (values 1, 2, 3).
        controllers[i].add(1);
        controllers[i].add(2);
        controllers[i].add(3);
        // Do NOT close the controllers yet.

        settled.add(
          settleRpc(
            client.clientStream(controllers[i].stream).then<Object?>((v) => v),
          ),
        );
      }

      // Wait for handlers to be registered.
      await waitForHandlers(
        server,
        minCount: 20,
        timeout: const Duration(seconds: 10),
        reason: 'Expected 20 client-streaming handlers',
      );

      // server.shutdown() — NO channel.shutdown().
      await server.shutdown();

      // All 20 must settle within 10s.
      final results = await Future.wait(settled).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'Timed out: not all 20 client-streaming '
          'RPCs settled after server.shutdown()',
        ),
      );

      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        // Each settles with either an int sum or
        // a GrpcError — both are acceptable.
        expect(
          r is int || r is GrpcError,
          isTrue,
          reason:
              'Client-stream RPC $i settled with '
              'unexpected type: ${r.runtimeType}',
        );
      }

      // Close all controllers, then cleanup.
      for (final c in controllers) {
        await c.close();
      }
      await channel.shutdown();
    });
  });

  group('RST_STREAM at scale', () {
    testTcpAndUds('100 concurrent streams terminate cleanly '
        'on server.shutdown()', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      final doneCompleters = List.generate(100, (_) => Completer<void>());
      final itemCounts = List.filled(100, 0);
      final errors = <Object>[];
      final firstItemCompleters = List.generate(100, (_) => Completer<void>());

      for (var i = 0; i < 100; i++) {
        final idx = i;
        final stream = client.serverStream(255);
        stream.listen(
          (item) {
            itemCounts[idx]++;
            if (!firstItemCompleters[idx].isCompleted) {
              firstItemCompleters[idx].complete();
            }
          },
          onError: (Object e) {
            if (e is! GrpcError) {
              errors.add(e);
            }
            if (!firstItemCompleters[idx].isCompleted) {
              firstItemCompleters[idx].complete();
            }
            if (!doneCompleters[idx].isCompleted) {
              doneCompleters[idx].complete();
            }
          },
          onDone: () {
            if (!doneCompleters[idx].isCompleted) {
              doneCompleters[idx].complete();
            }
          },
        );
      }

      // Wait for first item on all 100 streams.
      // This may take longer than 50 due to volume.
      await Future.wait(firstItemCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail(
          'Timed out waiting for first items on '
          'all 100 streams',
        ),
      );

      // server.shutdown() — NO channel.shutdown().
      await server.shutdown();

      // All 100 done completers must fire within 15s.
      // Some RST_STREAM frames may rely on the
      // socket-close fallback rather than explicit
      // per-stream flush.
      await Future.wait(doneCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail(
          'Timed out: not all 100 streams terminated '
          'after server.shutdown()',
        ),
      );

      expect(
        errors,
        isEmpty,
        reason: 'No unexpected non-GrpcError errors expected',
      );

      for (var i = 0; i < 100; i++) {
        expect(
          itemCounts[i],
          lessThan(255),
          reason:
              'Stream $i should be truncated by '
              'shutdown (got ${itemCounts[i]} items)',
        );
      }

      // Cleanup AFTER all assertions.
      await channel.shutdown();
    });

    testTcpAndUds('server.shutdown() during initial handshake '
        '(streams not yet flowing)', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      final settled = <Future<Object?>>[];

      // Start 20 server-streaming RPCs.
      for (var i = 0; i < 20; i++) {
        settled.add(
          settleRpc(client.serverStream(255).toList().then<Object?>((v) => v)),
        );
      }

      // Immediately shut down — do NOT wait for first
      // items. Some RPCs may never have started.
      await server.shutdown();

      // All 20 must settle within 10s.
      final results = await Future.wait(settled).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'Timed out: not all 20 RPCs settled after '
          'immediate server.shutdown()',
        ),
      );

      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        // Each settles with either a list of ints or
        // a GrpcError — both acceptable.
        expect(
          r is List<int> || r is GrpcError,
          isTrue,
          reason:
              'RPC $i settled with unexpected type: '
              '${r.runtimeType}',
        );
      }

      // Cleanup AFTER all assertions.
      await channel.shutdown();
    });

    testTcpAndUds('repeated shutdown stress: 8 cycles of '
        'start -> 25 streams -> shutdown', (address) async {
      for (var cycle = 0; cycle < 8; cycle++) {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);
        final client = EchoClient(channel);

        final doneCompleters = List.generate(25, (_) => Completer<void>());
        final firstItemCompleters = List.generate(25, (_) => Completer<void>());
        final errors = <Object>[];

        for (var i = 0; i < 25; i++) {
          final idx = i;
          final stream = client.serverStream(255);
          stream.listen(
            (item) {
              if (!firstItemCompleters[idx].isCompleted) {
                firstItemCompleters[idx].complete();
              }
            },
            onError: (Object e) {
              if (e is! GrpcError) {
                errors.add(e);
              }
              if (!firstItemCompleters[idx].isCompleted) {
                firstItemCompleters[idx].complete();
              }
              if (!doneCompleters[idx].isCompleted) {
                doneCompleters[idx].complete();
              }
            },
            onDone: () {
              if (!doneCompleters[idx].isCompleted) {
                doneCompleters[idx].complete();
              }
            },
          );
        }

        // Wait for first item on all 25 streams.
        await Future.wait(firstItemCompleters.map((c) => c.future)).timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail(
            'Cycle $cycle: timed out waiting for first '
            'items on all 25 streams',
          ),
        );

        // server.shutdown() ONLY — no channel crutch.
        await server.shutdown();

        // All 25 must settle within 10s.
        await Future.wait(doneCompleters.map((c) => c.future)).timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail(
            'Cycle $cycle: not all 25 streams '
            'terminated after server.shutdown()',
          ),
        );

        expect(
          errors,
          isEmpty,
          reason:
              'Cycle $cycle: no unexpected '
              'non-GrpcError errors expected',
        );

        // THEN channel.shutdown() for cleanup.
        await channel.shutdown();
      }
    });
  });
}
