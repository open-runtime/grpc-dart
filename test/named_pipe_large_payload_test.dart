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

/// Large payload tests for the Windows named-pipe gRPC transport.
///
/// Named pipes have a 64KB buffer ([kNamedPipeBufferSize] = 65536). These tests
/// verify that payloads at, below, and far exceeding that boundary are
/// transported correctly without data corruption, truncation, or deadlock.
///
/// Every test is Windows-only (via [testNamedPipe]) and uses a unique pipe
/// name derived from the test description to prevent cross-test interference.
@TestOn('vm')
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

// =============================================================================
// Helpers
// =============================================================================

/// Generates a deterministic byte payload of [size] bytes.
///
/// Each byte is `(seed + index) & 0xFF`, producing a repeating 256-byte
/// pattern offset by [seed]. This makes it trivial to verify round-trip
/// integrity: if any byte is wrong, the index and expected value are
/// immediately obvious.
Uint8List generatePayload(int size, [int seed = 0]) {
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = (seed + i) & 0xFF;
  }
  return data;
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  // ===========================================================================
  // 1. Unary Large Payloads
  // ===========================================================================

  group('Unary Large Payloads', () {
    // -------------------------------------------------------------------------
    // Test 1: 64KB payload (exact pipe buffer size)
    // -------------------------------------------------------------------------
    // The named pipe buffer is exactly 65536 bytes. A payload of this size
    // will fill the buffer in a single write, exercising the boundary where
    // ReadFile returns exactly kNamedPipeBufferSize bytes. If the transport
    // mishandles the case where bytesRead == bufferSize (e.g., assumes more
    // data follows when there is none), this test will catch it.
    testNamedPipe('64KB payload (exact pipe buffer size)', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      final payload = generatePayload(65536);
      final result = await client.echoBytes(payload);

      expect(result.length, equals(65536));
      expect(result, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 2: 100KB payload (exceeds pipe buffer)
    // -------------------------------------------------------------------------
    // At 102400 bytes, this payload is ~1.56x the pipe buffer. The transport
    // must split the write across multiple WriteFile calls and reassemble
    // the data from multiple ReadFile calls. If the partial-write or
    // partial-read logic is incorrect, data will be truncated or corrupted.
    testNamedPipe('100KB payload (exceeds pipe buffer)', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      final payload = generatePayload(102400);
      final result = await client.echoBytes(payload);

      expect(result.length, equals(102400));
      expect(result, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 3: 256KB payload (4x pipe buffer)
    // -------------------------------------------------------------------------
    // At 262144 bytes (4 * 65536), this payload requires at least 4 full
    // buffer fills on the pipe. This exercises the transport's loop logic
    // for repeated partial reads/writes and verifies that no data is lost
    // or reordered across multiple buffer cycles.
    testNamedPipe('256KB payload (4x pipe buffer)', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      final payload = generatePayload(262144);
      final result = await client.echoBytes(payload);

      expect(result.length, equals(262144));
      expect(result, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 4: 512KB payload (large)
    // -------------------------------------------------------------------------
    // At 524288 bytes (8x the pipe buffer), this is a large stress test for
    // the transport. It requires ~8 full buffer cycles and pushes both the
    // HTTP/2 framing layer and the pipe's flow control hard. Reduced from
    // 1MB to stay within the 20-minute CI test budget on Windows runners.
    testNamedPipe('512KB payload (large)', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      final payload = generatePayload(524288);
      final result = await client.echoBytes(payload);

      expect(result.length, equals(524288));
      expect(result, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 5: Boundary payloads (buffer-1, buffer, buffer+1)
    // -------------------------------------------------------------------------
    // These three sizes target the exact byte boundaries where off-by-one
    // bugs hide in buffer management:
    //   - 65535 (buffer - 1): fits entirely in one buffer read, but leaves
    //     1 byte unused. If the transport uses >= instead of > for "is there
    //     more data?", it will issue a spurious extra read.
    //   - 65536 (buffer exactly): the boundary itself. ReadFile returns
    //     exactly bufferSize bytes. The transport must not assume this means
    //     "more data available" (which would be true for > bufferSize).
    //   - 65537 (buffer + 1): one byte overflows into a second read. If the
    //     transport does not correctly loop for the remaining 1 byte, it
    //     will be lost.
    testNamedPipe('boundary payloads: buffer-1, buffer, buffer+1', (
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

      // 65535 bytes: buffer - 1
      final payloadMinus = generatePayload(65535, 1);
      final resultMinus = await client.echoBytes(payloadMinus);
      expect(resultMinus.length, equals(65535));
      expect(resultMinus, equals(payloadMinus));

      // 65536 bytes: exact buffer size
      final payloadExact = generatePayload(65536, 2);
      final resultExact = await client.echoBytes(payloadExact);
      expect(resultExact.length, equals(65536));
      expect(resultExact, equals(payloadExact));

      // 65537 bytes: buffer + 1
      final payloadPlus = generatePayload(65537, 3);
      final resultPlus = await client.echoBytes(payloadPlus);
      expect(resultPlus.length, equals(65537));
      expect(resultPlus, equals(payloadPlus));

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // ===========================================================================
  // 2. Streaming Large Payloads
  // ===========================================================================

  group('Streaming Large Payloads', () {
    // -------------------------------------------------------------------------
    // Test 6: Server stream — 10 chunks x 10KB
    // -------------------------------------------------------------------------
    // Total transfer: 100KB across 10 messages. Each chunk is 10240 bytes,
    // well within a single pipe buffer, but the cumulative transfer exceeds
    // the buffer. This tests the transport's ability to handle many
    // sequential medium-sized messages without losing any.
    testNamedPipe('server stream: 10 chunks x 10KB', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      // Encode request: [chunkCount=10, chunkSize=10240] as 8 bytes BE.
      final bd = ByteData(8);
      bd.setUint32(0, 10);
      bd.setUint32(4, 10240);
      final request = bd.buffer.asUint8List();

      final chunks = await client.serverStreamBytes(request).toList();

      expect(chunks.length, equals(10));
      for (var i = 0; i < 10; i++) {
        expect(chunks[i].length, equals(10240), reason: 'chunk $i length');
        // Verify pattern: each byte is (chunkIndex + bytePos) & 0xFF.
        for (var j = 0; j < 10240; j++) {
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

    // -------------------------------------------------------------------------
    // Test 7: Server stream — 5 chunks x 64KB (at buffer boundary)
    // -------------------------------------------------------------------------
    // Each chunk is exactly kNamedPipeBufferSize (65536 bytes). This means
    // every individual message fills the pipe buffer completely. The server
    // must write each chunk, and the client must read it fully before the
    // next chunk can be written. Any flow control or backpressure bugs
    // will cause deadlock here.
    testNamedPipe('server stream: 5 chunks x 64KB (at buffer boundary)', (
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

      // Encode request: [chunkCount=5, chunkSize=65536] as 8 bytes BE.
      final bd = ByteData(8);
      bd.setUint32(0, 5);
      bd.setUint32(4, 65536);
      final request = bd.buffer.asUint8List();

      final chunks = await client.serverStreamBytes(request).toList();

      expect(chunks.length, equals(5));
      for (var i = 0; i < 5; i++) {
        expect(chunks[i].length, equals(65536), reason: 'chunk $i length');
        // Verify pattern: each byte is (chunkIndex + bytePos) & 0xFF.
        for (var j = 0; j < 65536; j++) {
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

    // -------------------------------------------------------------------------
    // Test 8: Server stream — 100 chunks x 1KB (many small chunks)
    // -------------------------------------------------------------------------
    // High-throughput test with 100 small messages (1024 bytes each). Total
    // transfer is only 100KB, but the per-message overhead (gRPC framing,
    // HTTP/2 headers) is significant relative to the payload. This stresses
    // the transport's message framing and demuxing paths under rapid
    // sequential delivery.
    testNamedPipe('server stream: 100 chunks x 1KB (many small chunks)', (
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

      // Encode request: [chunkCount=100, chunkSize=1024] as 8 bytes BE.
      final bd = ByteData(8);
      bd.setUint32(0, 100);
      bd.setUint32(4, 1024);
      final request = bd.buffer.asUint8List();

      final chunks = await client.serverStreamBytes(request).toList();

      expect(chunks.length, equals(100));
      for (var i = 0; i < 100; i++) {
        expect(chunks[i].length, equals(1024), reason: 'chunk $i length');
        // Verify pattern: each byte is (chunkIndex + bytePos) & 0xFF.
        for (var j = 0; j < 1024; j++) {
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

    // -------------------------------------------------------------------------
    // Test 9: Bidi stream — 20 x 8KB chunks
    // -------------------------------------------------------------------------
    // Sends 20 chunks of 8192 bytes each via bidirectional streaming. Each
    // chunk is echoed back unchanged. Total transfer: 160KB in each
    // direction (320KB round-trip). This verifies that bidi streaming
    // correctly handles medium-sized payloads without mixing up chunks
    // or losing data.
    testNamedPipe('bidi stream: 20 x 8KB chunks', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      // Build 20 chunks of 8KB each with unique patterns.
      final sentChunks = <Uint8List>[];
      for (var i = 0; i < 20; i++) {
        sentChunks.add(generatePayload(8192, i));
      }

      final inputController = StreamController<List<int>>();
      final responseStream = client.bidiStreamBytes(inputController.stream);

      // Collect responses.
      final receivedChunks = <List<int>>[];
      final streamDone = Completer<void>();
      responseStream.listen(
        receivedChunks.add,
        onError: (Object e) {
          if (!streamDone.isCompleted) streamDone.completeError(e);
        },
        onDone: () {
          if (!streamDone.isCompleted) streamDone.complete();
        },
      );

      // Send all chunks.
      for (final chunk in sentChunks) {
        inputController.add(chunk);
      }
      await inputController.close();

      // Wait for the stream to complete.
      await streamDone.future;

      expect(receivedChunks.length, equals(20));
      for (var i = 0; i < 20; i++) {
        expect(
          receivedChunks[i].length,
          equals(8192),
          reason: 'chunk $i length',
        );
        expect(
          receivedChunks[i],
          equals(sentChunks[i]),
          reason: 'chunk $i data mismatch',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 10: Bidi stream — 5 x 32KB chunks
    // -------------------------------------------------------------------------
    // Each chunk is 32768 bytes (~half the pipe buffer). The transport must
    // handle multi-message bidi streams where each message is substantial.
    // Reduced from 5x100KB to stay within the 20-minute CI test budget
    // on Windows runners while still exercising the bidi path meaningfully.
    testNamedPipe('bidi stream: 5 x 32KB chunks', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      // Build 5 chunks of 32KB each with unique patterns.
      final sentChunks = <Uint8List>[];
      for (var i = 0; i < 5; i++) {
        sentChunks.add(generatePayload(32768, i * 50));
      }

      final inputController = StreamController<List<int>>();
      final responseStream = client.bidiStreamBytes(inputController.stream);

      // Collect responses.
      final receivedChunks = <List<int>>[];
      final streamDone = Completer<void>();
      responseStream.listen(
        receivedChunks.add,
        onError: (Object e) {
          if (!streamDone.isCompleted) streamDone.completeError(e);
        },
        onDone: () {
          if (!streamDone.isCompleted) streamDone.complete();
        },
      );

      // Send all chunks.
      for (final chunk in sentChunks) {
        inputController.add(chunk);
      }
      await inputController.close();

      // Wait for the stream to complete.
      await streamDone.future;

      expect(receivedChunks.length, equals(5));
      for (var i = 0; i < 5; i++) {
        expect(
          receivedChunks[i].length,
          equals(32768),
          reason: 'chunk $i length',
        );
        expect(
          receivedChunks[i],
          equals(sentChunks[i]),
          reason: 'chunk $i data mismatch',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // ===========================================================================
  // 3. Data Integrity Under Pressure
  // ===========================================================================

  group('Data Integrity Under Pressure', () {
    // -------------------------------------------------------------------------
    // Test 11: Concurrent large payload RPCs
    // -------------------------------------------------------------------------
    // Fires 5 concurrent echoBytes calls, each with a different 20KB payload
    // seeded with a unique value. All 5 payloads are in-flight simultaneously
    // on the same channel (multiplexed as separate HTTP/2 streams over a
    // single pipe). If the transport's stream demuxing is incorrect, response
    // data will leak between streams (cross-request contamination). Each
    // response is verified against its specific request.
    testNamedPipe(
      'concurrent large payload RPCs (no cross-request contamination)',
      (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        addTearDown(() => server.shutdown());
        await server.serve(pipeName: pipeName);

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );
        final client = EchoClient(channel);

        // Create 5 payloads of 20KB each with different seeds.
        final payloads = <Uint8List>[];
        for (var i = 0; i < 5; i++) {
          payloads.add(generatePayload(20480, i * 37));
        }

        // Fire all 5 RPCs concurrently.
        final futures = <Future<List<int>>>[];
        for (var i = 0; i < 5; i++) {
          futures.add(client.echoBytes(payloads[i]));
        }

        final results = await Future.wait(futures);

        // Verify each response matches its specific request.
        for (var i = 0; i < 5; i++) {
          expect(results[i].length, equals(20480), reason: 'RPC $i length');
          expect(
            results[i],
            equals(payloads[i]),
            reason: 'RPC $i data mismatch (cross-request contamination?)',
          );
        }

        await channel.shutdown();
        await server.shutdown();
      },
    );

    // -------------------------------------------------------------------------
    // Test 12: Large payload followed by small payload
    // -------------------------------------------------------------------------
    // Sends a 200KB echoBytes, then immediately sends a tiny echo(42). This
    // tests that the transport correctly frames and separates messages of
    // vastly different sizes. If the large message's trailing bytes spill
    // into the small message's frame (or vice versa), one or both responses
    // will be corrupted. The small echo also verifies that the transport
    // recovers from the large transfer and is ready for normal-sized RPCs.
    testNamedPipe('large payload followed by small payload', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      // Send 200KB payload.
      final largePayload = generatePayload(204800);
      final largeResult = await client.echoBytes(largePayload);
      expect(largeResult.length, equals(204800));
      expect(largeResult, equals(largePayload));

      // Immediately send a tiny echo to verify the transport is clean.
      final smallResult = await client.echo(42);
      expect(smallResult, equals(42));

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 13: Alternating large and small payloads
    // -------------------------------------------------------------------------
    // 10 iterations alternating between echoBytes(50KB) and echo(i). This
    // exercises the transport's ability to handle rapid size transitions.
    // The HTTP/2 framing layer must correctly delimit each message regardless
    // of the preceding message's size. If there is any state leakage between
    // messages (e.g., a leftover partial-read buffer from the large message
    // corrupting the small message's frame header), this test will catch it.
    testNamedPipe('alternating large and small payloads', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      addTearDown(() => server.shutdown());
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );
      final client = EchoClient(channel);

      for (var i = 0; i < 10; i++) {
        // Large payload: 50KB with seed based on iteration.
        final largePayload = generatePayload(51200, i * 17);
        final largeResult = await client.echoBytes(largePayload);
        expect(
          largeResult.length,
          equals(51200),
          reason: 'iteration $i large payload length',
        );
        expect(
          largeResult,
          equals(largePayload),
          reason: 'iteration $i large payload data mismatch',
        );

        // Small payload: echo the iteration index.
        final smallResult = await client.echo(i);
        expect(
          smallResult,
          equals(i),
          reason: 'iteration $i small echo mismatch',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });
  });
}
