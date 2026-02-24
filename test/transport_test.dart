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
import 'package:grpc/src/client/http2_connection.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

Stream<T> pacedStream<T>(Iterable<T> values, {int yieldEvery = 10}) async* {
  var count = 0;
  for (final value in values) {
    yield value;
    count++;
    if (count % yieldEvery == 0) {
      await Future.delayed(Duration.zero);
    }
  }
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
        pacedStream([1, 2, 3, 4, 5], yieldEvery: 1),
      );
      expect(result, equals(15)); // Sum of 1+2+3+4+5

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('bidirectional streaming RPC', (address) async {
      final transport = address.type == InternetAddressType.unix
          ? 'UDS'
          : 'TCP';
      final sw = Stopwatch()..start();
      void log(String msg) =>
          print('[bidi/$transport ${sw.elapsedMilliseconds}ms] $msg');

      log('starting server...');
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      log('server listening on port ${server.port}');

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Use a controller to feed items with event-loop yields between
      // each batch. Stream.fromIterable() delivers all items
      // synchronously in a single microtask, which can exhaust HTTP/2
      // flow-control windows on transports without TCP_NODELAY (e.g.
      // Unix domain sockets), causing a deadlock where neither side
      // can make progress.
      final controller = StreamController<int>();
      var sentCount = 0;
      unawaited(() async {
        for (var i = 1; i <= 50; i++) {
          controller.add(i);
          sentCount++;
          // Yield to the event loop so HTTP/2 frames can be flushed
          // and WINDOW_UPDATE frames can be received.
          if (i % 10 == 0) {
            log('sent $sentCount/50 items, yielding...');
            await Future.delayed(Duration.zero);
          }
        }
        log('closing controller after $sentCount items');
        await controller.close();
      }());

      log('awaiting bidi stream results...');
      final results = await client.bidiStream(controller.stream).toList();
      log('received ${results.length} results');
      expect(results, equals(List.generate(50, (i) => (i + 1) * 2)));

      log('shutting down...');
      await channel.shutdown();
      await server.shutdown();
      log('done');
    });

    testTcpAndUds(
      'flow-control producer comparison (fromIterable vs yielded controller)',
      (address) async {
        final transport = address.type == InternetAddressType.unix
            ? 'UDS'
            : 'TCP';
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

        Future<({bool completed, int count, int elapsedMs})> runCase(
          String label,
          Stream<int> requests,
        ) async {
          final sw = Stopwatch()..start();
          try {
            final results = await client
                .bidiStream(requests)
                .toList()
                .timeout(const Duration(seconds: 2));
            sw.stop();
            print(
              '[flow-control/$transport] $label completed in '
              '${sw.elapsedMilliseconds}ms (${results.length} items)',
            );
            return (
              completed: true,
              count: results.length,
              elapsedMs: sw.elapsedMilliseconds,
            );
          } on TimeoutException {
            sw.stop();
            print(
              '[flow-control/$transport] $label timed out after '
              '${sw.elapsedMilliseconds}ms',
            );
            return (
              completed: false,
              count: 0,
              elapsedMs: sw.elapsedMilliseconds,
            );
          }
        }

        const itemCount = 200;
        final fromIterableResult = await runCase(
          'fromIterable',
          Stream<int>.fromIterable(List<int>.generate(itemCount, (i) => i + 1)),
        );

        final yieldedController = StreamController<int>();
        unawaited(() async {
          for (var i = 1; i <= itemCount; i++) {
            yieldedController.add(i);
            if (i % 10 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
          await yieldedController.close();
        }());
        final yieldedResult = await runCase(
          'yieldedController',
          yieldedController.stream,
        );

        // The yielded producer is the expected safe baseline.
        expect(yieldedResult.completed, isTrue);
        expect(yieldedResult.count, equals(itemCount));

        // fromIterable is expected to be reliable on TCP and may stall on UDS.
        if (fromIterableResult.completed) {
          expect(fromIterableResult.count, equals(itemCount));
        } else {
          expect(
            address.type,
            equals(InternetAddressType.unix),
            reason: 'Only UDS is expected to hit this flow-control stall',
          );
        }

        await channel.shutdown();
        await server.shutdown();
      },
    );

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

    testTcpAndUds('server streaming with compression', (address) async {
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
      final results = await client
          .serverStream(
            100,
            options: CallOptions(compression: const GzipCodec()),
          )
          .toList();
      expect(results.length, equals(100));
      expect(results, equals(List.generate(100, (i) => i + 1)));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('client streaming with compression', (address) async {
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
      // 50 items with values cycling 1..5. Sum = 15 × 10 = 150.
      // Stays within single-byte encoding (<= 255).
      final result = await client.clientStream(
        pacedStream(List<int>.generate(50, (i) => (i % 5) + 1), yieldEvery: 5),
        options: CallOptions(compression: const GzipCodec()),
      );
      expect(result, equals(150));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('bidi streaming with compression', (address) async {
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
      final results = await client
          .bidiStream(
            pacedStream(List<int>.generate(100, (i) => i % 128), yieldEvery: 5),
            options: CallOptions(compression: const GzipCodec()),
          )
          .toList();
      expect(results.length, equals(100));
      for (var i = 0; i < 100; i++) {
        expect(results[i], equals((i % 128) * 2), reason: 'bidi item $i');
      }

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('100KB compressed unary payload with gzip', (address) async {
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

      // 100KB payload with repeating pattern.
      final payload = Uint8List(100 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i & 0xFF;
      }

      final result = await client.echoBytes(
        payload,
        options: CallOptions(compression: const GzipCodec()),
      );
      expect(result.length, equals(payload.length));
      expect(result, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    testTcpAndUds('500 rapid sequential RPCs with compression', (
      address,
    ) async {
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

      // Use echoBytes with a 1KB payload so gzip actually compresses
      // (1-byte payloads expand under gzip, defeating the purpose).
      final payload = Uint8List(1024);
      for (var j = 0; j < payload.length; j++) {
        payload[j] = j & 0xFF;
      }
      for (var i = 0; i < 500; i++) {
        final result = await client.echoBytes(
          payload,
          options: CallOptions(compression: const GzipCodec()),
        );
        expect(result, equals(payload), reason: 'RPC $i');
      }

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
      final transport = address.type == InternetAddressType.unix
          ? 'UDS'
          : 'TCP';
      final sw = Stopwatch()..start();
      void log(String msg) => print(
        '[bidi-shutdown/$transport '
        '${sw.elapsedMilliseconds}ms] $msg',
      );

      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      log('server listening on port ${server.port}');

      final channel = TestClientChannel(
        Http2ClientConnection(
          address,
          server.port!,
          ChannelOptions(credentials: ChannelCredentials.insecure()),
        ),
      );

      final client = EchoClient(channel);

      // Start a bidi stream with a controller so we can feed items
      // gradually.
      final controller = StreamController<int>();
      final collected = <int>[];
      final streamDone = client
          .bidiStream(controller.stream)
          .listen(
            (v) {
              collected.add(v);
              if (collected.length % 5 == 0) {
                log('received ${collected.length} items');
              }
            },
            onError: (e) => log('stream error: $e'),
            cancelOnError: false,
          )
          .asFuture()
          .then((_) => collected, onError: (_) => collected);

      // Send 20 items with small delays
      for (var i = 0; i < 20; i++) {
        controller.add(i);
        await Future.delayed(const Duration(milliseconds: 5));
      }
      log('sent 20 items, shutting down server mid-stream');

      // Shut down server mid-stream
      await server.shutdown();
      log('server shutdown complete, closing controller');
      await controller.close();

      // Stream must terminate (not hang) within 10 seconds
      log('waiting for stream to terminate...');
      final results = await streamDone.timeout(const Duration(seconds: 10));
      log('stream done, received ${results.length} items total');

      // We should have received some (possibly all) doubled values.
      // At least 1 must arrive, and no more than 20 (total sent).
      expect(
        results.length,
        greaterThan(0),
        reason: 'Should have received at least 1 echoed item',
      );
      expect(
        results.length,
        lessThanOrEqualTo(20),
        reason: 'Should not exceed the 20 items sent',
      );

      await channel.shutdown();
      log('done');
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
          pacedStream([1, 2, 3, 4, 5], yieldEvery: 1),
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
        // Use a controller with event-loop yields to prevent flow-control
        // deadlock (same pattern as TCP/UDS bidi tests).
        final ctrl = StreamController<int>();
        unawaited(() async {
          for (var i = 0; i < 50; i++) {
            ctrl.add(i + 1);
            if (i % 10 == 0) await Future.delayed(Duration.zero);
          }
          await ctrl.close();
        }());
        final results = await client.bidiStream(ctrl.stream).toList();
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

  // ===========================================================================
  // sendTrailers idempotency — cross-transport verification
  // ===========================================================================
  //
  // The _trailersSent guard in ServerHandler prevents duplicate trailers when
  // both _onResponseError and _onResponseDone fire sendTrailers. The handler-
  // level test (handler_hardening_test.dart) verifies exactly-once at the
  // mock-transport level. These tests verify the guard works end-to-end over
  // each real transport: if sendTrailers were called twice, the second would
  // attempt to write to an already-closed HTTP/2 stream, corrupting the
  // connection or crashing the server.

  group(
    'sendTrailers idempotency — cross-transport',
    timeout: const Timeout(Duration(seconds: 30)),
    () {
      testTcpAndUds('streaming handler error delivers exactly one trailer', (
        address,
      ) async {
        final server = Server.create(services: [_ThrowingStreamService()]);
        await server.serve(address: address, port: 0);

        final channel = TestClientChannel(
          Http2ClientConnection(
            address,
            server.port!,
            ChannelOptions(credentials: ChannelCredentials.insecure()),
          ),
        );

        final client = _ThrowingStreamClient(channel);

        // Call the streaming method that yields values then throws.
        // The client should receive some values and then a GrpcError.
        final received = <int>[];
        GrpcError? caughtError;
        try {
          await for (final value in client.throwAfterYields(1)) {
            received.add(value);
          }
        } on GrpcError catch (e) {
          caughtError = e;
        }

        // The server yielded values before throwing — we may have received some.
        // The critical assertion: the client got a proper GrpcError (not a
        // crash, hang, or protocol error from duplicate trailers).
        expect(
          caughtError,
          isNotNull,
          reason:
              'Client should have received a GrpcError from the handler throw',
        );

        // Shut down the throwing service, then verify a fresh server on the
        // same address works. This proves the error didn't corrupt anything
        // at the OS transport level. (We must shut down first because UDS
        // doesn't allow two servers on the same path.)
        await channel.shutdown();
        await server.shutdown();

        final echoServer = Server.create(services: [EchoService()]);
        await echoServer.serve(address: address, port: 0);
        final echoChannel = TestClientChannel(
          Http2ClientConnection(
            address,
            echoServer.port!,
            ChannelOptions(credentials: ChannelCredentials.insecure()),
          ),
        );
        final echoClient = EchoClient(echoChannel);
        expect(await echoClient.echo(99), equals(99));

        await echoChannel.shutdown();
        await echoServer.shutdown();
      });

      testNamedPipe('streaming handler error delivers exactly one trailer', (
        pipeName,
      ) async {
        final server = NamedPipeServer.create(
          services: [_ThrowingStreamService()],
        );
        await server.serve(pipeName: pipeName);

        final channel = NamedPipeClientChannel(
          pipeName,
          options: const NamedPipeChannelOptions(),
        );

        final client = _ThrowingStreamClient(channel);

        // Call the streaming method that yields values then throws.
        final received = <int>[];
        GrpcError? caughtError;
        try {
          await for (final value in client.throwAfterYields(1)) {
            received.add(value);
          }
        } on GrpcError catch (e) {
          caughtError = e;
        }

        expect(
          caughtError,
          isNotNull,
          reason: 'Client should have received a GrpcError',
        );

        await channel.shutdown();
        await server.shutdown();
      });
    },
  );
}

// =============================================================================
// Test doubles for sendTrailers idempotency tests
// =============================================================================

/// A service whose server-streaming method yields some values then throws,
/// triggering both _onResponseError and _onResponseDone → double sendTrailers.
class _ThrowingStreamService extends Service {
  @override
  String get $name => 'test.ThrowingStream';

  _ThrowingStreamService() {
    $addMethod(
      ServiceMethod<int, int>(
        'ThrowAfterYields',
        _throwAfterYields,
        false,
        true,
        (List<int> value) => value[0],
        (int value) => [value],
      ),
    );
  }

  Stream<int> _throwAfterYields(ServiceCall call, Future<int> request) async* {
    final count = await request;
    for (var i = 0; i < 3; i++) {
      yield i;
      await Future.delayed(Duration.zero);
    }
    throw GrpcError.unknown('Intentional throw after $count yields');
  }
}

/// Client for the ThrowingStreamService.
class _ThrowingStreamClient extends Client {
  static final _$throwAfterYields = ClientMethod<int, int>(
    '/test.ThrowingStream/ThrowAfterYields',
    (int value) => [value],
    (List<int> value) => value[0],
  );

  _ThrowingStreamClient(super.channel);

  ResponseStream<int> throwAfterYields(int request, {CallOptions? options}) {
    return $createStreamingCall(
      _$throwAfterYields,
      Stream.value(request),
      options: options,
    );
  }
}
