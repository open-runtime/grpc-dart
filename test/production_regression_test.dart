// Copyright (c) 2026, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba.,
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
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:grpc/src/server/server_keepalive.dart';
import 'package:test/test.dart';

import 'src/echo_service.dart';

/// Production regression coverage for high-risk lifecycle paths.
///
/// This file focuses on regressions that can cause hangs, leaked handlers,
/// or unhandled transport errors under shutdown and keepalive pressure.
Future<void> _safeShutdown(ClientChannel channel) async {
  try {
    await channel.shutdown();
  } catch (error) {
    // Expected when a channel was already hard-terminated.
    if (error is! GrpcError && error is! StateError) rethrow;
  }
}

void main() {
  group('Server lifecycle regressions', () {
    test(
      'shutdown with active streaming handlers settles and empties map',
      () async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: 'localhost', port: 0);
        addTearDown(() => server.shutdown());

        final channel = ClientChannel(
          'localhost',
          port: server.port!,
          options: const ChannelOptions(
            credentials: ChannelCredentials.insecure(),
          ),
        );
        addTearDown(() => channel.shutdown());
        final client = EchoClient(channel);

        final firstItemSeen = Completer<void>();
        final subs = <StreamSubscription<int>>[];
        final unexpectedErrors = <Object>[];
        for (var i = 0; i < 5; i++) {
          final sub = client
              .serverStream(255)
              .listen(
                (_) {
                  if (!firstItemSeen.isCompleted) firstItemSeen.complete();
                },
                onError: (Object error) {
                  if (error is! GrpcError) unexpectedErrors.add(error);
                },
              );
          subs.add(sub);
        }

        await firstItemSeen.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            fail('streams never became active before shutdown');
          },
        );

        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            fail('server.shutdown() hung with active handlers');
          },
        );

        for (final sub in subs) {
          await sub.cancel();
        }
        expect(
          unexpectedErrors,
          isEmpty,
          reason: 'Expected only GrpcError stream termination signals',
        );

        expect(
          server.handlers.values.every((list) => list.isEmpty),
          isTrue,
          reason: 'handler map should be empty after shutdown cleanup',
        );
      },
    );

    test('server remains healthy after abrupt client termination', () async {
      final server = Server.create(
        services: [EchoService()],
        keepAliveOptions: const ServerKeepAliveOptions(
          maxBadPings: 2,
          minIntervalBetweenPingsWithoutData: Duration(milliseconds: 100),
        ),
      );
      await server.serve(address: 'localhost', port: 0);
      addTearDown(() => server.shutdown());

      final brokenChannel = ClientChannel(
        'localhost',
        port: server.port!,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      addTearDown(() => _safeShutdown(brokenChannel));
      final brokenClient = EchoClient(brokenChannel);
      expect(await brokenClient.echo(1), equals(1));
      await brokenChannel.terminate();

      final healthyChannel = ClientChannel(
        'localhost',
        port: server.port!,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      addTearDown(() => healthyChannel.shutdown());
      final healthyClient = EchoClient(healthyChannel);
      expect(await healthyClient.echo(42), equals(42));
    });

    test(
      'shutdown completes even with one broken and one active connection',
      () async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: 'localhost', port: 0);
        addTearDown(() => server.shutdown());

        final activeChannel = ClientChannel(
          'localhost',
          port: server.port!,
          options: const ChannelOptions(
            credentials: ChannelCredentials.insecure(),
          ),
        );
        addTearDown(() => activeChannel.shutdown());
        final activeClient = EchoClient(activeChannel);
        expect(await activeClient.echo(1), equals(1));

        final unexpectedErrors = <Object>[];
        final streamSub = activeClient
            .serverStream(100)
            .listen(
              (_) {},
              onError: (Object error) {
                if (error is! GrpcError) unexpectedErrors.add(error);
              },
            );

        final brokenChannel = ClientChannel(
          'localhost',
          port: server.port!,
          options: const ChannelOptions(
            credentials: ChannelCredentials.insecure(),
          ),
        );
        addTearDown(() => _safeShutdown(brokenChannel));
        final brokenClient = EchoClient(brokenChannel);
        expect(await brokenClient.echo(2), equals(2));
        await brokenChannel.terminate();

        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            fail('shutdown did not settle with broken connection present');
          },
        );

        await streamSub.cancel();
        expect(
          unexpectedErrors,
          isEmpty,
          reason: 'Expected only GrpcError stream termination signals',
        );
      },
    );
  });

  group('Client lifecycle regressions', () {
    test(
      'makeRequest on null transport throws unavailable instead of null crash',
      () async {
        final connection = Http2ClientConnection(
          'localhost',
          12345,
          const ChannelOptions(credentials: ChannelCredentials.insecure()),
        );
        addTearDown(() => connection.shutdown());

        expect(
          () => connection.makeRequest(
            '/test.EchoService/Echo',
            null,
            const <String, String>{},
            (Object error, StackTrace stackTrace) {},
            callOptions: CallOptions(),
          ),
          throwsA(
            isA<GrpcError>()
                .having((e) => e.code, 'code', StatusCode.unavailable)
                .having(
                  (e) => e.message,
                  'message',
                  contains('Connection not ready'),
                ),
          ),
        );
      },
    );
  });

  group('Keepalive regressions', () {
    test('tooManyBadPings callback fires only once under ping flood', () async {
      final pingController = StreamController<void>();
      final dataController = StreamController<void>();
      addTearDown(() async {
        await pingController.close();
        await dataController.close();
      });

      FakeAsync().run((async) {
        var tooManyBadPingsCalls = 0;
        ServerKeepAlive(
          options: const ServerKeepAliveOptions(
            maxBadPings: 1,
            minIntervalBetweenPingsWithoutData: Duration(milliseconds: 5),
          ),
          pingNotifier: pingController.stream,
          dataNotifier: dataController.stream,
          tooManyBadPings: () async {
            tooManyBadPingsCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 1));
          },
        ).handle();

        pingController.add(null); // baseline timestamp ping
        for (var i = 0; i < 20; i++) {
          pingController.add(null);
        }

        async.flushMicrotasks();
        expect(
          tooManyBadPingsCalls,
          equals(1),
          reason: 'keepalive termination callback should be idempotent',
        );
      });
    });
  });
}
