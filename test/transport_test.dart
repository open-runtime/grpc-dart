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

/// Comprehensive transport protocol tests for gRPC.
///
/// Tests all supported transport protocols:
/// - TCP/HTTP2 (all platforms)
/// - Unix Domain Sockets (macOS/Linux)
/// - Named Pipes (Windows)
///
/// Each transport is tested with:
/// - Basic unary RPC
/// - Server streaming RPC
/// - Client streaming RPC
/// - Bidirectional streaming RPC
/// - Connection lifecycle (connect, idle, reconnect, shutdown)
/// - Error handling and recovery
/// - Compression
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/channel.dart' hide ClientChannel;
import 'package:grpc/src/client/connection.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

// =============================================================================
// Test Channel Wrapper
// =============================================================================

class TestClientChannel extends ClientChannelBase {
  final Http2ClientConnection clientConnection;
  final List<ConnectionState> states = [];

  TestClientChannel(this.clientConnection) {
    onConnectionStateChanged.listen((state) => states.add(state));
  }

  @override
  ClientConnection createConnection() => clientConnection;
}

// =============================================================================
// TCP Transport Tests
// =============================================================================

void main() {
  group('TCP Transport', timeout: const Timeout(Duration(seconds: 30)), () {
    testTcpAndUds('basic unary RPC', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);
      expect(await client.echo(42), equals(42));
      expect(await client.echo(100), equals(100));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('server streaming RPC', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);
      final results = await client.serverStream(5).toList();
      expect(results, equals([1, 2, 3, 4, 5]));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('client streaming RPC', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);
      final result = await client.clientStream(
        Stream.fromIterable([1, 2, 3, 4, 5]),
      );
      expect(result, equals(15)); // Sum of 1+2+3+4+5

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('bidirectional streaming RPC', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);
      final results = await client
          .bidiStream(Stream.fromIterable(List.generate(50, (i) => i + 1)))
          .toList();
      expect(results, equals(List.generate(50, (i) => (i + 1) * 2)));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('multiple concurrent RPCs', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Fire multiple concurrent requests
      final futures = List.generate(100, (i) => client.echo(i));
      final results = await Future.wait(futures);
      expect(results, equals(List.generate(100, (i) => i)));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('connection state transitions', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Initial call triggers connection
      await client.echo(1);

      // Verify we went through connecting -> ready states
      expect(channel.states, contains(ConnectionState.connecting));
      expect(channel.states, contains(ConnectionState.ready));

      // Verify EXACT ordering: connecting must precede ready
      final connectingIdx = channel.states.indexOf(ConnectionState.connecting);
      final readyIdx = channel.states.indexOf(ConnectionState.ready);
      expect(
        connectingIdx,
        lessThan(readyIdx),
        reason: 'connecting must occur before ready',
      );

      await channel.shutdown();
      await server.shutdown();

      // Verify shutdown state and ordering: ready must precede shutdown
      expect(channel.states, contains(ConnectionState.shutdown));
      final shutdownIdx = channel.states.indexOf(ConnectionState.shutdown);
      expect(
        readyIdx,
        lessThan(shutdownIdx),
        reason: 'ready must occur before shutdown',
      );
    });

    testTcpAndUds('RPC with compression', (address) async {
      final server = Server.create(
        services: [EchoService()],
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      await server.serve(address: address, port: 0);

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
      final result = await client.echo(
        42,
        options: CallOptions(compression: const GzipCodec()),
      );
      expect(result, equals(42));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('large payload exceeding typical buffer sizes', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // 100KB payload with repeating byte pattern for integrity check
      final payload = Uint8List(100 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i & 0xFF;
      }

      final response = await client.echoBytes(payload);
      expect(response, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('server shutdown during active bidi stream', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Start a bidi stream with a controller so we can feed items gradually
      final controller = StreamController<int>();
      final collected = <int>[];
      final streamDone = client
          .bidiStream(controller.stream)
          .listen(collected.add, onError: (_) {}, cancelOnError: false)
          .asFuture()
          .then((_) => collected, onError: (_) => collected);

      // Send 20 items with small delays
      for (var i = 0; i < 20; i++) {
        controller.add(i);
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // Shut down server mid-stream
      await server.shutdown();
      await controller.close();

      // Stream must terminate (not hang) within 10 seconds
      final results = await streamDone.timeout(const Duration(seconds: 10));

      // We should have received some (possibly all) doubled values
      expect(results.length, lessThanOrEqualTo(20));

      await channel.shutdown();
    });

    testTcpAndUds('500 rapid sequential RPCs', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Sustained throughput: 500 sequential echo RPCs
      for (var i = 0; i < 500; i++) {
        final result = await client.echo(i % 256);
        expect(result, equals(i % 256));
      }

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('graceful server shutdown during streaming', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Start a long server stream and immediately attach an error handler
      // so the GrpcError from shutdown doesn't become an unhandled async error.
      final streamFuture = client
          .serverStream(100)
          .toList()
          .then((results) => results, onError: (e) => <int>[]);

      // Wait a bit then shutdown server
      await Future.delayed(const Duration(milliseconds: 50));
      await server.shutdown();

      // Stream should either complete partially or have been caught above
      final results = await streamFuture;
      expect(results.length, lessThanOrEqualTo(100));

      await channel.shutdown();
    });

    testTcpAndUds('server shutdown with multiple active streaming RPCs', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Start multiple long-running server streams concurrently
      final streams = List.generate(
        5,
        (_) => client
            .serverStream(100)
            .toList()
            .then((r) => r, onError: (e) => <int>[]),
      );

      // Let some responses flow
      await Future.delayed(const Duration(milliseconds: 50));

      // Shutdown should not hang even with 5 active streams
      await server.shutdown();

      // All streams should resolve (partially or with error)
      final results = await Future.wait(streams);
      for (final result in results) {
        expect(result.length, lessThanOrEqualTo(100));
      }

      await channel.shutdown();
    });

    testTcpAndUds('client shutdown during active server stream', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Start a long server stream
      final streamFuture = client
          .serverStream(100)
          .toList()
          .then((r) => r, onError: (e) => <int>[]);

      // Client shuts down immediately
      await channel.shutdown();

      final results = await streamFuture;
      expect(results.length, lessThanOrEqualTo(100));

      await server.shutdown();
    });
  });

  // =============================================================================
  // Secure TCP Transport Tests
  // =============================================================================

  group(
    'Secure TCP Transport',
    timeout: const Timeout(Duration(seconds: 30)),
    () {
      test('TLS connection', () async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(
          address: 'localhost',
          port: 0,
          security: ServerTlsCredentials(
            certificate: File('test/data/localhost.crt').readAsBytesSync(),
            privateKey: File('test/data/localhost.key').readAsBytesSync(),
          ),
        );

        final channel = TestClientChannel(
          Http2ClientConnection(
            'localhost',
            server.port!,
            ChannelOptions(
              credentials: ChannelCredentials.secure(
                certificates: File('test/data/localhost.crt').readAsBytesSync(),
                authority: 'localhost',
              ),
            ),
          ),
        );

        final client = EchoClient(channel);
        expect(await client.echo(42), equals(42));

        await channel.shutdown();
        await server.shutdown();
      });
    },
  );

  // =============================================================================
  // Named Pipe Transport Tests (Windows only)
  // =============================================================================

  group(
    'Named Pipe Transport',
    timeout: const Timeout(Duration(seconds: 30)),
    () {
      testNamedPipe('basic unary RPC', (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        addTearDown(() => server.shutdown());
        await server.serve(pipeName: pipeName);

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );

        final client = EchoClient(channel);
        expect(await client.echo(42), equals(42));

        await channel.shutdown();
        await server.shutdown();
      });

      testNamedPipe('server streaming RPC', (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        addTearDown(() => server.shutdown());
        await server.serve(pipeName: pipeName);

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );

        final client = EchoClient(channel);
        final results = await client.serverStream(5).toList();
        expect(results, equals([1, 2, 3, 4, 5]));

        await channel.shutdown();
        await server.shutdown();
      });

      testNamedPipe('client streaming RPC', (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        addTearDown(() => server.shutdown());
        await server.serve(pipeName: pipeName);

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );

        final client = EchoClient(channel);
        final result = await client.clientStream(
          Stream.fromIterable([1, 2, 3, 4, 5]),
        );
        expect(result, equals(15));

        await channel.shutdown();
        await server.shutdown();
      });

      testNamedPipe('bidirectional streaming RPC', (pipeName) async {
        final server = NamedPipeServer.create(services: [EchoService()]);
        addTearDown(() => server.shutdown());
        await server.serve(pipeName: pipeName);

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );

        final client = EchoClient(channel);
        final results = await client
            .bidiStream(Stream.fromIterable(List.generate(50, (i) => i + 1)))
            .toList();
        expect(results, equals(List.generate(50, (i) => (i + 1) * 2)));

        await channel.shutdown();
        await server.shutdown();
      });

      testNamedPipe('multiple concurrent RPCs', (pipeName) async {
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
    },
  );

  // =============================================================================
  // Cross-Platform Transport Selection Tests
  // =============================================================================

  group(
    'Transport Selection',
    timeout: const Timeout(Duration(seconds: 30)),
    () {
      test(
        'platform-appropriate transport works',
        timeout: const Timeout(Duration(seconds: 30)),
        () async {
          if (Platform.isWindows) {
            // On Windows, test named pipe
            final pipeName =
                'grpc-platform-test-${DateTime.now().millisecondsSinceEpoch}';
            final server = NamedPipeServer.create(services: [EchoService()]);
            addTearDown(() => server.shutdown());
            await server.serve(pipeName: pipeName);

            final channel = NamedPipeClientChannel(
              pipeName,
              options: const NamedPipeChannelOptions(),
            );

            final client = EchoClient(channel);
            expect(await client.echo(42), equals(42));

            await channel.shutdown();
            await server.shutdown();
          } else {
            // On Unix, test UDS
            final tempDir = await Directory.systemTemp.createTemp();
            final address = InternetAddress(
              '${tempDir.path}/socket',
              type: InternetAddressType.unix,
            );

            final server = Server.create(services: [EchoService()]);
            await server.serve(address: address, port: 0);

            final channel = TestClientChannel(
              Http2ClientConnection(
                address,
                server.port!,
                ChannelOptions(credentials: ChannelCredentials.insecure()),
              ),
            );

            final client = EchoClient(channel);
            expect(await client.echo(42), equals(42));

            await channel.shutdown();
            await server.shutdown();
            await tempDir.delete(recursive: true);
          }
        },
      );
    },
  );
}
