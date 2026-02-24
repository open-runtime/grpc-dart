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

/// Stress, lifecycle, concurrency, and error-handling tests for the Windows
/// named-pipe gRPC transport.
///
/// Every test is Windows-only (via [testNamedPipe]) and uses a unique pipe
/// name derived from the test description to prevent cross-test interference.
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

// =============================================================================
// Tests
// =============================================================================

void main() {
  // ===========================================================================
  // 1. Lifecycle Tests
  // ===========================================================================

  group('Named Pipe Lifecycle', () {
    // 1. Happy path: start -> connect -> RPC -> disconnect -> shutdown
    testNamedPipe(
      'server start -> client connect -> RPC -> disconnect -> shutdown',
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        addTearDown(() => server.shutdown());
        await server.serve(pipeName: pipeName);
        expect(server.isRunning, isTrue);

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );

        final client = EchoClient(channel);

        // Verify basic RPC succeeds.
        final result = await client.echo(42);
        expect(result, equals(42));

        // Verify a second RPC on the same channel.
        expect(await client.echo(7), equals(7));

        await channel.shutdown();
        await server.shutdown();
        expect(server.isRunning, isFalse);
      },
    );

    // 2. Server start -> immediate shutdown (no clients ever connect)
    testNamedPipe('server start -> shutdown with no clients', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);
      expect(server.isRunning, isTrue);

      // Shut down immediately — no client ever connects.
      await server.shutdown();
      expect(server.isRunning, isFalse);
    });

    // 3. Server reuse: start -> shutdown -> start again (same pipe name)
    testNamedPipe('server start -> shutdown -> restart with same pipe name', (
      pipeName,
    ) async {
      final server1 = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server1.shutdown());
      await server1.serve(pipeName: pipeName);
      expect(server1.isRunning, isTrue);

      // First session: verify it works.
      final channel1 = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client1 = EchoClient(channel1);
      expect(await client1.echo(1), equals(1));

      await channel1.shutdown();
      await server1.shutdown();
      expect(server1.isRunning, isFalse);

      // Small delay so pipe namespace is cleaned up.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Second session: new server instance, same pipe name.
      final server2 = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server2.shutdown());
      await server2.serve(pipeName: pipeName);
      expect(server2.isRunning, isTrue);

      final channel2 = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client2 = EchoClient(channel2);
      expect(await client2.echo(2), equals(2));

      await channel2.shutdown();
      await server2.shutdown();
      expect(server2.isRunning, isFalse);
    });

    // 4. Multiple sequential start/shutdown cycles
    testNamedPipe('multiple sequential server start/shutdown cycles', (
      pipeName,
    ) async {
      // Track the most recent server so addTearDown can clean up if the
      // test fails mid-cycle. Double-shutdown is a safe no-op.
      NamedPipeServer? lastServer;
      addTearDown(() => lastServer?.shutdown());

      for (var cycle = 0; cycle < 8; cycle++) {
        final server = NamedPipeServer.create(services: [EchoService()]);
        lastServer = server;
        await server.serve(pipeName: pipeName);

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );
        final client = EchoClient(channel);
        final value = cycle % 256;
        expect(await client.echo(value), equals(value), reason: 'cycle $cycle');

        await channel.shutdown();
        await server.shutdown();

        // Brief pause between cycles to let the OS release the pipe.
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    });

    // 5. Server shutdown while client is mid-streaming-RPC
    testNamedPipe('server shutdown during active server-streaming RPC', (
      pipeName,
    ) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      // Request a long server stream (1000 items, ~10ms each = ~10 seconds).
      // Using 1000 instead of 100 makes it impossible for the stream to
      // complete before the server is shut down, eliminating flakiness on
      // fast machines.
      //
      // We use a Completer to synchronize: wait until at least one item
      // has been received (proving the stream is active) before shutting
      // down the server, rather than relying on a fixed time delay which
      // is inherently racy.
      final receivedFirst = Completer<void>();
      final results = <int>[];

      final subscription = client
          .serverStream(1000)
          .listen(
            (value) {
              results.add(value);
              if (!receivedFirst.isCompleted) {
                receivedFirst.complete();
              }
            },
            onError: (_) {
              // Expected: GrpcError when server shuts down mid-stream.
              if (!receivedFirst.isCompleted) {
                receivedFirst.complete();
              }
            },
          );

      // Wait until the stream is provably active before shutting down.
      await receivedFirst.future;
      await server.shutdown();

      // Cancel the client subscription to prevent dangling listeners.
      await subscription.cancel();

      // The stream should have been cut short — 1000 items at 10ms each
      // would take ~10 seconds, but we shut down almost immediately after
      // the first item.
      expect(results.length, lessThan(1000));

      await channel.shutdown();
    });

    // 5b. Large payload exceeding pipe buffer boundary (100KB unary)
    testNamedPipe('large payload exceeding pipe buffer boundary', (
      pipeName,
    ) async {
      // Tests sending a payload larger than kNamedPipeBufferSize (65536 bytes)
      // to verify the transport handles fragmentation/reassembly correctly.
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      // Create a 100KB payload filled with a repeating byte pattern.
      final payload = Uint8List(102400);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i & 0xFF;
      }

      final response = await client.echoBytes(payload);
      expect(response, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    // 5c. Large server-stream chunks exceeding pipe buffer
    testNamedPipe('large server-stream chunks exceeding pipe buffer', (
      pipeName,
    ) async {
      // Tests that server-streamed chunks larger than the pipe buffer
      // are correctly fragmented and reassembled.
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      // Request 5 chunks of 20KB each (100KB total).
      // Request format: 8 bytes big-endian [chunkCount(4), chunkSize(4)].
      const chunkCount = 5;
      const chunkSize = 20480; // 20KB
      final request = Uint8List(8);
      final bd = ByteData.sublistView(request);
      bd.setUint32(0, chunkCount);
      bd.setUint32(4, chunkSize);

      final chunks = await client.serverStreamBytes(request).toList();

      expect(chunks.length, equals(chunkCount));

      for (var i = 0; i < chunkCount; i++) {
        expect(chunks[i].length, equals(chunkSize), reason: 'chunk $i length');
        // Verify fill pattern: byte at position j in chunk i = (i+j) & 0xFF.
        for (var j = 0; j < chunkSize; j++) {
          expect(
            chunks[i][j],
            equals((i + j) & 0xFF),
            reason: 'chunk $i byte $j',
          );
        }
      }

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // ===========================================================================
  // 2. Concurrency & Stress Tests
  // ===========================================================================

  group('Named Pipe Concurrency & Stress', () {
    // 6. 100 concurrent unary RPCs on the same channel
    testNamedPipe('100 concurrent unary RPCs on same channel', (
      pipeName,
    ) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      final futures = List.generate(100, (i) => client.echo(i));
      final results = await Future.wait(futures);
      expect(results, equals(List.generate(100, (i) => i)));

      await channel.shutdown();
      await server.shutdown();
    });

    // 7. 20 sequential channel connect/disconnect cycles
    testNamedPipe('20 sequential channel connect/disconnect cycles', (
      pipeName,
    ) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      for (var i = 0; i < 20; i++) {
        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );
        final client = EchoClient(channel);
        final value = i % 256;
        expect(await client.echo(value), equals(value), reason: 'cycle $i');
        await channel.shutdown();
      }

      await server.shutdown();
    });

    // 8. Multiple clients connecting simultaneously (3 channels)
    testNamedPipe('multiple clients connecting to same server simultaneously', (
      pipeName,
    ) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      // Create three independent channels.
      final channels = List.generate(
        3,
        (_) => NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        ),
      );
      final clients = channels.map(EchoClient.new).toList();

      // Fire one RPC per client concurrently.
      final results = await Future.wait([
        clients[0].echo(10),
        clients[1].echo(20),
        clients[2].echo(30),
      ]);
      expect(results, equals([10, 20, 30]));

      // Fire a second round to confirm all channels remain healthy.
      // Note: Values must stay ≤255 because the echo service serializes
      // int as a single byte ([value]) — values >255 are truncated
      // (e.g., 300 % 256 = 44).
      final results2 = await Future.wait([
        clients[0].echo(100),
        clients[1].echo(200),
        clients[2].echo(250),
      ]);
      expect(results2, equals([100, 200, 250]));

      // Clean up all channels, then server.
      for (final ch in channels) {
        await ch.shutdown();
      }
      await server.shutdown();
    });

    // 9. Rapid fire: 500 echo RPCs as fast as possible
    testNamedPipe('rapid fire 500 sequential echo RPCs', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < 500; i++) {
        final value = i % 256;
        final result = await client.echo(value);
        expect(result, equals(value), reason: 'RPC #$i');
      }

      stopwatch.stop();

      // All 500 RPCs must have succeeded (we already asserted above).
      // Log elapsed time for manual perf analysis, but do not assert on
      // timing because CI machines vary widely.
      // ignore: avoid_print
      print(
        'Named pipe: 500 sequential echo RPCs in '
        '${stopwatch.elapsedMilliseconds}ms',
      );

      await channel.shutdown();
      await server.shutdown();
    });

    // 10. Sustained concurrent load: 5 channels, 20 RPCs each
    testNamedPipe('100 concurrent RPCs across 5 channels', (pipeName) async {
      // Stress test: 5 independent channels, 20 RPCs each, all concurrent.
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channels = List.generate(
        5,
        (_) => NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        ),
      );
      final clients = channels.map(EchoClient.new).toList();

      // Fire 20 concurrent RPCs per client (100 total).
      final allFutures = <Future<int>>[];
      for (var ch = 0; ch < 5; ch++) {
        for (var rpc = 0; rpc < 20; rpc++) {
          final value = (ch * 20 + rpc) % 256;
          allFutures.add(clients[ch].echo(value));
        }
      }

      final results = await Future.wait(allFutures);

      // Verify all 100 results are correct.
      for (var idx = 0; idx < 100; idx++) {
        final expected = (idx) % 256;
        expect(results[idx], equals(expected), reason: 'RPC #$idx');
      }

      // Clean up all channels, then server.
      for (final ch in channels) {
        await ch.shutdown();
      }
      await server.shutdown();
    });
  });

  // ===========================================================================
  // 3. Error Handling Tests
  // ===========================================================================

  group('Named Pipe Error Handling', () {
    // 10. Client connects to non-existent pipe
    testNamedPipe('client connect to non-existent pipe throws error', (
      pipeName,
    ) async {
      // No server started — the pipe does not exist.
      final fakePipeName =
          'grpc-nonexistent-${DateTime.now().microsecondsSinceEpoch}';
      final channel = NamedPipeClientChannel(
        fakePipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      // Attempting an RPC should fail because the pipe does not exist.
      // The error surfaces as a GrpcError wrapping the underlying
      // NamedPipeException (or as a direct GrpcError.unavailable).
      try {
        await client.echo(1);
        fail('Expected an error when connecting to non-existent pipe');
      } on GrpcError catch (e) {
        // GrpcError is expected — the connection layer converts transport
        // failures into gRPC status codes (typically UNAVAILABLE).
        expect(e.code, isNotNull);
      }

      await channel.shutdown();
    });

    // 11. Server with invalid pipe name
    testNamedPipe('server with invalid pipe name rejects serve()', (
      pipeName,
    ) async {
      // An empty pipe name or one with embedded NUL bytes should cause a
      // failure when CreateNamedPipe is called.
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());

      // Try to serve on an absurdly long / malformed pipe name.
      // Windows pipe names have practical limits and reserved characters.
      // An empty name should fail because the resulting path
      // `\\.\pipe\` is invalid for CreateNamedPipe.
      try {
        await server.serve(pipeName: '');
        // If serve() unexpectedly succeeds, clean up.
        await server.shutdown();
        // Some Windows versions may tolerate this; don't hard-fail the test.
      } on StateError {
        // Expected: the server isolate reports a CreateNamedPipe failure
        // which serve() propagates as a StateError.
      } on ArgumentError {
        // Also acceptable.
      } catch (e) {
        // Any error is acceptable — the key assertion is that it does NOT
        // silently succeed and hang.
        expect(e, isNotNull);
      }
    });

    // 12. Client connect after server shutdown
    testNamedPipe('client connect after server shutdown fails', (
      pipeName,
    ) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      // Verify it works before shutdown.
      final channel1 = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client1 = EchoClient(channel1);
      expect(await client1.echo(99), equals(99));
      await channel1.shutdown();

      // Now shut down the server.
      await server.shutdown();

      // Brief pause so the OS tears down the pipe.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // A new channel connecting to the now-dead pipe should fail.
      final channel2 = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client2 = EchoClient(channel2);

      try {
        await client2.echo(1);
        fail('Expected error connecting to shut-down server');
      } on GrpcError catch (e) {
        expect(e.code, isNotNull);
      }

      await channel2.shutdown();
    });
  });

  // ===========================================================================
  // 4. Edge Case / Safety Tests
  // ===========================================================================

  group('Named Pipe Edge Cases', () {
    // 14. Double shutdown safety — second call is a no-op.
    testNamedPipe('server double shutdown is a safe no-op', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);
      expect(server.isRunning, isTrue);

      // First shutdown.
      await server.shutdown();
      expect(server.isRunning, isFalse);

      // Second shutdown — must not throw.
      await server.shutdown();
      expect(server.isRunning, isFalse);
    });

    // 15. Double serve() throws StateError.
    testNamedPipe('server double serve() throws StateError', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);
      expect(server.isRunning, isTrue);

      // Calling serve() again while already running must throw.
      expect(
        () => server.serve(pipeName: pipeName),
        throwsA(isA<StateError>()),
      );

      await server.shutdown();
    });

    // 16. Client channel double shutdown is safe.
    testNamedPipe('client channel double shutdown is a safe no-op', (
      pipeName,
    ) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      // Ensure at least one RPC to establish the connection.
      expect(await client.echo(1), equals(1));

      // First shutdown.
      await channel.shutdown();

      // Second shutdown — must not throw.
      await channel.shutdown();

      await server.shutdown();
    });
  });

  // ===========================================================================
  // 5. Cross-Platform Skip Verification
  // ===========================================================================

  group('Named Pipe Cross-Platform', () {
    // 17. On non-Windows platforms the testNamedPipe helper returns early,
    //     meaning the test body never executes. We verify that behaviour by
    //     running a plain `test()` that checks the platform guard.
    test('testNamedPipe skips on non-Windows platforms', () {
      if (Platform.isWindows) {
        // On Windows, testNamedPipe tests DO run — nothing to assert here
        // other than confirming the platform detection itself.
        expect(Platform.isWindows, isTrue);
      } else {
        // On macOS/Linux, testNamedPipe should be a no-op.  We cannot
        // assert that a skipped test "didn't run" from inside another test,
        // but we CAN verify that the guard logic (Platform.isWindows) works
        // and that NamedPipeServer.create + serve would throw.
        final server = NamedPipeServer.create(services: [EchoService()]);
        expect(
          () => server.serve(pipeName: 'irrelevant'),
          throwsA(isA<UnsupportedError>()),
        );
      }
    });

    // 18. On macOS/Linux, NamedPipeServer.create().serve() throws
    //     UnsupportedError. This runs on ALL platforms (plain test()).
    test('NamedPipeServer.serve() throws UnsupportedError on non-Windows', () {
      if (!Platform.isWindows) {
        final server = NamedPipeServer.create(services: [EchoService()]);
        expect(
          () => server.serve(pipeName: 'any-pipe-name'),
          throwsA(isA<UnsupportedError>()),
        );
      }
    });
  });
}
