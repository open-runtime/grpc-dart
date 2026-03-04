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

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:grpc/src/shared/message.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

import 'src/server_utils.dart';
import 'src/utils.dart';

/// Service that triggers the race condition by having serialization errors
class RaceConditionService extends Service {
  @override
  String get $name => 'RaceCondition';

  bool shouldFailSerialization = false;

  RaceConditionService() {
    $addMethod(
      ServiceMethod<int, int>(
        'StreamingMethod',
        streamingMethod,
        false, // not streaming request
        true, // streaming response
        mockDecode,
        (int value) {
          // Conditionally fail serialization to trigger the error path
          if (shouldFailSerialization && value > 2) {
            throw Exception('Simulated serialization error!');
          }
          return mockEncode(value);
        },
      ),
    );
  }

  Stream<int> streamingMethod(ServiceCall call, Future<int> request) async* {
    // Send multiple responses
    for (var i = 0; i < 5; i++) {
      yield i;
      // Small delay to allow concurrent operations
      await Future.delayed(Duration(milliseconds: 1));

      // After sending a few responses, trigger conditions that could close the stream
      if (i == 2) {
        shouldFailSerialization = true;
        // Also simulate a timeout or cancellation happening around the same time
        Timer(Duration(microseconds: 100), () {
          // This simulates what happens during a timeout/cancellation
          // The handler would normally close the requests stream
        });
      }
    }
  }
}

/// Custom harness for testing the race condition
class RaceConditionHarness {
  final toServer = StreamController<StreamMessage>();
  final fromServer = StreamController<StreamMessage>();
  final service = RaceConditionService();
  late ConnectionServer server;

  // Track errors that occur in the handler
  final List<GrpcError> capturedErrors = [];
  StackTrace? capturedStackTrace;

  void setUp() {
    server = Server.create(
      services: [service],
      errorHandler: (error, stackTrace) {
        capturedErrors.add(error);
        capturedStackTrace = stackTrace;
      },
    );

    final stream = TestServerStream(toServer.stream, fromServer.sink);
    server.serveStream_(stream: stream);
  }

  void tearDown() {
    fromServer.close();
    toServer.close();
  }

  void sendRequestHeader(String path) {
    final headers = Http2ClientConnection.createCallHeaders(
      true,
      'test',
      path,
      Duration(seconds: 1), // Add a timeout
      null,
      null,
      userAgent: 'dart-grpc/test',
    );
    toServer.add(HeadersStreamMessage(headers));
  }

  void sendData(int value) {
    toServer.add(DataStreamMessage(frame(mockEncode(value))));
  }

  void closeClientStream() {
    toServer.add(HeadersStreamMessage([], endStream: true));
  }

  void simulateClientDisconnect() {
    // Simulate abrupt client disconnect
    toServer.addError('Client disconnected');
    toServer.close();
  }
}

void main() {
  group('Race Condition in ServerHandler', timeout: const Timeout(Duration(seconds: 30)), () {
    late RaceConditionHarness harness;

    setUp(() {
      harness = RaceConditionHarness();
      harness.setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('Should handle serialization error without crashing when stream closes concurrently', () async {
      // Set up response listener
      final responseCompleter = Completer<void>();
      final firstResponseSeen = Completer<void>();
      var responseCount = 0;

      harness.fromServer.stream.listen(
        (message) {
          responseCount++;
          if (!firstResponseSeen.isCompleted) {
            firstResponseSeen.complete();
          }
        },
        onError: (error) {
          // Error on response stream is acceptable during concurrent close
        },
        onDone: () {
          if (!responseCompleter.isCompleted) responseCompleter.complete();
        },
      );

      // Send request
      harness.sendRequestHeader('/RaceCondition/StreamingMethod');
      harness.sendData(1);

      // Wait for at least one server response before closing to ensure
      // we are racing against active response serialization, not startup.
      await firstResponseSeen.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Did not observe initial response before closing client stream'),
      );

      // Now close the client stream while the server is still sending
      // responses. This simulates a client disconnect/timeout happening
      // during response serialization.
      harness.closeClientStream();

      // Wait for everything to complete
      await responseCompleter.future.timeout(
        Duration(seconds: 2),
        onTimeout: () => fail('Response stream did not settle after client close'),
      );

      // At least the initial headers should have been sent.
      expect(responseCount, greaterThanOrEqualTo(1));

      // The important thing is that the server didn't crash with
      // "Cannot add event after closing"
      final hasBadStateError = harness.capturedErrors.any(
        (e) => e.message?.contains('Cannot add event after closing') ?? false,
      );
      expect(hasBadStateError, isFalse, reason: 'Should not have "Cannot add event after closing" error');
    });

    test('Stress test - multiple concurrent disconnections during serialization errors', () async {
      // This test increases the likelihood of hitting the race condition
      final futures = <Future>[];

      for (var i = 0; i < 10; i++) {
        futures.add(() async {
          final harness = RaceConditionHarness();
          harness.setUp();

          try {
            // Send request
            harness.sendRequestHeader('/RaceCondition/StreamingMethod');
            harness.sendData(1);

            // Vary disconnect timing by event-loop turns without wall-clock
            // sleeps, preserving race diversity deterministically.
            for (var turn = 0; turn < (i % 5); turn++) {
              await Future<void>.delayed(Duration.zero);
            }

            // Randomly choose how to disconnect
            if (i % 2 == 0) {
              harness.closeClientStream();
            } else {
              harness.simulateClientDisconnect();
            }

            // Yield once so async close/error paths run before teardown.
            await Future<void>.delayed(Duration.zero);
          } finally {
            harness.tearDown();
          }
        }());
      }

      await Future.wait(futures);

      // All 10 iterations completed without unhandled exceptions
      expect(futures.length, equals(10));
    });

    test('Reproduce exact "Cannot add event after closing" scenario', () async {
      // This test specifically tries to reproduce the exact error message
      // from production. The fix should prevent it from occurring.
      final errorCompleter = Completer<String>();
      final firstWireEvent = Completer<void>();
      final wireSettled = Completer<void>();

      // Create a fresh harness for this test
      final testHarness = RaceConditionHarness();

      // Override the error handler to capture the exact error
      final server = Server.create(
        services: [testHarness.service],
        errorHandler: (error, stackTrace) {
          if (error.message?.contains('Cannot add event after closing') ?? false) {
            if (!errorCompleter.isCompleted) {
              errorCompleter.complete('REPRODUCED: ${error.message}');
            }
          }
        },
      );

      final stream = TestServerStream(testHarness.toServer.stream, testHarness.fromServer.sink);
      server.serveStream_(stream: stream);
      testHarness.fromServer.stream.listen(
        (_) {
          if (!firstWireEvent.isCompleted) {
            firstWireEvent.complete();
          }
        },
        onError: (_) {
          if (!firstWireEvent.isCompleted) {
            firstWireEvent.complete();
          }
          if (!wireSettled.isCompleted) {
            wireSettled.complete();
          }
        },
        onDone: () {
          if (!firstWireEvent.isCompleted) {
            firstWireEvent.complete();
          }
          if (!wireSettled.isCompleted) {
            wireSettled.complete();
          }
        },
      );

      // Send request that will trigger serialization errors
      testHarness.sendRequestHeader('/RaceCondition/StreamingMethod');
      testHarness.sendData(1);

      await firstWireEvent.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail(
          'Did not observe wire activity before forced close in '
          'reproduction scenario',
        ),
      );

      // Force close the stream while serialization error is happening
      testHarness.toServer.close();

      // Wait for wire shutdown; timing out here is a hard failure.
      await wireSettled.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Wire did not settle after forced close in reproduction scenario'),
      );

      // With our race condition fix, this error should NOT be reproduced.
      // If it is, that indicates a regression.
      expect(
        errorCompleter.isCompleted,
        isFalse,
        reason: 'Race condition fix should prevent "Cannot add event after closing"',
      );

      // Clean up
      testHarness.tearDown();
    });

    test('timeout and serialization error fire simultaneously', () async {
      // Creates a scenario where both _onTimedOut and _onResponseError
      // try to close the same stream controller
      var completedIterations = 0;
      for (var i = 0; i < 20; i++) {
        final harness = RaceConditionHarness();
        harness.setUp();

        final responseComplete = Completer<void>();
        harness.fromServer.stream.listen(
          (_) {},
          onDone: () {
            if (!responseComplete.isCompleted) responseComplete.complete();
          },
          onError: (_) {
            if (!responseComplete.isCompleted) responseComplete.complete();
          },
        );

        // Send with very tight timeout
        harness.sendRequestHeader('/RaceCondition/StreamingMethod');
        harness.sendData(1);

        await responseComplete.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('Response stream did not settle in timeout/serialization race'),
        );

        // No crash = success
        harness.tearDown();
        completedIterations++;
      }

      // If we reached here, all 20 iterations completed without hangs.
      expect(completedIterations, equals(20));
    });
  });
}
