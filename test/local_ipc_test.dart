// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba.,
// Pieces.app. All rights reserved.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'src/echo_service.dart';

void main() {
  group('validateServiceName', () {
    test('accepts valid names', () {
      expect(() => validateServiceName('my-service'), returnsNormally);
      expect(() => validateServiceName('my_service'), returnsNormally);
      expect(() => validateServiceName('my.service'), returnsNormally);
      expect(() => validateServiceName('MyService123'), returnsNormally);
      expect(() => validateServiceName('a'), returnsNormally);
      expect(() => validateServiceName('a' * 32), returnsNormally);
    });

    test('rejects empty name', () {
      expect(() => validateServiceName(''), throwsArgumentError);
    });

    test('rejects names longer than 32 chars', () {
      expect(() => validateServiceName('a' * 33), throwsArgumentError);
    });

    test('rejects names with invalid characters', () {
      expect(() => validateServiceName('my/service'), throwsArgumentError);
      expect(() => validateServiceName('my service'), throwsArgumentError);
      expect(() => validateServiceName('my:service'), throwsArgumentError);
      expect(() => validateServiceName(r'my\service'), throwsArgumentError);
      expect(() => validateServiceName('my@service'), throwsArgumentError);
    });
  });

  group('udsSocketPath', () {
    test('produces deterministic paths', () {
      final path1 = udsSocketPath('my-service');
      final path2 = udsSocketPath('my-service');
      expect(path1, equals(path2));
    });

    test('different names produce different paths', () {
      expect(udsSocketPath('service-a'), isNot(equals(udsSocketPath('service-b'))));
    });

    test('path ends with .sock', () {
      expect(udsSocketPath('my-service'), endsWith('.sock'));
    });

    test('path contains service name', () {
      expect(udsSocketPath('my-service'), contains('my-service'));
    });
  });

  group('defaultUdsDirectory', () {
    test('returns a non-empty path', () {
      expect(defaultUdsDirectory(), isNotEmpty);
    });

    test('path contains grpc-local', () {
      expect(defaultUdsDirectory(), contains('grpc-local'));
    });
  });

  group('LocalGrpcServer + LocalGrpcChannel end-to-end', () {
    test('unary RPC round-trip', () async {
      final server = LocalGrpcServer('local-ipc-test-unary', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      expect(server.isServing, isTrue);
      expect(server.address, isNotNull);

      final channel = LocalGrpcChannel('local-ipc-test-unary');
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);
      final response = await client.echo(42);
      expect(response, equals(42));
    });

    test('server-streaming RPC', () async {
      final server = LocalGrpcServer('local-ipc-test-stream', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      final channel = LocalGrpcChannel('local-ipc-test-stream');
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);
      final items = await client.serverStream(10).toList();
      expect(items, hasLength(10));
    });

    test('bidirectional streaming RPC', () async {
      final server = LocalGrpcServer('local-ipc-test-bidi', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      final channel = LocalGrpcChannel('local-ipc-test-bidi');
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);
      final controller = StreamController<int>();
      final responseFuture = client.bidiStream(controller.stream).toList();

      controller.add(1);
      controller.add(2);
      controller.add(3);
      await controller.close();

      final responses = await responseFuture;
      // EchoService._bidiStream doubles each value
      expect(responses, equals([2, 4, 6]));
    });

    test('multiple clients share one server', () async {
      final server = LocalGrpcServer('local-ipc-test-multi', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      final channels = List.generate(5, (_) => LocalGrpcChannel('local-ipc-test-multi'));
      addTearDown(() => Future.wait(channels.map((c) => c.shutdown())));

      final clients = channels.map(EchoClient.new).toList();
      final results = await Future.wait(clients.map((c) => c.echo(99)));
      expect(results, everyElement(equals(99)));
    });

    test('stale socket file is cleaned up automatically', () async {
      if (Platform.isWindows) return; // UDS only

      final socketPath = udsSocketPath('local-ipc-test-stale');
      final dir = Directory(defaultUdsDirectory());
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Create a stale file
      File(socketPath).writeAsStringSync('stale');
      expect(File(socketPath).existsSync(), isTrue);

      final server = LocalGrpcServer('local-ipc-test-stale', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      // Server should have replaced the stale file
      final channel = LocalGrpcChannel('local-ipc-test-stale');
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);
      expect(await client.echo(7), equals(7));
    });

    test('shutdown cleans up socket file', () async {
      if (Platform.isWindows) return; // UDS only

      final server = LocalGrpcServer('local-ipc-test-cleanup', services: [EchoService()]);
      await server.serve();

      final socketPath = server.address!;
      expect(File(socketPath).existsSync(), isTrue);

      await server.shutdown();
      expect(File(socketPath).existsSync(), isFalse);
    });

    test('isServing reflects state', () async {
      final server = LocalGrpcServer('local-ipc-test-state', services: [EchoService()]);
      expect(server.isServing, isFalse);

      await server.serve();
      expect(server.isServing, isTrue);

      await server.shutdown();
      expect(server.isServing, isFalse);
    });

    test('connectionServer exposes underlying server', () async {
      final server = LocalGrpcServer('local-ipc-test-cs', services: [EchoService()]);

      expect(() => server.connectionServer, throwsStateError);

      await server.serve();
      addTearDown(() => server.shutdown());

      expect(server.connectionServer, isA<ConnectionServer>());
    });

    test('double serve throws', () async {
      final server = LocalGrpcServer('local-ipc-test-double', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      expect(() => server.serve(), throwsStateError);
    });

    test('address property matches expected format', () async {
      final server = LocalGrpcServer('local-ipc-test-addr', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      if (Platform.isWindows) {
        expect(server.address, contains(r'\\.\pipe\'));
      } else {
        expect(server.address, endsWith('.sock'));
        expect(server.address, contains('local-ipc-test-addr'));
      }
    });

    test('channel address matches server address convention', () {
      final channel = LocalGrpcChannel('local-ipc-test-addr-match');
      addTearDown(() => channel.shutdown());

      if (Platform.isWindows) {
        expect(channel.address, contains(r'\\.\pipe\'));
      } else {
        expect(channel.address, endsWith('.sock'));
        expect(channel.address, contains('local-ipc-test-addr-match'));
      }
    });

    test('concurrent RPCs from multiple clients', () async {
      final server = LocalGrpcServer('local-ipc-test-concurrent', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      final channels = List.generate(3, (_) => LocalGrpcChannel('local-ipc-test-concurrent'));
      addTearDown(() => Future.wait(channels.map((c) => c.shutdown())));

      final clients = channels.map(EchoClient.new).toList();

      // 30 concurrent RPCs across 3 clients
      final futures = <Future<int>>[];
      for (var i = 0; i < 30; i++) {
        futures.add(clients[i % 3].echo(i));
      }
      final results = await Future.wait(futures);
      for (var i = 0; i < 30; i++) {
        expect(results[i], equals(i));
      }
    });

    test('maxInboundMessageSize rejects oversized requests', () async {
      final server = LocalGrpcServer(
        'local-ipc-test-size',
        services: [EchoService()],
        maxInboundMessageSize: 64, // Very small
      );
      await server.serve();
      addTearDown(() => server.shutdown());

      final channel = LocalGrpcChannel('local-ipc-test-size');
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);

      // Small message should work
      expect(await client.echo(1), equals(1));

      // 1KB payload exceeds 64-byte server limit → RESOURCE_EXHAUSTED
      final bigPayload = List<int>.filled(1024, 0xAB);
      try {
        await client.echoBytes(bigPayload);
        fail('Expected GrpcError for oversized message');
      } on GrpcError catch (e) {
        expect(e.code, equals(StatusCode.resourceExhausted));
      }
    });

    test('client gets UNAVAILABLE when server is not running', () async {
      final channel = LocalGrpcChannel('local-ipc-test-no-server');
      addTearDown(() => channel.terminate());

      final client = EchoClient(channel);
      try {
        await client.echo(1);
        fail('Expected GrpcError when server is not running');
      } on GrpcError catch (e) {
        expect(e.code, equals(StatusCode.unavailable));
      }
    });

    test('shutdown during active streaming RPC', () async {
      final server = LocalGrpcServer('local-ipc-test-shutdown-rpc', services: [EchoService()]);
      await server.serve();

      final channel = LocalGrpcChannel('local-ipc-test-shutdown-rpc');
      addTearDown(() => channel.terminate());

      final client = EchoClient(channel);

      // Start a server-streaming RPC (255 items with delays)
      final stream = client.serverStream(255);
      final received = <int>[];
      final sub = stream.listen(received.add, onError: (_) {});

      // Let a few items arrive
      await Future.delayed(Duration(milliseconds: 50));

      // Shutdown server while stream is active
      await server.shutdown();
      await sub.cancel();

      // We should have received some items before shutdown killed the stream
      expect(received, isNotEmpty);
    });

    test('client reconnects after server restart', () async {
      var server = LocalGrpcServer('local-ipc-test-reconnect', services: [EchoService()]);
      await server.serve();

      final channel = LocalGrpcChannel(
        'local-ipc-test-reconnect',
        options: LocalChannelOptions(
          backoffStrategy: (_) => Duration(milliseconds: 100),
        ),
      );
      addTearDown(() => channel.terminate());

      final client = EchoClient(channel);

      // First RPC succeeds
      expect(await client.echo(1), equals(1));

      // Kill the server
      await server.shutdown();

      // Restart on the same name
      server = LocalGrpcServer('local-ipc-test-reconnect', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      // Client should reconnect and succeed (may take a few retries)
      int? result;
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          result = await client.echo(2).timeout(Duration(seconds: 2));
          break;
        } on GrpcError {
          await Future.delayed(Duration(milliseconds: 200));
        } on TimeoutException {
          await Future.delayed(Duration(milliseconds: 200));
        }
      }
      expect(result, equals(2), reason: 'Client should reconnect after server restart');
    });

    test('connection state changes are observable', () async {
      final server = LocalGrpcServer('local-ipc-test-states', services: [EchoService()]);
      await server.serve();
      addTearDown(() => server.shutdown());

      final channel = LocalGrpcChannel('local-ipc-test-states');
      addTearDown(() => channel.terminate());

      final states = <ConnectionState>[];
      final sub = channel.onConnectionStateChanged.listen(states.add);
      addTearDown(() => sub.cancel());

      // Trigger connection via RPC
      final client = EchoClient(channel);
      await client.echo(1);

      // Should have transitioned through connecting -> ready
      expect(states, contains(ConnectionState.ready));
    });

    test('double shutdown is idempotent', () async {
      final server = LocalGrpcServer('local-ipc-test-double-shutdown', services: [EchoService()]);
      await server.serve();

      // Both should complete without error
      await server.shutdown();
      await server.shutdown();
    });

    test('invalid service name in channel throws', () {
      expect(() => LocalGrpcChannel(''), throwsArgumentError);
      expect(() => LocalGrpcChannel('has spaces'), throwsArgumentError);
      expect(() => LocalGrpcChannel('has/slash'), throwsArgumentError);
    });

    test('server interceptors are called', () async {
      var intercepted = false;

      final interceptor = _TrackingInterceptor(() => intercepted = true);
      final server = LocalGrpcServer(
        'local-ipc-test-intercept',
        services: [EchoService()],
        serverInterceptors: [interceptor],
      );
      await server.serve();
      addTearDown(() => server.shutdown());

      final channel = LocalGrpcChannel('local-ipc-test-intercept');
      addTearDown(() => channel.shutdown());

      final client = EchoClient(channel);
      await client.echo(1);

      expect(intercepted, isTrue);
    });
  });
}

class _TrackingInterceptor extends ServerInterceptor {
  final void Function() onIntercept;
  _TrackingInterceptor(this.onIntercept);

  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    onIntercept();
    return invoker(call, method, requests);
  }
}
