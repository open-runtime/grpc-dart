// Copyright (c) 2024, the gRPC project authors. Please see the AUTHORS file
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

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:grpc/src/server/server_keepalive.dart';
import 'package:test/test.dart';

void main() {
  late StreamController pingStream;
  late StreamController dataStream;
  late int maxBadPings;

  var goAway = false;

  void initServer([ServerKeepAliveOptions? options]) => ServerKeepAlive(
    options:
        options ??
        ServerKeepAliveOptions(
          maxBadPings: maxBadPings,
          minIntervalBetweenPingsWithoutData: Duration(milliseconds: 5),
        ),
    pingNotifier: pingStream.stream,
    dataNotifier: dataStream.stream,
    tooManyBadPings: () async => goAway = true,
  ).handle();

  setUp(() {
    pingStream = StreamController();
    dataStream = StreamController();
    maxBadPings = 10;
    goAway = false;
  });

  tearDown(() {
    pingStream.close();
    dataStream.close();
  });

  test('Sending too many pings without data kills connection', () async {
    FakeAsync().run((async) {
      initServer();
      // Send first ping (starts timer).
      pingStream.sink.add(null);
      async.flushMicrotasks();

      // Send [maxBadPings] rapid pings (elapsed ≈ 0 < 5ms → bad).
      for (var i = 0; i < maxBadPings; i++) {
        pingStream.sink.add(null);
      }
      async.flushMicrotasks();
      expect(goAway, false);

      // Send another rapid bad ping; that's one too many!
      pingStream.sink.add(null);
      async.flushMicrotasks();
      expect(goAway, true);
    });
  });
  test(
    'Sending too many pings without data doesn`t kill connection if the server doesn`t care',
    () async {
      FakeAsync().run((async) {
        initServer(
          ServerKeepAliveOptions(
            maxBadPings: null,
            minIntervalBetweenPingsWithoutData: Duration(milliseconds: 5),
          ),
        );
        // Send first ping.
        pingStream.sink.add(null);
        async.flushMicrotasks();

        // Send a lot of rapid pings, that's still ok.
        for (var i = 0; i < 50; i++) {
          pingStream.sink.add(null);
        }
        async.flushMicrotasks();
        expect(goAway, false);
      });
    },
  );

  test('Sending many pings with data doesn`t kill connection', () async {
    FakeAsync().run((async) {
      initServer();

      // Send first ping (starts timer).
      pingStream.sink.add(null);
      async.flushMicrotasks();

      // Send [maxBadPings] rapid bad pings.
      for (var i = 0; i < maxBadPings; i++) {
        pingStream.sink.add(null);
      }
      async.flushMicrotasks();
      expect(goAway, false);

      // Sending data resets the bad ping count.
      dataStream.add(null);
      async.flushMicrotasks();

      // Send first ping after data reset (starts new timer).
      pingStream.sink.add(null);
      async.flushMicrotasks();

      // Send [maxBadPings] rapid bad pings.
      for (var i = 0; i < maxBadPings; i++) {
        pingStream.sink.add(null);
      }
      async.flushMicrotasks();
      expect(goAway, false);

      // Send another rapid bad ping; that's one too many!
      pingStream.sink.add(null);
      async.flushMicrotasks();
      expect(goAway, true);
    });
  });
}
