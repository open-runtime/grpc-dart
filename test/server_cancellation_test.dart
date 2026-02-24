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

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      // Start 10 concurrent server-streaming RPCs. Each streams 255
      // items at 10ms/item = ~2.5 seconds. We manually collect items
      // per-stream so we can use a concrete "first item arrived"
      // signal instead of a flaky time-based delay.
      final collectors = <List<int>>[];
      final doneCompleters = <Completer<void>>[];
      final firstItemSeen = Completer<void>();

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
                expect(e, isA<GrpcError>());
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
        onTimeout: () =>
            fail('No stream received any data — handlers may not have started'),
      );

      // Shutdown must cancel all 10 handlers and complete.
      await server.shutdown().timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            fail('server.shutdown() hung with 10 active streaming handlers'),
      );

      // All 10 streams must have terminated (not hung).
      await Future.wait(doneCompleters.map((c) => c.future)).timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('streams still active after shutdown'),
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

    testTcpAndUds('shutdown verifies handler map is fully emptied', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = createTestChannel(address, server.port!);
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

      await Future.delayed(const Duration(milliseconds: 50));

      // Verify handlers were registered BEFORE shutdown — this guards
      // against the vacuous truth where handlers.values is empty and
      // .every() trivially returns true.
      expect(
        server.handlers.isNotEmpty,
        isTrue,
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
      'handlers at various lifecycle stages all terminate on shutdown',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);
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

        // Let data flow.
        await Future.delayed(const Duration(milliseconds: 100));

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
                expect(e, isA<GrpcError>());
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

      await Future.delayed(const Duration(milliseconds: 50));

      expect(
        server.handlers.isNotEmpty,
        isTrue,
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

        await Future.delayed(const Duration(milliseconds: 100));

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

      await Future.delayed(const Duration(milliseconds: 50));

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
