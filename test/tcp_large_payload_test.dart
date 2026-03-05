// Copyright (c) 2025, the gRPC project authors. Please see the AUTHORS file
// for details. All rights reserved.
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

/// Large payload tests for TCP and Unix domain socket transports.
///
/// Parallels the named pipe large payload tests but targets TCP/HTTP2 and
/// UDS transports. Verifies correct behavior for:
/// - Unary RPCs with payloads up to 1MB
/// - Server-streaming and bidirectional-streaming with large chunks
/// - Data integrity under concurrent load
/// - Compression with large payloads
@TestOn('vm')
@Timeout(Duration(seconds: 120))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

// =============================================================================
// Helpers
// =============================================================================

/// Generates a [Uint8List] of [size] bytes filled with the repeating pattern
/// `(seed + i) & 0xFF` for integrity verification.
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
  // Group 1: Unary Large Payloads
  // ===========================================================================

  group('Unary Large Payloads', () {
    // 1. 100KB payload echoed back via unary RPC.
    testTcpAndUds('100KB payload', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      final client = EchoClient(channel);

      final payload = generatePayload(102400); // 100KB
      final response = await client.echoBytes(payload);

      expect(response.length, equals(102400));
      expect(response, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    // 2. 256KB payload echoed back via unary RPC.
    testTcpAndUds('256KB payload', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      final client = EchoClient(channel);

      final payload = generatePayload(262144); // 256KB
      final response = await client.echoBytes(payload);

      expect(response.length, equals(262144));
      expect(response, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    // 3. 1MB payload echoed back via unary RPC.
    testTcpAndUds('1MB payload', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      final client = EchoClient(channel);

      final payload = generatePayload(1048576); // 1MB
      final response = await client.echoBytes(payload);

      expect(response.length, equals(1048576));
      expect(response, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // ===========================================================================
  // Group 2: Streaming Large Payloads
  // ===========================================================================

  group('Streaming Large Payloads', () {
    // 4. Server stream: 10 chunks of 10KB each.
    testTcpAndUds('server stream: 10 chunks x 10KB', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      final client = EchoClient(channel);

      // Build the 8-byte request: [chunkCount(4 BE), chunkSize(4 BE)].
      const chunkCount = 10;
      const chunkSize = 10240; // 10KB
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

    // 5. Server stream: 5 chunks of 100KB each.
    testTcpAndUds('server stream: 5 chunks x 100KB', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      final client = EchoClient(channel);

      const chunkCount = 5;
      const chunkSize = 102400; // 100KB
      final request = Uint8List(8);
      final bd = ByteData.sublistView(request);
      bd.setUint32(0, chunkCount);
      bd.setUint32(4, chunkSize);

      final chunks = await client.serverStreamBytes(request).toList();

      expect(chunks.length, equals(chunkCount));
      for (var i = 0; i < chunkCount; i++) {
        expect(chunks[i].length, equals(chunkSize), reason: 'chunk $i length');
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

    // 6. Bidi stream: 20 chunks of 8KB each, echoed back.
    testTcpAndUds('bidi stream: 20 x 8KB chunks', (address) async {
      final transport = address.type == InternetAddressType.unix
          ? 'UDS'
          : 'TCP';
      final sw = Stopwatch()..start();
      void log(String msg) => print(
        '[bidi-20x8KB/$transport '
        '${sw.elapsedMilliseconds}ms] $msg',
      );

      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());
      log('server on port ${server.port}');

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      final client = EchoClient(channel);

      const chunkCount = 20;
      const chunkSize = 8192; // 8KB

      // Build input chunks with unique patterns per chunk.
      final inputChunks = <Uint8List>[];
      for (var i = 0; i < chunkCount; i++) {
        inputChunks.add(generatePayload(chunkSize, i));
      }

      // Use a controller to feed chunks with event-loop yields.
      // Stream.fromIterable() delivers all items synchronously,
      // which can exhaust HTTP/2 flow-control windows on UDS,
      // causing deadlock.
      final ctrl20 = StreamController<List<int>>();
      var sent20 = 0;
      () async {
        for (final chunk in inputChunks) {
          ctrl20.add(chunk);
          sent20++;
          if (sent20 % 5 == 0) log('sent $sent20/$chunkCount');
          await Future.delayed(Duration.zero);
        }
        log('closing after $sent20 chunks');
        await ctrl20.close();
      }();

      log('awaiting bidi stream...');
      final responses = await client.bidiStreamBytes(ctrl20.stream).toList();
      log('received ${responses.length} responses');

      expect(responses.length, equals(chunkCount));
      for (var i = 0; i < chunkCount; i++) {
        expect(
          responses[i],
          equals(inputChunks[i]),
          reason: 'bidi chunk $i mismatch',
        );
      }

      log('shutting down...');
      await channel.shutdown();
      await server.shutdown();
      log('done');
    });

    // 7. Bidi stream: 5 chunks of 100KB each.
    testTcpAndUds('bidi stream: 5 x 100KB chunks', (address) async {
      final transport = address.type == InternetAddressType.unix
          ? 'UDS'
          : 'TCP';
      final sw = Stopwatch()..start();
      void log(String msg) => print(
        '[bidi-5x100KB/$transport '
        '${sw.elapsedMilliseconds}ms] $msg',
      );

      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());
      log('server on port ${server.port}');

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      final client = EchoClient(channel);

      const chunkCount = 5;
      const chunkSize = 102400; // 100KB

      final inputChunks = <Uint8List>[];
      for (var i = 0; i < chunkCount; i++) {
        inputChunks.add(generatePayload(chunkSize, i));
      }

      // Use a controller to feed chunks with event-loop yields.
      final ctrl100 = StreamController<List<int>>();
      var sent100 = 0;
      () async {
        for (final chunk in inputChunks) {
          ctrl100.add(chunk);
          sent100++;
          log('sent $sent100/$chunkCount (${chunkSize}B)');
          await Future.delayed(Duration.zero);
        }
        log('closing after $sent100 chunks');
        await ctrl100.close();
      }();

      log('awaiting bidi stream...');
      final responses = await client.bidiStreamBytes(ctrl100.stream).toList();
      log('received ${responses.length} responses');

      expect(responses.length, equals(chunkCount));
      for (var i = 0; i < chunkCount; i++) {
        expect(
          responses[i],
          equals(inputChunks[i]),
          reason: 'bidi chunk $i mismatch',
        );
      }

      log('shutting down...');
      await channel.shutdown();
      await server.shutdown();
      log('done');
    });
  });

  // ===========================================================================
  // Group 3: Data Integrity Under Pressure
  // ===========================================================================

  group('Data Integrity Under Pressure', () {
    // 8. Five concurrent 50KB echoBytes RPCs with unique seeds.
    //    Verifies no cross-contamination between concurrent payloads.
    testTcpAndUds('5 concurrent large payload RPCs', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      final client = EchoClient(channel);

      const payloadSize = 51200; // 50KB
      const concurrentCount = 5;

      // Generate payloads with unique seeds so they are distinguishable.
      final payloads = <Uint8List>[];
      for (var i = 0; i < concurrentCount; i++) {
        payloads.add(generatePayload(payloadSize, i * 37));
      }

      // Fire all RPCs concurrently.
      final futures = <Future<List<int>>>[];
      for (var i = 0; i < concurrentCount; i++) {
        futures.add(client.echoBytes(payloads[i]));
      }
      final results = await Future.wait(futures);

      // Verify each response matches its original payload exactly.
      for (var i = 0; i < concurrentCount; i++) {
        expect(
          results[i].length,
          equals(payloadSize),
          reason: 'response $i length',
        );
        expect(
          results[i],
          equals(payloads[i]),
          reason: 'response $i data mismatch — possible cross-contamination',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });

    // 9. Alternating large (50KB) and small (single int) payloads.
    //    Verifies the transport handles mixed payload sizes correctly.
    testTcpAndUds('alternating large and small payloads', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );
      final client = EchoClient(channel);

      const iterations = 10;
      const largeSize = 51200; // 50KB

      for (var i = 0; i < iterations; i++) {
        // Large payload RPC.
        final payload = generatePayload(largeSize, i);
        final largeResponse = await client.echoBytes(payload);
        expect(
          largeResponse,
          equals(payload),
          reason: 'large payload mismatch at iteration $i',
        );

        // Small payload RPC (single int echo).
        final smallResponse = await client.echo(i);
        expect(
          smallResponse,
          equals(i),
          reason: 'small payload mismatch at iteration $i',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });

    // 10. Large payload with gzip compression on both server and client.
    //     Verifies compression/decompression works correctly with 100KB.
    testTcpAndUds('large payload with compression', (address) async {
      final server = Server.create(
        services: [EchoService()],
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
          ),
        ),
      );
      final client = EchoClient(channel);

      final payload = generatePayload(102400); // 100KB
      final response = await client.echoBytes(
        payload,
        options: CallOptions(compression: const GzipCodec()),
      );

      expect(response.length, equals(102400));
      expect(response, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });
  });
}
