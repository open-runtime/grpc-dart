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

/// Tests for server handler hardening fixes in the open-runtime fork.
///
/// These tests verify that the following fixes in handler.dart work correctly:
/// - sendTrailers double-call guard (_trailersSent flag)
/// - _onTimedOut TOCTOU safety (isCanceled + _requests!.isClosed checks)
/// - _onDataActive guards (try-catch around _requests!.add/addError/close)
/// - _onResponse safe error handling (try-catch in _onResponse)
/// - _terminateStream double-terminate guard (_streamTerminated flag)
@TestOn('vm')
library;

import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:grpc/src/shared/message.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

import 'src/server_utils.dart';
import 'src/utils.dart';

// =============================================================================
// Custom harness with error tracking
// =============================================================================

/// Extended harness that captures errors sent by the handler, allowing tests
/// to inspect error behavior without relying on the wire protocol alone.
class ErrorCapturingHarness {
  final toServer = StreamController<StreamMessage>();
  final fromServer = StreamController<StreamMessage>();
  final service = TestService();
  final interceptor = TestInterceptor();

  final List<GrpcError> capturedErrors = [];
  late ConnectionServer server;

  void setUp() {
    server = Server.create(
      services: [service],
      interceptors: [interceptor.call],
      errorHandler: (error, stackTrace) {
        capturedErrors.add(error);
      },
    );
    final stream = TestServerStream(toServer.stream, fromServer.sink);
    server.serveStream_(stream: stream);
  }

  void tearDown() {
    fromServer.close();
    toServer.close();
  }

  void sendRequestHeader(
    String path, {
    Duration? timeout,
    Map<String, String>? metadata,
  }) {
    final headers = Http2ClientConnection.createCallHeaders(
      true,
      'test',
      path,
      timeout,
      metadata,
      null,
      userAgent: 'dart-grpc/1.0.0 test',
    );
    toServer.add(HeadersStreamMessage(headers));
  }

  void sendData(int value) {
    toServer.add(DataStreamMessage(frame(mockEncode(value))));
  }
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  // ---------------------------------------------------------------------------
  // sendTrailers double-call guard
  // ---------------------------------------------------------------------------
  group('sendTrailers double-call guard', () {
    late ServerHarness harness;

    setUp(() {
      harness = ServerHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('sendTrailers is idempotent - second call sends exactly one trailer',
        () async {
      // A handler that throws a GrpcError. This triggers:
      //   _onResponseError -> _sendError -> sendTrailers (first call)
      //   The response stream ends -> _onResponseDone -> sendTrailers
      //     (second call, should be a no-op)
      //
      // Before the fix, the second sendTrailers would NPE on _customTrailers
      // because it was set to null by the first call.
      Stream<int> methodHandler(ServiceCall call, Future<int> request) async* {
        await request;
        throw GrpcError.internal('Intentional error');
      }

      final responseCompleter = Completer<void>();
      var trailerCount = 0;
      var totalMessageCount = 0;

      harness.fromServer.stream.listen(
        (message) {
          totalMessageCount++;
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            if (headers.containsKey('grpc-status')) {
              trailerCount++;
            }
          }
        },
        onError: (error) {
          // The TestServerStream.terminate() sends 'TERMINATED' as an error
        },
        onDone: () {
          responseCompleter.complete();
        },
      );

      harness.service.serverStreamingHandler = methodHandler;
      harness.sendRequestHeader('/Test/ServerStreaming');
      harness.sendData(1);
      harness.toServer.close();

      await responseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Timed out waiting for response'),
      );

      // The critical assertion: exactly ONE set of trailers was sent.
      // The _trailersSent guard must prevent the second sendTrailers call
      // from emitting a duplicate.
      expect(trailerCount, equals(1),
          reason: 'Expected exactly 1 trailer message with grpc-status, '
              'got $trailerCount (totalMessages=$totalMessageCount). '
              'The _trailersSent guard should prevent duplicate trailers.');
      // At least 1 total message (the trailer itself)
      expect(totalMessageCount, greaterThanOrEqualTo(1));
    });

    test('concurrent _onResponseDone and _sendError do not crash', () async {
      // A streaming handler that yields some values, then throws.
      // This triggers:
      //   _onResponseError -> _sendError -> sendTrailers (from the throw)
      //   _onResponseDone may also fire -> sendTrailers
      // Both paths must be safe.
      Stream<int> methodHandler(ServiceCall call, Future<int> request) async* {
        await request;
        yield 1;
        yield 2;
        // Introduce a microtask boundary so responses start flushing
        await Future.delayed(Duration.zero);
        throw GrpcError.unknown('Handler failure after yields');
      }

      final responseCompleter = Completer<void>();
      var trailerCount = 0;

      harness.fromServer.stream.listen(
        (message) {
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            if (headers.containsKey('grpc-status')) {
              trailerCount++;
            }
          }
        },
        onError: (_) {},
        onDone: () {
          if (!responseCompleter.isCompleted) {
            responseCompleter.complete();
          }
        },
      );

      harness.service.serverStreamingHandler = methodHandler;
      harness.sendRequestHeader('/Test/ServerStreaming');
      harness.sendData(1);
      harness.toServer.close();

      await responseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Timed out waiting for response'),
      );

      // Verify exactly one set of trailers was sent — the _trailersSent guard
      // must prevent the _onResponseDone path from sending a second trailer
      // after _onResponseError already sent one.
      expect(trailerCount, equals(1),
          reason: 'Expected exactly 1 trailer with grpc-status, got $trailerCount');
    });
  });

  // ---------------------------------------------------------------------------
  // _onTimedOut TOCTOU safety
  // ---------------------------------------------------------------------------
  group('_onTimedOut TOCTOU safety', () {
    late ServerHarness harness;

    setUp(() {
      harness = ServerHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('timeout during active streaming does not crash', () async {
      // A streaming handler that yields slowly. Combined with a very short
      // grpc-timeout, the _onTimedOut callback will fire while the stream
      // is still active, potentially racing with _onResponseDone.
      Stream<int> methodHandler(ServiceCall call, Future<int> request) async* {
        await request;
        for (var i = 0; i < 100; i++) {
          yield i;
          // Slow enough that the 1us timeout will fire mid-stream
          await Future.delayed(const Duration(milliseconds: 5));
          if (call.isCanceled) return;
        }
      }

      final responseCompleter = Completer<void>();
      var sawDeadlineExceeded = false;

      harness.fromServer.stream.listen(
        (message) {
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            if (headers['grpc-status'] != null) {
              final status = int.tryParse(headers['grpc-status']!);
              if (status == StatusCode.deadlineExceeded) {
                sawDeadlineExceeded = true;
              }
            }
          }
        },
        onError: (_) {},
        onDone: () {
          if (!responseCompleter.isCompleted) {
            responseCompleter.complete();
          }
        },
      );

      harness.service.serverStreamingHandler = methodHandler;
      // Send with a 1 microsecond timeout
      harness.sendRequestHeader(
        '/Test/ServerStreaming',
        timeout: const Duration(microseconds: 1),
      );
      harness.sendData(1);
      harness.toServer.close();

      await responseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Timed out waiting for response'),
      );

      // The timeout should have fired and produced a deadline-exceeded error
      expect(sawDeadlineExceeded, isTrue);
    });

    test('timeout after stream closure is safe', () async {
      // A unary handler that completes very quickly. The timeout is set to
      // a short but non-zero duration so it fires AFTER the handler is done.
      // The _onTimedOut callback should be a no-op because isCanceled is set
      // or the stream is already closed.
      Future<int> methodHandler(ServiceCall call, Future<int> request) async {
        return await request;
      }

      final responseCompleter = Completer<void>();
      var sawOkStatus = false;

      harness.fromServer.stream.listen(
        (message) {
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            if (headers['grpc-status'] == '0') {
              sawOkStatus = true;
            }
          }
        },
        onError: (_) {},
        onDone: () {
          if (!responseCompleter.isCompleted) {
            responseCompleter.complete();
          }
        },
      );

      harness.service.unaryHandler = methodHandler;
      // 50ms timeout - handler completes almost instantly,
      // so timeout fires on an already-closed stream
      harness.sendRequestHeader(
        '/Test/Unary',
        timeout: const Duration(milliseconds: 50),
      );
      harness.sendData(42);
      harness.toServer.close();

      await responseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Timed out waiting for response'),
      );

      // Give the timeout timer a chance to fire after the stream closed
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify the normal response completed successfully before the timer fired
      expect(sawOkStatus, isTrue,
          reason: 'Handler should have completed with OK status before timeout fired');
    });
  });

  // ---------------------------------------------------------------------------
  // _onDataActive guards
  // ---------------------------------------------------------------------------
  group('_onDataActive guards', () {
    late ErrorCapturingHarness harness;

    setUp(() {
      harness = ErrorCapturingHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('data arriving after stream closure is handled gracefully', () async {
      // A handler that immediately throws an error. This causes
      // _sendError -> sendTrailers which closes things down. Meanwhile,
      // more data frames arrive from the client. Before the fix, adding
      // to the closed _requests stream would throw
      // "Cannot add event after closing".
      Stream<int> methodHandler(ServiceCall call, Stream<int> request) async* {
        // Read the first message then throw
        await for (final value in request) {
          throw GrpcError.internal('Immediate failure on value $value');
        }
      }

      final responseCompleter = Completer<void>();

      harness.fromServer.stream.listen(
        (_) {},
        onError: (_) {},
        onDone: () {
          if (!responseCompleter.isCompleted) {
            responseCompleter.complete();
          }
        },
      );

      harness.service.bidirectionalHandler = methodHandler;
      harness.sendRequestHeader('/Test/Bidirectional');

      // Send first data to trigger the handler
      harness.sendData(1);

      // Small delay to let the error propagate and close the stream
      await Future.delayed(const Duration(milliseconds: 10));

      // Send more data after the error has likely closed the requests stream.
      // Before the fix, this would cause "Cannot add event after closing".
      harness.sendData(2);
      harness.sendData(3);

      // Close the client stream
      harness.toServer.close();

      await responseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Timed out waiting for response'),
      );

      // The key assertion: we reached here without an unhandled StateError
      // crashing the test. Before the fix, sending data to a closed
      // _requests stream would throw "Cannot add event after closing" as
      // an unhandled exception. The try-catch guards in _onDataActive
      // now catch this and log it via logGrpcError (not the error handler),
      // so the test completing is itself the proof.
      //
      // Additionally verify the handler's intentional error was reported:
      expect(
        harness.capturedErrors.any(
          (e) => e.message?.contains('Immediate failure') ?? false,
        ),
        isTrue,
        reason: 'Handler should have reported the intentional GrpcError',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // _terminateStream double-terminate guard
  // ---------------------------------------------------------------------------
  group('_terminateStream double-terminate guard', () {
    late ServerHarness harness;

    setUp(() {
      harness = ServerHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('server shutdown after normal completion does not crash', () async {
      // A handler that completes normally. After it finishes, we also
      // call cancel() which calls _terminateStream().
      // The stream was already terminated by the normal completion path,
      // so the second terminate must be a no-op.
      Future<int> methodHandler(ServiceCall call, Future<int> request) async {
        return await request;
      }

      final responseCompleter = Completer<void>();
      var sawOkStatus = false;

      harness.fromServer.stream.listen(
        (message) {
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            if (headers['grpc-status'] == '0') {
              sawOkStatus = true;
            }
          }
        },
        onError: (_) {},
        onDone: () {
          if (!responseCompleter.isCompleted) {
            responseCompleter.complete();
          }
        },
      );

      harness.service.unaryHandler = methodHandler;
      harness.sendRequestHeader('/Test/Unary');
      harness.sendData(42);
      harness.toServer.close();

      await responseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Timed out waiting for response'),
      );

      expect(sawOkStatus, isTrue,
          reason: 'Handler should have completed with OK status');

      // Now exercise the double-terminate guard:
      // Server.shutdown() iterates over active handlers and calls cancel().
      // Even though this handler already completed and terminated its stream,
      // shutdownActiveConnections() must be safe.
      await (harness.server as Server).shutdown();
    });
  });

  // ---------------------------------------------------------------------------
  // _onResponse safe error handling
  // ---------------------------------------------------------------------------
  group('_onResponse safe error handling', () {
    late ServerHarness harness;

    setUp(() {
      harness = ServerHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test(
      'serialization error during streaming does not crash server',
      () async {
        // Use the ResponseError method which has a throwing serializer.
        // This triggers the try-catch in _onResponse that was added to
        // prevent "Cannot add event after closing".
        Stream<int> methodHandler(
          ServiceCall call,
          Stream<int> request,
        ) async* {
          await for (final value in request) {
            yield value;
          }
        }

        final responseCompleter = Completer<void>();
        var sawGrpcStatus = false;

        harness.fromServer.stream.listen(
          (message) {
            if (message is HeadersStreamMessage) {
              final headers = headersToMap(message.headers);
              if (headers.containsKey('grpc-status')) {
                sawGrpcStatus = true;
              }
            }
          },
          onError: (_) {},
          onDone: () {
            if (!responseCompleter.isCompleted) {
              responseCompleter.complete();
            }
          },
        );

        harness.service.bidirectionalHandler = methodHandler;
        // Use the ResponseError method which has a broken serializer
        harness.sendRequestHeader('/Test/ResponseError');
        harness.sendData(1);
        harness.sendData(2);
        harness.toServer.close();

        await responseCompleter.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('Timed out waiting for response'),
        );

        // Verify the server sent an error status (not just silently survived)
        expect(sawGrpcStatus, isTrue,
            reason: 'Server should have sent grpc-status for serialization error');
      },
    );
  });

  // ---------------------------------------------------------------------------
  // _onDoneExpected safe error handling
  // ---------------------------------------------------------------------------
  group('_onDoneExpected safe error handling', () {
    late ServerHarness harness;

    setUp(() {
      harness = ServerHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('stream done with no request on unary does not crash', () async {
      // Send a unary request header but close the stream without sending
      // any data. This triggers _onDoneExpected with the "No request
      // received" path. The fix ensures that if _requests is already
      // closed when we try to addError, we catch it gracefully.
      Future<int> methodHandler(ServiceCall call, Future<int> request) async {
        try {
          return await request;
        } catch (_) {
          return 0;
        }
      }

      final responseCompleter = Completer<void>();
      var sawNoRequestError = false;

      harness.fromServer.stream.listen(
        (message) {
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            final grpcMessage = headers['grpc-message'];
            if (grpcMessage != null &&
                grpcMessage.contains('No request received')) {
              sawNoRequestError = true;
            }
          }
        },
        onError: (_) {},
        onDone: () {
          if (!responseCompleter.isCompleted) {
            responseCompleter.complete();
          }
        },
      );

      harness.service.unaryHandler = methodHandler;
      harness.sendRequestHeader('/Test/Unary');
      // Close without sending data
      harness.toServer.close();

      await responseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Timed out waiting for response'),
      );

      expect(sawNoRequestError, isTrue);
    });
  });
}
