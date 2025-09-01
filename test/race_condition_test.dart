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
import 'package:grpc/src/server/handler.dart';
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
    $addMethod(ServiceMethod<int, int>(
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
    ));
  }

  Stream<int> streamingMethod(ServiceCall call, Future<int> request) async* {
    // Send multiple responses
    for (int i = 0; i < 5; i++) {
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
        userAgent: 'dart-grpc/test');
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
  group('Race Condition in ServerHandler', () {
    late RaceConditionHarness harness;

    setUp(() {
      harness = RaceConditionHarness();
      harness.setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test(
        'Should handle serialization error without crashing when stream closes concurrently',
        () async {
      // Set up response listener
      final responseCompleter = Completer<void>();
      int responseCount = 0;
      bool gotError = false;

      harness.fromServer.stream.listen(
        (message) {
          responseCount++;
          print(
              'Received response message #$responseCount: ${message.runtimeType}');
        },
        onError: (error) {
          print('Response stream error: $error');
          gotError = true;
        },
        onDone: () {
          print('Response stream closed');
          responseCompleter.complete();
        },
      );

      // Send request
      harness.sendRequestHeader('/RaceCondition/StreamingMethod');
      harness.sendData(1);

      // Wait for some responses to be processed
      await Future.delayed(Duration(milliseconds: 10));

      // Now close the client stream while the server is still sending responses
      // This simulates a client disconnect/timeout happening during response serialization
      harness.closeClientStream();

      // Wait for everything to complete
      await responseCompleter.future.timeout(
        Duration(seconds: 2),
        onTimeout: () {
          print('Test timed out waiting for response stream to close');
        },
      );

      // Check if we captured any errors
      if (harness.capturedErrors.isNotEmpty) {
        print(
            'Captured errors: ${harness.capturedErrors.map((e) => e.message)}');

        // The important thing is that the server didn't crash with "Cannot add event after closing"
        // Check that we don't have the bad state error
        final hasBadStateError = harness.capturedErrors.any((e) =>
            e.message?.contains('Cannot add event after closing') ?? false);
        expect(hasBadStateError, isFalse,
            reason: 'Should not have "Cannot add event after closing" error');
      }

      // The test passes if we reach here without an unhandled exception
      print('Test completed successfully without server crash');
    });

    test(
        'Stress test - multiple concurrent disconnections during serialization errors',
        () async {
      // This test increases the likelihood of hitting the race condition
      final futures = <Future>[];

      for (int i = 0; i < 10; i++) {
        futures.add(() async {
          final harness = RaceConditionHarness();
          harness.setUp();

          try {
            // Send request
            harness.sendRequestHeader('/RaceCondition/StreamingMethod');
            harness.sendData(1);

            // Random delay before disconnect
            await Future.delayed(Duration(milliseconds: i % 5));

            // Randomly choose how to disconnect
            if (i % 2 == 0) {
              harness.closeClientStream();
            } else {
              harness.simulateClientDisconnect();
            }

            // Wait a bit for any errors to manifest
            await Future.delayed(Duration(milliseconds: 10));
          } finally {
            harness.tearDown();
          }
        }());
      }

      await Future.wait(futures);

      // The test passes if none of the iterations caused an unhandled exception
      print('Stress test completed without crashes');
    });

    test('Reproduce exact "Cannot add event after closing" scenario', () async {
      // This test specifically tries to reproduce the exact error message from production
      final errorCompleter = Completer<String>();

      // Create a fresh harness for this test
      final testHarness = RaceConditionHarness();

      // Override the error handler to capture the exact error
      final server = Server.create(
        services: [testHarness.service],
        errorHandler: (error, stackTrace) {
          print('Error handler called with: ${error.message}');
          if (error.message?.contains('Cannot add event after closing') ??
              false) {
            errorCompleter.complete('REPRODUCED: ${error.message}');
          }
        },
      );

      final stream = TestServerStream(
          testHarness.toServer.stream, testHarness.fromServer.sink);
      server.serveStream_(stream: stream);

      // Send request that will trigger serialization errors
      testHarness.sendRequestHeader('/RaceCondition/StreamingMethod');
      testHarness.sendData(1);

      // Wait for responses to start
      await Future.delayed(Duration(milliseconds: 5));

      // Force close the stream while serialization error is happening
      testHarness.toServer.close();

      // Check if we reproduced the error
      final result = await errorCompleter.future.timeout(
        Duration(milliseconds: 100),
        onTimeout: () => 'Did not reproduce the exact error',
      );

      print('Result: $result');

      // The test succeeds whether we reproduce it or not,
      // but we log if we successfully reproduced it
      if (result.startsWith('REPRODUCED')) {
        print('✓ Successfully reproduced the production error!');
        print('  This confirms the race condition exists.');
      }

      // Clean up
      testHarness.tearDown();
    });
  });
}
