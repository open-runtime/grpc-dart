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

/// Hardcore server cancellation and shutdown tests.
///
/// These tests verify that Server.shutdown() correctly cancels ALL active
/// handlers in every lifecycle stage, empties the handler map, and does not
/// hang or crash under any conditions. Every test uses real TCP connections
/// (not mock harness) to exercise the actual production code path:
///
///   Server.shutdown() → shutdownActiveConnections() → handler.cancel()
///
/// This is the path that fires during AOT deployment restarts.
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

// waitForHandlers(), settleRpc(), expectExpectedRpcSettlement() are imported
// from common.dart

// =============================================================================
// Tests
// =============================================================================

void main() {
  // ---------------------------------------------------------------------------
  // Server.shutdown() with concurrent active handlers
  // ---------------------------------------------------------------------------
  group('Server.shutdown() with active handlers', () {
    testTcpAndUds('shutdown cancels 25 concurrent server-streaming handlers', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      // Start 25 concurrent server-streaming RPCs. Each streams 255
      // items at 1ms/item = ~0.255 seconds. We manually collect items
      // per-stream so we can use a concrete "all items arrived"
      // signal instead of a flaky time-based delay.
      const streamCount = 25;
      final collectors = <List<int>>[];
      final doneCompleters = <Completer<void>>[];
      final perStreamFirstItem = <Completer<void>>[];
      final unexpectedErrors = <Object>[];

      for (var i = 0; i < streamCount; i++) {
        final items = <int>[];
        collectors.add(items);
        final done = Completer<void>();
        doneCompleters.add(done);
        final firstItem = Completer<void>();
        perStreamFirstItem.add(firstItem);

        client
            .serverStream(255)
            .listen(
              (value) {
                items.add(value);
                if (!firstItem.isCompleted) firstItem.complete();
              },
              onError: (e) {
                // Complete the done completer FIRST to unblock
                // Future.wait, then assert. If expect() threw before
                // complete(), a non-GrpcError would prevent the
                // completer from ever completing, causing the
                // "streams still active" timeout to fire instead of
                // surfacing the real assertion failure.
                if (e is! GrpcError) unexpectedErrors.add(e);
                if (!done.isCompleted) done.complete();
              },
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
            );
      }

      // Wait until ALL streams have received at least one item.
      // This proves all 25 handlers are active and data is flowing.
      await Future.wait(perStreamFirstItem.map((c) => c.future)).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'Not all streams received data — '
          '${perStreamFirstItem.where((c) => c.isCompleted).length}'
          '/$streamCount started',
        ),
      );

      // Shutdown must cancel all 25 handlers and complete.
      await server.shutdown().timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            fail('server.shutdown() hung with 25 active streaming handlers'),
      );

      // All 25 streams must have terminated (not hung).
      // The server's shutdownActiveConnections() now yields between
      // handler.cancel() and connection.finish(), giving the http2
      // outgoing queue time to flush RST_STREAM frames before GOAWAY
      // closes the socket. This should be sufficient — no client-side
      // channel.shutdown() crutch needed.
      await Future.wait(doneCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('streams still active after shutdown'),
      );
      expect(
        unexpectedErrors,
        isEmpty,
        reason: 'Expected stream termination errors to be GrpcError only',
      );

      // Verify truncation: each stream must have fewer than 255 items.
      for (var i = 0; i < collectors.length; i++) {
        expect(
          collectors[i].length,
          lessThan(255),
          reason:
              'stream $i should have been truncated by shutdown '
              '(0 items is valid if shutdown won the race)',
        );
      }

      // Guard against vacuous truth: all per-stream completers
      // proved all items arrived. Verify it's reflected.
      final totalItems = collectors.fold<int>(
        0,
        (sum, items) => sum + items.length,
      );
      expect(
        totalItems,
        greaterThanOrEqualTo(streamCount),
        reason:
            'all $streamCount streams started, '
            'each must have at least 1 item',
      );
    });

    testTcpAndUds('shutdown verifies handler map is fully emptied', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      // Start 15 concurrent streaming RPCs.
      final streamFutures = <Future<Object?>>[];
      for (var i = 0; i < 15; i++) {
        streamFutures.add(settleRpc(client.serverStream(255).toList()));
      }

      // Wait for handlers to be registered (deterministic signal).
      await waitForHandlers(
        server,
        reason:
            'Handlers map must have entries before shutdown '
            '(otherwise the test proves nothing)',
      );

      await server.shutdown().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('shutdown hung'),
      );

      // Verify handler map is completely empty — no leaked
      // references. We already proved the map was non-empty
      // above, so this is not vacuously true.
      expect(
        server.handlers.values.every((list) => list.isEmpty),
        isTrue,
        reason: 'All handler lists should be empty after shutdown',
      );

      final settled = await Future.wait(streamFutures).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('streams hung'),
      );
      for (final result in settled) {
        expectExpectedRpcSettlement(
          result,
          reason:
              'shutdown verifies map test should settle '
              'with known result/error',
        );
      }
      await channel.shutdown();
    });

    testTcpAndUds(
      'stress: repeated shutdown cycles cancel active handlers cleanly',
      (address) async {
        const cycles = 16;
        const streamCount = 12;
        final shutdownRaceTimeout = address.type == InternetAddressType.unix
            ? const Duration(seconds: 20)
            : const Duration(seconds: 10);

        for (var cycle = 0; cycle < cycles; cycle++) {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channel = createTestChannel(address, server.port!);
          final client = EchoClient(channel);

          final firstItems = List.generate(
            streamCount,
            (_) => Completer<void>(),
          );
          final doneCompleters = List.generate(
            streamCount,
            (_) => Completer<void>(),
          );
          final unexpectedErrors = <Object>[];

          try {
            for (var i = 0; i < streamCount; i++) {
              client
                  .serverStream(255)
                  .listen(
                    (value) {
                      if (!firstItems[i].isCompleted) firstItems[i].complete();
                    },
                    onError: (e) {
                      if (e is! GrpcError) unexpectedErrors.add(e);
                      if (!doneCompleters[i].isCompleted) {
                        doneCompleters[i].complete();
                      }
                    },
                    onDone: () {
                      if (!doneCompleters[i].isCompleted) {
                        doneCompleters[i].complete();
                      }
                    },
                  );
            }

            await Future.wait(firstItems.map((c) => c.future)).timeout(
              const Duration(seconds: 8),
              onTimeout: () =>
                  fail('Cycle $cycle: not all streams started before shutdown'),
            );

            if (cycle.isEven) {
              await server.shutdown().timeout(
                shutdownRaceTimeout,
                onTimeout: () =>
                    fail('Cycle $cycle: server.shutdown() did not settle'),
              );
              await channel.shutdown().timeout(
                const Duration(seconds: 10),
                onTimeout: () =>
                    fail('Cycle $cycle: channel.shutdown() did not settle'),
              );
            } else {
              await channel.shutdown().timeout(
                const Duration(seconds: 10),
                onTimeout: () =>
                    fail('Cycle $cycle: channel.shutdown() did not settle'),
              );
              await server.shutdown().timeout(
                shutdownRaceTimeout,
                onTimeout: () =>
                    fail('Cycle $cycle: server.shutdown() did not settle'),
              );
            }

            await Future.wait(doneCompleters.map((c) => c.future)).timeout(
              const Duration(seconds: 5),
              onTimeout: () =>
                  fail('Cycle $cycle: streams still active after shutdown'),
            );

            expect(
              unexpectedErrors,
              isEmpty,
              reason:
                  'Cycle $cycle: expected stream termination errors '
                  'to be GrpcError only',
            );
            expect(
              server.handlers.values.every((list) => list.isEmpty),
              isTrue,
              reason: 'Cycle $cycle: handlers leaked after shutdown',
            );
          } finally {
            await channel.shutdown();
            await server.shutdown();
          }
        }
      },
    );

    testTcpAndUds(
      'handlers at various lifecycle stages all terminate on shutdown',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channel = createTestChannel(address, server.port!);
        addTearDown(() => channel.shutdown());
        final client = EchoClient(channel);

        // (1) Completed unary — already done by the time we shutdown.
        final unaryResult = await client.echo(42);
        expect(unaryResult, equals(42));

        // (2) Server-stream mid-yield — streaming 255 items at 1ms each.
        final serverStreamFuture = settleRpc(client.serverStream(255).toList());

        // (3) Bidi stream — handler blocks in await-for after first item.
        final bidiController = StreamController<int>();
        final bidiStreamFuture = settleRpc(
          client.bidiStream(bidiController.stream).toList(),
        );
        bidiController.add(1); // send one item, handler processes it

        // (4) Client-stream — still accumulating.
        final clientStreamController = StreamController<int>();
        final clientStreamFuture = settleRpc(
          client.clientStream(clientStreamController.stream),
        );
        clientStreamController.add(10);
        clientStreamController.add(20);

        // Wait for handlers to be registered (deterministic signal).
        await waitForHandlers(
          server,
          reason:
              'Handlers must be active before shutdown '
              '(mixed lifecycle test)',
        );

        // Shutdown — must cancel all active handlers.
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('shutdown hung with mixed lifecycle handlers'),
        );

        // Close client-side streams.
        await bidiController.close();
        await clientStreamController.close();

        // All RPCs must settle (succeed or error, but not hang).
        final settled =
            await Future.wait([
              serverStreamFuture,
              bidiStreamFuture,
              clientStreamFuture,
            ]).timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail('RPCs still active after shutdown'),
            );
        for (final result in settled) {
          expectExpectedRpcSettlement(
            result,
            reason: 'mixed lifecycle RPC should settle with known result/error',
          );
        }

        await channel.shutdown();
      },
    );

    testNamedPipe('shutdown cancels 25 concurrent server-streaming handlers', (
      pipeName,
    ) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      // Use manual collectors with a concrete signal instead of
      // time-based delay. This prevents the vacuous-truth scenario
      // where shutdown wins the race and all streams get 0 items.
      final collectors = <List<int>>[];
      final doneCompleters = <Completer<void>>[];
      final firstItemSeen = Completer<void>();
      final unexpectedErrors = <Object>[];

      for (var i = 0; i < 25; i++) {
        final items = <int>[];
        collectors.add(items);
        final done = Completer<void>();
        doneCompleters.add(done);

        client
            .serverStream(255)
            .listen(
              (value) {
                items.add(value);
                if (!firstItemSeen.isCompleted) {
                  firstItemSeen.complete();
                }
              },
              onError: (e) {
                // Complete the done completer FIRST to unblock
                // Future.wait (same rationale as TCP variant).
                if (e is! GrpcError) unexpectedErrors.add(e);
                if (!done.isCompleted) done.complete();
              },
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
            );
      }

      // Concrete signal: wait until at least one stream has received
      // its first item. This proves handlers are active and data is
      // flowing — no time-based guessing.
      await firstItemSeen.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'No named-pipe stream received any data — '
          'handlers may not have started',
        ),
      );

      // Shutdown must cancel all 25 handlers and complete.
      await server.shutdown().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'server.shutdown() hung with 25 active streaming '
          'handlers (named pipe)',
        ),
      );

      // All 25 streams must have terminated (not hung).
      await Future.wait(doneCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('streams still active after shutdown'),
      );
      expect(
        unexpectedErrors,
        isEmpty,
        reason: 'Expected stream termination errors to be GrpcError only',
      );

      // Verify truncation: each stream must have fewer than 255 items.
      for (var i = 0; i < collectors.length; i++) {
        expect(
          collectors[i].length,
          lessThan(255),
          reason:
              'stream $i should have been truncated by shutdown '
              '(0 items is valid if shutdown won the race)',
        );
      }

      // Guard against vacuous truth: the firstItemSeen completer
      // already proved at least 1 item arrived. Verify it's reflected.
      final totalItems = collectors.fold<int>(
        0,
        (sum, items) => sum + items.length,
      );
      expect(
        totalItems,
        greaterThan(0),
        reason: 'firstItemSeen completed, so at least 1 item must exist',
      );

      await channel.shutdown();
    });

    testNamedPipe('shutdown verifies handler map is fully emptied', (
      pipeName,
    ) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);
      addTearDown(() => server.shutdown());

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      final streamFutures = <Future<Object?>>[];
      for (var i = 0; i < 15; i++) {
        streamFutures.add(settleRpc(client.serverStream(255).toList()));
      }

      // Wait for handlers to be registered (deterministic signal).
      await waitForHandlers(
        server,
        reason:
            'Handlers map must have entries before shutdown '
            '(otherwise the test proves nothing)',
      );

      await server.shutdown().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('shutdown hung'),
      );

      expect(
        server.handlers.values.every((list) => list.isEmpty),
        isTrue,
        reason: 'All handler lists should be empty after shutdown',
      );

      final settled = await Future.wait(streamFutures).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('streams hung'),
      );
      for (final result in settled) {
        expectExpectedRpcSettlement(
          result,
          reason:
              'named-pipe shutdown verifies map should '
              'settle with known result/error',
        );
      }
      await channel.shutdown();
    });

    testNamedPipe(
      'handlers at various lifecycle stages all terminate on shutdown',
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        await server.serve(pipeName: pipeName);
        addTearDown(() => server.shutdown());

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );
        addTearDown(() => channel.shutdown());
        final client = EchoClient(channel);

        final unaryResult = await client.echo(42);
        expect(unaryResult, equals(42));

        final serverStreamFuture = settleRpc(client.serverStream(255).toList());

        final bidiController = StreamController<int>();
        final bidiStreamFuture = settleRpc(
          client.bidiStream(bidiController.stream).toList(),
        );
        bidiController.add(1);

        final clientStreamController = StreamController<int>();
        final clientStreamFuture = settleRpc(
          client.clientStream(clientStreamController.stream),
        );
        clientStreamController.add(10);
        clientStreamController.add(20);

        // Wait for handlers to be registered (deterministic signal).
        await waitForHandlers(
          server,
          reason:
              'Handlers must be active before shutdown '
              '(named pipe mixed lifecycle test)',
        );

        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('shutdown hung with mixed lifecycle handlers'),
        );

        await bidiController.close();
        await clientStreamController.close();

        final settled =
            await Future.wait([
              serverStreamFuture,
              bidiStreamFuture,
              clientStreamFuture,
            ]).timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail('RPCs still active after shutdown'),
            );
        for (final result in settled) {
          expectExpectedRpcSettlement(
            result,
            reason:
                'named-pipe mixed lifecycle RPC should settle with known result/error',
          );
        }

        await channel.shutdown();
      },
    );

    testNamedPipe(
      'stress: repeated shutdown cycles cancel active handlers cleanly',
      (pipeName) async {
        const cycles = 16;
        const streamCount = 12;

        for (var cycle = 0; cycle < cycles; cycle++) {
          final server = NamedPipeServer.create(services: [EchoService()]);
          await server.serve(pipeName: pipeName);

          final channel = NamedPipeClientChannel(
            pipeName,
            options: const NamedPipeChannelOptions(),
          );
          final client = EchoClient(channel);

          final firstItems = List.generate(
            streamCount,
            (_) => Completer<void>(),
          );
          final doneCompleters = List.generate(
            streamCount,
            (_) => Completer<void>(),
          );
          final unexpectedErrors = <Object>[];

          try {
            for (var i = 0; i < streamCount; i++) {
              client
                  .serverStream(255)
                  .listen(
                    (value) {
                      if (!firstItems[i].isCompleted) firstItems[i].complete();
                    },
                    onError: (e) {
                      if (e is! GrpcError) unexpectedErrors.add(e);
                      if (!doneCompleters[i].isCompleted) {
                        doneCompleters[i].complete();
                      }
                    },
                    onDone: () {
                      if (!doneCompleters[i].isCompleted) {
                        doneCompleters[i].complete();
                      }
                    },
                  );
            }

            await Future.wait(firstItems.map((c) => c.future)).timeout(
              const Duration(seconds: 8),
              onTimeout: () =>
                  fail('Cycle $cycle: not all streams started before shutdown'),
            );

            final channelDelayMs = (cycle % 3) * 2;
            await Future.wait([
              server.shutdown(),
              Future<void>.delayed(
                Duration(milliseconds: channelDelayMs),
                () => channel.shutdown(),
              ),
            ]).timeout(
              const Duration(seconds: 10),
              onTimeout: () =>
                  fail('Cycle $cycle: shutdown race did not settle'),
            );

            await Future.wait(doneCompleters.map((c) => c.future)).timeout(
              const Duration(seconds: 5),
              onTimeout: () =>
                  fail('Cycle $cycle: streams still active after shutdown'),
            );

            expect(
              unexpectedErrors,
              isEmpty,
              reason:
                  'Cycle $cycle: expected stream termination errors '
                  'to be GrpcError only',
            );
            expect(
              server.handlers.values.every((list) => list.isEmpty),
              isTrue,
              reason: 'Cycle $cycle: handlers leaked after shutdown',
            );
          } finally {
            await channel.shutdown();
            await server.shutdown();
          }
        }
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Rapid start/shutdown cycles
  // ---------------------------------------------------------------------------
  group('Rapid server lifecycle', () {
    testTcpAndUds('20 rapid sequential start/shutdown cycles', (address) async {
      for (var cycle = 0; cycle < 20; cycle++) {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);
        final client = EchoClient(channel);

        final result = await client
            .echo(cycle)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail('echo hung on cycle $cycle'),
            );
        expect(result, equals(cycle));

        await channel.shutdown();
        await server.shutdown().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('shutdown hung on cycle $cycle'),
        );
      }
      // Reaching here without EMFILE, EADDRINUSE, or hangs is the test.
    });
  });

  // ---------------------------------------------------------------------------
  // Concurrent shutdown safety
  // ---------------------------------------------------------------------------
  group('Concurrent shutdown safety', () {
    testTcpAndUds('concurrent server.shutdown() calls are safe', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      // Start an active stream so shutdown has work to do.
      final streamFuture = settleRpc(client.serverStream(255).toList());

      // Wait for handlers to be registered (deterministic signal).
      await waitForHandlers(
        server,
        reason: 'Handler must be active before concurrent shutdown test',
      );

      // Call shutdown() 5 times concurrently — all must complete.
      await Future.wait([
        server.shutdown(),
        server.shutdown(),
        server.shutdown(),
        server.shutdown(),
        server.shutdown(),
      ]).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('concurrent shutdown() calls hung or deadlocked'),
      );

      final settled = await streamFuture.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('stream hung after shutdown'),
      );
      expectExpectedRpcSettlement(
        settled,
        reason:
            'concurrent shutdown stream should settle with known result/error',
      );
      await channel.shutdown();
    });
  });

  // -------------------------------------------------------------------
  // Extreme concurrency
  // -------------------------------------------------------------------
  group('Extreme concurrency', () {
    testTcpAndUds(
      '50 concurrent bidi streams with shutdown',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channel = createTestChannel(address, server.port!);
        addTearDown(() => channel.shutdown());
        final client = EchoClient(channel);

        // 50 bidi streams, each with its own controller.
        // Each handler blocks in await-for after the first
        // item, so all 50 are alive concurrently.
        const streamCount = 50;
        final controllers = <StreamController<int>>[];
        final streamFutures = <Future<Object?>>[];

        for (var i = 0; i < streamCount; i++) {
          final ctrl = StreamController<int>();
          controllers.add(ctrl);
          streamFutures.add(settleRpc(client.bidiStream(ctrl.stream).toList()));
          // Send one item so the handler starts processing.
          ctrl.add(i);
        }

        // Wait for handlers to be registered.
        await waitForHandlers(
          server,
          minCount: streamCount,
          timeout: const Duration(seconds: 15),
          reason:
              '50 bidi handlers must be registered '
              'before shutdown',
        );

        // Shutdown must cancel all 50 handlers.
        await server.shutdown().timeout(
          const Duration(seconds: 15),
          onTimeout: () => fail('server.shutdown() hung with 50 bidi streams'),
        );

        // Close all client-side controllers.
        for (final ctrl in controllers) {
          await ctrl.close();
        }

        // All 50 must settle without hanging.
        final settled = await Future.wait(streamFutures).timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail(
            '50 bidi streams did not settle after '
            'shutdown',
          ),
        );
        for (final result in settled) {
          expectExpectedRpcSettlement(
            result,
            reason:
                '50-bidi shutdown should settle with '
                'known result/error',
          );
        }

        await channel.shutdown();
      },
      udsTimeout: const Timeout(Duration(seconds: 90)),
    );

    testTcpAndUds('20 clients x 5 streams = 100 concurrent streams '
        'under shutdown', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      // 20 separate channels, 5 server-streams each.
      const clientCount = 20;
      const streamsPerClient = 5;
      final channels = <TestClientChannel>[];
      final allStreamFutures = <Future<Object?>>[];

      for (var c = 0; c < clientCount; c++) {
        final ch = createTestChannel(address, server.port!);
        channels.add(ch);
        addTearDown(() => ch.shutdown());
        final cl = EchoClient(ch);

        for (var s = 0; s < streamsPerClient; s++) {
          allStreamFutures.add(settleRpc(cl.serverStream(255).toList()));
        }
      }

      // Not all 100 may register before we proceed —
      // wait for a reasonable subset.
      await waitForHandlers(
        server,
        minCount: 50,
        timeout: const Duration(seconds: 15),
        reason:
            'At least 50 of 100 handlers must register '
            'before shutdown',
      );

      await server.shutdown().timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail(
          'server.shutdown() hung with 100 streams '
          'across 20 clients',
        ),
      );

      // All 100 must settle.
      final settled = await Future.wait(allStreamFutures).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('100 streams did not settle after shutdown'),
      );
      for (final result in settled) {
        expectExpectedRpcSettlement(
          result,
          reason:
              '100-stream multi-client shutdown should '
              'settle with known result/error',
        );
      }

      // All 20 channels must shutdown cleanly.
      await Future.wait(channels.map((ch) => ch.shutdown())).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('channel shutdown hung after server shutdown'),
      );
    }, udsTimeout: const Timeout(Duration(seconds: 90)));
  });
}
