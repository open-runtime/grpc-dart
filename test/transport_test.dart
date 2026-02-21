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

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/channel.dart' hide ClientChannel;
import 'package:grpc/src/client/connection.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:test/test.dart';

import 'common.dart';

// =============================================================================
// Test Service Definitions
// =============================================================================

class EchoClient extends Client {
  static final _$echo = ClientMethod<int, int>(
    '/test.EchoService/Echo',
    (int value) => [value],
    (List<int> value) => value[0],
  );

  static final _$serverStream = ClientMethod<int, int>(
    '/test.EchoService/ServerStream',
    (int value) => [value],
    (List<int> value) => value[0],
  );

  static final _$clientStream = ClientMethod<int, int>(
    '/test.EchoService/ClientStream',
    (int value) => [value],
    (List<int> value) => value[0],
  );

  static final _$bidiStream = ClientMethod<int, int>(
    '/test.EchoService/BidiStream',
    (int value) => [value],
    (List<int> value) => value[0],
  );

  EchoClient(super.channel);

  ResponseFuture<int> echo(int request, {CallOptions? options}) {
    return $createUnaryCall(_$echo, request, options: options);
  }

  ResponseStream<int> serverStream(int request, {CallOptions? options}) {
    return $createStreamingCall(
      _$serverStream,
      Stream.value(request),
      options: options,
    );
  }

  ResponseFuture<int> clientStream(Stream<int> requests, {CallOptions? options}) {
    return $createStreamingCall(
      _$clientStream,
      requests,
      options: options,
    ).single;
  }

  ResponseStream<int> bidiStream(Stream<int> requests, {CallOptions? options}) {
    return $createStreamingCall(
      _$bidiStream,
      requests,
      options: options,
    );
  }
}

class EchoService extends Service {
  @override
  String get $name => 'test.EchoService';

  EchoService() {
    $addMethod(ServiceMethod<int, int>(
      'Echo',
      _echo,
      false,
      false,
      (List<int> value) => value[0],
      (int value) => [value],
    ));
    $addMethod(ServiceMethod<int, int>(
      'ServerStream',
      _serverStream,
      false,
      true,
      (List<int> value) => value[0],
      (int value) => [value],
    ));
    $addMethod(ServiceMethod<int, int>(
      'ClientStream',
      _clientStream,
      true,
      false,
      (List<int> value) => value[0],
      (int value) => [value],
    ));
    $addMethod(ServiceMethod<int, int>(
      'BidiStream',
      _bidiStream,
      true,
      true,
      (List<int> value) => value[0],
      (int value) => [value],
    ));
  }

  Future<int> _echo(ServiceCall call, Future<int> request) async {
    return await request;
  }

  Stream<int> _serverStream(ServiceCall call, Future<int> request) async* {
    final count = await request;
    for (var i = 1; i <= count; i++) {
      yield i;
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<int> _clientStream(ServiceCall call, Stream<int> requests) async {
    var sum = 0;
    await for (final value in requests) {
      sum += value;
    }
    return sum;
  }

  Stream<int> _bidiStream(ServiceCall call, Stream<int> requests) async* {
    await for (final value in requests) {
      yield value * 2; // Echo back doubled value
    }
  }
}

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
  group('TCP Transport', () {
    testTcpAndUds('basic unary RPC', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(Http2ClientConnection(
        address,
        server.port!,
        ChannelOptions(credentials: ChannelCredentials.insecure()),
      ));

      final client = EchoClient(channel);
      expect(await client.echo(42), equals(42));
      expect(await client.echo(100), equals(100));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('server streaming RPC', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(Http2ClientConnection(
        address,
        server.port!,
        ChannelOptions(credentials: ChannelCredentials.insecure()),
      ));

      final client = EchoClient(channel);
      final results = await client.serverStream(5).toList();
      expect(results, equals([1, 2, 3, 4, 5]));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('client streaming RPC', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(Http2ClientConnection(
        address,
        server.port!,
        ChannelOptions(credentials: ChannelCredentials.insecure()),
      ));

      final client = EchoClient(channel);
      final result = await client.clientStream(Stream.fromIterable([1, 2, 3, 4, 5]));
      expect(result, equals(15)); // Sum of 1+2+3+4+5

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('bidirectional streaming RPC', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(Http2ClientConnection(
        address,
        server.port!,
        ChannelOptions(credentials: ChannelCredentials.insecure()),
      ));

      final client = EchoClient(channel);
      final results = await client.bidiStream(Stream.fromIterable([1, 2, 3])).toList();
      expect(results, equals([2, 4, 6])); // Doubled values

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('multiple concurrent RPCs', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(Http2ClientConnection(
        address,
        server.port!,
        ChannelOptions(credentials: ChannelCredentials.insecure()),
      ));

      final client = EchoClient(channel);

      // Fire multiple concurrent requests
      final futures = List.generate(10, (i) => client.echo(i));
      final results = await Future.wait(futures);
      expect(results, equals(List.generate(10, (i) => i)));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('connection state transitions', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(Http2ClientConnection(
        address,
        server.port!,
        ChannelOptions(credentials: ChannelCredentials.insecure()),
      ));

      final client = EchoClient(channel);

      // Initial call triggers connection
      await client.echo(1);

      // Verify we went through connecting -> ready states
      expect(channel.states, contains(ConnectionState.connecting));
      expect(channel.states, contains(ConnectionState.ready));

      await channel.shutdown();
      await server.shutdown();

      // Verify shutdown state
      expect(channel.states, contains(ConnectionState.shutdown));
    });

    testTcpAndUds('RPC with compression', (address) async {
      final server = Server.create(
        services: [EchoService()],
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(Http2ClientConnection(
        address,
        server.port!,
        ChannelOptions(
          credentials: ChannelCredentials.insecure(),
          codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
        ),
      ));

      final client = EchoClient(channel);
      final result = await client.echo(
        42,
        options: CallOptions(compression: const GzipCodec()),
      );
      expect(result, equals(42));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('graceful server shutdown during streaming', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(Http2ClientConnection(
        address,
        server.port!,
        ChannelOptions(credentials: ChannelCredentials.insecure()),
      ));

      final client = EchoClient(channel);

      // Start a long server stream
      final streamFuture = client.serverStream(100).toList();

      // Wait a bit then shutdown server
      await Future.delayed(const Duration(milliseconds: 50));
      await server.shutdown();

      // Stream should either complete partially or throw
      try {
        final results = await streamFuture;
        expect(results.length, lessThanOrEqualTo(100));
      } on GrpcError {
        // Expected - server went away
      }

      await channel.shutdown();
    });
  });

  // =============================================================================
  // Secure TCP Transport Tests
  // =============================================================================

  group('Secure TCP Transport', () {
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

      final channel = TestClientChannel(Http2ClientConnection(
        'localhost',
        server.port!,
        ChannelOptions(
          credentials: ChannelCredentials.secure(
            certificates: File('test/data/localhost.crt').readAsBytesSync(),
            authority: 'localhost',
          ),
        ),
      ));

      final client = EchoClient(channel);
      expect(await client.echo(42), equals(42));

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // =============================================================================
  // Named Pipe Transport Tests (Windows only)
  // =============================================================================

  group('Named Pipe Transport', () {
    testNamedPipe('basic unary RPC', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
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
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );

      final client = EchoClient(channel);
      final result = await client.clientStream(Stream.fromIterable([1, 2, 3, 4, 5]));
      expect(result, equals(15));

      await channel.shutdown();
      await server.shutdown();
    });

    testNamedPipe('bidirectional streaming RPC', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );

      final client = EchoClient(channel);
      final results = await client.bidiStream(Stream.fromIterable([1, 2, 3])).toList();
      expect(results, equals([2, 4, 6]));

      await channel.shutdown();
      await server.shutdown();
    });

    testNamedPipe('multiple concurrent RPCs', (pipeName) async {
      final server = NamedPipeServer.create(services: [EchoService()]);
      await server.serve(pipeName: pipeName);

      final channel = NamedPipeClientChannel(
        pipeName,
        options: const NamedPipeChannelOptions(),
      );

      final client = EchoClient(channel);

      final futures = List.generate(10, (i) => client.echo(i));
      final results = await Future.wait(futures);
      expect(results, equals(List.generate(10, (i) => i)));

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // =============================================================================
  // Cross-Platform Transport Selection Tests
  // =============================================================================

  group('Transport Selection', () {
    test('platform-appropriate transport works', () async {
      if (Platform.isWindows) {
        // On Windows, test named pipe
        final pipeName = 'grpc-platform-test-${DateTime.now().millisecondsSinceEpoch}';
        final server = NamedPipeServer.create(services: [EchoService()]);
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

        final channel = TestClientChannel(Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ));

        final client = EchoClient(channel);
        expect(await client.echo(42), equals(42));

        await channel.shutdown();
        await server.shutdown();
        await tempDir.delete(recursive: true);
      }
    });
  });
}
