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

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

// =============================================================================
// Helpers
// =============================================================================

/// Deterministic wait for at least one handler to be registered on [server].
///
/// Replaces arbitrary `Future.delayed(milliseconds: N)` calls with a bounded
/// poll loop that checks the concrete `server.handlers` map. This ensures
/// tests advance as soon as the server has accepted and begun processing RPCs,
/// rather than guessing an appropriate sleep duration.
///
/// Throws a [TestFailure] if no handler appears within [timeout].
Future<void> waitForHandlers(
  ConnectionServer server, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'Handlers must be registered',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (server.handlers.values.every((list) => list.isEmpty) &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(
    server.handlers.values.any((list) => list.isNotEmpty),
    isTrue,
    reason: reason,
  );
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  // ---------------------------------------------------------------------------
  // Server.shutdown() with concurrent active handlers
  // ---------------------------------------------------------------------------
  group('Server.shutdown() with active handlers', () {
    testTcpAndUds('shutdown cancels 10 concurrent server-streaming handlers', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      // Start 10 concurrent server-streaming RPCs. Each streams 255
      // items at 10ms/item = ~2.5 seconds. We manually collect items
      // per-stream so we can use a concrete "all items arrived"
      // signal instead of a flaky time-based delay.
      const streamCount = 10;
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
      // This proves all 10 handlers are active and data is flowing.
      await Future.wait(perStreamFirstItem.map((c) => c.future)).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'Not all streams received data — '
          '${perStreamFirstItem.where((c) => c.isCompleted).length}'
          '/$streamCount started',
        ),
      );

      // Shutdown must cancel all 10 handlers and complete.
      await server.shutdown().timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            fail('server.shutdown() hung with 10 active streaming handlers'),
      );

      // All 10 streams must have terminated (not hung).
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

      // Start 5 concurrent streaming RPCs.
      final streamFutures = <Future<List<int>>>[];
      for (var i = 0; i < 5; i++) {
        streamFutures.add(
          client
              .serverStream(255)
              .toList()
              .then((r) => r, onError: (_) => <int>[]),
        );
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

      // Verify handler map is completely empty — no leaked references.
      // We already proved the map was non-empty above, so this is not
      // vacuously true.
      expect(
        server.handlers.values.every((list) => list.isEmpty),
        isTrue,
        reason: 'All handler lists should be empty after shutdown',
      );

      await Future.wait(streamFutures).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('streams hung'),
      );
      await channel.shutdown();
    });

    testTcpAndUds(
      'stress: repeated shutdown cycles cancel active handlers cleanly',
      (address) async {
        const cycles = 12;
        const streamCount = 6;

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
            await channel.shutdown().catchError((_) {});
            await server.shutdown().catchError((_) {});
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

        // (2) Server-stream mid-yield — streaming 255 items at 10ms each.
        final serverStreamFuture = client
            .serverStream(255)
            .toList()
            .then((r) => r, onError: (_) => <int>[]);

        // (3) Bidi stream — handler blocks in await-for after first item.
        final bidiController = StreamController<int>();
        final bidiStreamFuture = client
            .bidiStream(bidiController.stream)
            .toList()
            .then((r) => r, onError: (_) => <int>[]);
        bidiController.add(1); // send one item, handler processes it

        // (4) Client-stream — still accumulating.
        final clientStreamController = StreamController<int>();
        final clientStreamFuture = client
            .clientStream(clientStreamController.stream)
            .then((r) => r, onError: (_) => -1);
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
        await Future.wait([
          serverStreamFuture,
          bidiStreamFuture,
          clientStreamFuture,
        ]).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('RPCs still active after shutdown'),
        );

        await channel.shutdown();
      },
    );

    testNamedPipe('shutdown cancels 10 concurrent server-streaming handlers', (
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

      for (var i = 0; i < 10; i++) {
        final items = <int>[];
        collectors.add(items);
        final done = Completer<void>();
        doneCompleters.add(done);

        client
            .serverStream(255)
            .listen(
              (value) {
                items.add(value);
                if (!firstItemSeen.isCompleted) firstItemSeen.complete();
              },
              onError: (e) {
                // Complete the done completer FIRST to unblock
                // Future.wait (same rationale as TCP variant above).
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

      // Shutdown must cancel all 10 handlers and complete.
      await server.shutdown().timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'server.shutdown() hung with 10 active streaming handlers '
          '(named pipe)',
        ),
      );

      // All 10 streams must have terminated (not hung).
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

      final streamFutures = <Future<List<int>>>[];
      for (var i = 0; i < 5; i++) {
        streamFutures.add(
          client
              .serverStream(255)
              .toList()
              .then((r) => r, onError: (_) => <int>[]),
        );
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

      await Future.wait(streamFutures).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('streams hung'),
      );
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

        final serverStreamFuture = client
            .serverStream(255)
            .toList()
            .then((r) => r, onError: (_) => <int>[]);

        final bidiController = StreamController<int>();
        final bidiStreamFuture = client
            .bidiStream(bidiController.stream)
            .toList()
            .then((r) => r, onError: (_) => <int>[]);
        bidiController.add(1);

        final clientStreamController = StreamController<int>();
        final clientStreamFuture = client
            .clientStream(clientStreamController.stream)
            .then((r) => r, onError: (_) => -1);
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

        await Future.wait([
          serverStreamFuture,
          bidiStreamFuture,
          clientStreamFuture,
        ]).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('RPCs still active after shutdown'),
        );

        await channel.shutdown();
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Rapid start/shutdown cycles
  // ---------------------------------------------------------------------------
  group('Rapid server lifecycle', () {
    testTcpAndUds('10 rapid sequential start/shutdown cycles', (address) async {
      for (var cycle = 0; cycle < 10; cycle++) {
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
      final streamFuture = client
          .serverStream(255)
          .toList()
          .then((r) => r, onError: (_) => <int>[]);

      // Wait for handlers to be registered (deterministic signal).
      await waitForHandlers(
        server,
        reason: 'Handler must be active before concurrent shutdown test',
      );

      // Call shutdown() 3 times concurrently — all must complete.
      await Future.wait([
        server.shutdown(),
        server.shutdown(),
        server.shutdown(),
      ]).timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('concurrent shutdown() calls hung or deadlocked'),
      );

      await streamFuture.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('stream hung after shutdown'),
      );
      await channel.shutdown();
    });
  });
}
