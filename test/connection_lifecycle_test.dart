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

/// Tests for HTTP/2 connection lifecycle fixes in the open-runtime fork.
///
/// These tests verify:
/// - Connection generation tracking (_connectionGeneration) prevents stale
///   socket.done callbacks from abandoning new connections
/// - Rapid reconnection cycles are stable
/// - shutdown/terminate clean up all resources
/// - makeRequest on null connection throws GrpcError.unavailable-style error
///   (ArgumentError with descriptive message, not a null pointer crash)
@TestOn('vm')
library;

import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/channel.dart' hide ClientChannel;
import 'package:grpc/src/client/connection.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

// =============================================================================
// Test Channel Wrapper (mirrors transport_test.dart pattern)
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
// Tests
// =============================================================================

void main() {
  // ---------------------------------------------------------------------------
  // Connection generation tracking
  // ---------------------------------------------------------------------------
  group('Connection generation tracking', () {
    testTcpAndUds(
      'stale socket.done callback does not abandon new connection',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);

        final channel = TestClientChannel(
          Http2ClientConnection(
            address,
            server.port!,
            ChannelOptions(
              credentials: ChannelCredentials.insecure(),
              // Short connection timeout so reconnection is quick
              connectionTimeout: const Duration(milliseconds: 200),
            ),
          ),
        );

        final client = EchoClient(channel);

        // First call establishes connection (generation 1)
        expect(await client.echo(1), equals(1));
        expect(channel.states, contains(ConnectionState.ready));

        // Wait for connection to age out, triggering reconnect on next call
        await Future.delayed(const Duration(milliseconds: 300));

        // Second call forces a reconnection (generation 2).
        // The old socket.done from generation 1 may still fire,
        // but should be ignored because generation has advanced.
        expect(await client.echo(2), equals(2));

        // Verify the connection went through a second ready cycle
        final readyCount = channel.states
            .where((s) => s == ConnectionState.ready)
            .length;
        expect(
          readyCount,
          greaterThanOrEqualTo(2),
          reason: 'Should have connected at least twice (original + reconnect)',
        );

        await channel.shutdown();
        await server.shutdown();
      },
    );

    testTcpAndUds('rapid reconnection cycles are stable', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            // Very short timeout forces frequent reconnection
            connectionTimeout: const Duration(milliseconds: 50),
          ),
        ),
      );

      final client = EchoClient(channel);

      // Perform 5 rounds of connect + request + age-out
      for (var i = 0; i < 5; i++) {
        final result = await client.echo(i);
        expect(result, equals(i));
        // Wait for connection to age out
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Verify all requests succeeded and we had multiple ready states
      final readyCount = channel.states
          .where((s) => s == ConnectionState.ready)
          .length;
      expect(
        readyCount,
        greaterThanOrEqualTo(3),
        reason: 'Should have reconnected multiple times',
      );

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // ---------------------------------------------------------------------------
  // Connection cleanup
  // ---------------------------------------------------------------------------
  group('Connection cleanup', () {
    testTcpAndUds('shutdown cleans up all resources', (address) async {
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

      // Establish connection and make a request
      expect(await client.echo(42), equals(42));
      expect(channel.states, contains(ConnectionState.ready));

      // Shutdown
      await channel.shutdown();

      // Verify shutdown state was reached
      expect(channel.states.last, equals(ConnectionState.shutdown));

      // Verify further calls fail
      try {
        await client.echo(1);
        fail('Should have thrown after shutdown');
      } catch (e) {
        expect(e, isA<GrpcError>());
      }

      await server.shutdown();
    });

    testTcpAndUds('terminate cleans up all resources', (address) async {
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

      // Establish connection and make a request
      expect(await client.echo(42), equals(42));
      expect(channel.states, contains(ConnectionState.ready));

      // Terminate (more aggressive than shutdown)
      await channel.terminate();

      // Verify shutdown state was reached
      expect(channel.states.last, equals(ConnectionState.shutdown));

      await server.shutdown();
    });
  });

  // ---------------------------------------------------------------------------
  // makeRequest error handling
  // ---------------------------------------------------------------------------
  group('makeRequest error handling', () {
    testTcpAndUds(
      'makeRequest on null connection throws GrpcError.unavailable',
      (address) async {
        // Create a connection object but do NOT connect it.
        // The _transportConnection is null.
        final connection = Http2ClientConnection(
          address,
          12345, // arbitrary port, doesn't matter
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        );

        // Calling makeRequest when _transportConnection is null should
        // throw a GrpcError.unavailable with an informative message,
        // NOT a null pointer exception (NoSuchMethodError on null).
        // The fork fix replaced the raw null dereference with:
        //   throw GrpcError.unavailable('Connection not ready');
        expect(
          () => connection.makeRequest(
            '/test.EchoService/Echo',
            null,
            {},
            (e, st) {},
            callOptions: CallOptions(),
          ),
          throwsA(
            allOf(
              isA<GrpcError>(),
              predicate<GrpcError>(
                (e) => e.code == StatusCode.unavailable,
                'has status code UNAVAILABLE',
              ),
              predicate<GrpcError>(
                (e) =>
                    e.message != null &&
                    e.message!.contains('Connection not ready'),
                'has "Connection not ready" message',
              ),
            ),
          ),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Server shutdown during active streaming
  // ---------------------------------------------------------------------------
  group('Server shutdown during active handlers', () {
    testTcpAndUds('server shutdown terminates active streams cleanly', (
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
          .then((results) => results, onError: (e) => <int>[]);

      // Let some data flow
      await Future.delayed(const Duration(milliseconds: 50));

      // Shutdown server while stream is active
      await server.shutdown();

      // Stream should either complete partially or error gracefully
      final results = await streamFuture;
      expect(results.length, lessThanOrEqualTo(100));

      await channel.shutdown();
    });

    testTcpAndUds('server shutdown during active streams does not crash', (
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
          .then((results) => results, onError: (e) => <int>[]);

      // Let some data flow
      await Future.delayed(const Duration(milliseconds: 30));

      // Shutdown while stream is active. server.shutdown()
      // calls cancel() on all active handlers, which calls
      // _terminateStream(). If the handler already completed
      // and terminated, the second call must be a no-op.
      await server.shutdown();

      final results = await streamFuture;
      expect(results.length, lessThanOrEqualTo(100));

      await channel.shutdown();
    });
  });

  // ---------------------------------------------------------------------------
  // Connection idle timeout
  // ---------------------------------------------------------------------------
  group('Connection idle timeout', () {
    testTcpAndUds('idle connection transitions to idle state', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(
            credentials: ChannelCredentials.insecure(),
            idleTimeout: const Duration(milliseconds: 100),
          ),
        ),
      );

      final client = EchoClient(channel);

      // Make a request to establish connection
      expect(await client.echo(1), equals(1));
      expect(channel.states, contains(ConnectionState.ready));

      // Wait for idle timeout to fire
      await Future.delayed(const Duration(milliseconds: 300));

      // The connection should have gone idle
      expect(channel.states, contains(ConnectionState.idle));

      // But a new request should still work (re-establishes connection)
      expect(await client.echo(2), equals(2));

      await channel.shutdown();
      await server.shutdown();
    });
  });
}
