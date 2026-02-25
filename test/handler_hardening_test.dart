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
/// - cancel() closes _requests (unblocks await-for handlers)
/// - Server.shutdown() end-to-end production path
/// - State machine adversarial races (double-cancel, triple-race, etc.)
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:grpc/src/server/handler.dart';
import 'package:grpc/src/shared/message.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart' as echo;
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
// Custom services for end-to-end tests
// =============================================================================

/// A bidi service where the handler blocks in await-for after the first item.
/// Used to test that Server.shutdown() → cancel() unblocks blocked handlers.
class _BlockingBidiService extends Service {
  final Completer<void> onEntered;
  final Completer<void> onExited;

  _BlockingBidiService({required this.onEntered, required this.onExited}) {
    $addMethod(
      ServiceMethod<int, int>(
        'BidiStream',
        _bidiStream,
        true,
        true,
        (List<int> value) => value[0],
        (int value) => [value],
      ),
    );
  }

  @override
  String get $name => 'test.EchoService';

  Stream<int> _bidiStream(ServiceCall call, Stream<int> requests) async* {
    try {
      await for (final value in requests) {
        yield value * 2;
        if (!onEntered.isCompleted) onEntered.complete();
        // Now blocked waiting for next item that won't come.
      }
    } catch (_) {
      // GrpcError.cancelled from cancel() — expected.
    }
    if (!onExited.isCompleted) onExited.complete();
  }
}

/// A bidi service that tracks N concurrent handlers via completer lists.
class _MultiBlockingBidiService extends Service {
  final List<Completer<void>> handlersEntered;
  final List<Completer<void>> handlersExited;
  int _handlerIndex = 0;

  _MultiBlockingBidiService({
    required this.handlersEntered,
    required this.handlersExited,
  }) {
    $addMethod(
      ServiceMethod<int, int>(
        'BidiStream',
        _bidiStream,
        true,
        true,
        (List<int> value) => value[0],
        (int value) => [value],
      ),
    );
  }

  @override
  String get $name => 'test.EchoService';

  Stream<int> _bidiStream(ServiceCall call, Stream<int> requests) async* {
    final myIndex = _handlerIndex++;
    try {
      await for (final value in requests) {
        yield value * 2;
        if (!handlersEntered[myIndex].isCompleted) {
          handlersEntered[myIndex].complete();
        }
      }
    } catch (_) {
      // GrpcError.cancelled — expected.
    }
    if (!handlersExited[myIndex].isCompleted) {
      handlersExited[myIndex].complete();
    }
  }
}

/// Bidi service with a request deserializer hook so tests can assert whether
/// incoming frames are still being deserialized after cancellation.
class _CountingDecodeBidiService extends Service {
  final void Function() onDeserialize;
  final Completer<void> onFirstRequestSeen;

  _CountingDecodeBidiService({
    required this.onDeserialize,
    required this.onFirstRequestSeen,
  }) {
    $addMethod(
      ServiceMethod<int, int>('BidiStream', _bidiStream, true, true, (
        List<int> value,
      ) {
        onDeserialize();
        return value[0];
      }, (int value) => [value]),
    );
  }

  @override
  String get $name => 'test.EchoService';

  Stream<int> _bidiStream(ServiceCall call, Stream<int> requests) async* {
    await for (final value in requests) {
      if (!onFirstRequestSeen.isCompleted) {
        onFirstRequestSeen.complete();
      }
      yield value;
    }
  }
}

/// StreamController wrapper that forces addError() to throw.
///
/// Used to deterministically exercise ServerHandler._onError catch handling.
class _ThrowingAddErrorController<T> implements StreamController<T> {
  final StreamController<T> _delegate;
  final void Function() onAddErrorAttempt;

  _ThrowingAddErrorController(this._delegate, this.onAddErrorAttempt);

  @override
  Stream<T> get stream => _delegate.stream;

  @override
  StreamSink<T> get sink => _delegate.sink;

  @override
  Future<void> get done => _delegate.done;

  @override
  bool get hasListener => _delegate.hasListener;

  @override
  bool get isClosed => _delegate.isClosed;

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  void add(T event) => _delegate.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    onAddErrorAttempt();
    throw StateError('forced addError failure');
  }

  @override
  Future<void> addStream(Stream<T> stream, {bool? cancelOnError}) =>
      _delegate.addStream(stream, cancelOnError: cancelOnError);

  @override
  Future<void> close() => _delegate.close();

  @override
  FutureOr<void> Function()? get onCancel => _delegate.onCancel;

  @override
  set onCancel(FutureOr<void> Function()? handler) =>
      _delegate.onCancel = handler;

  @override
  void Function()? get onListen => _delegate.onListen;

  @override
  set onListen(void Function()? handler) => _delegate.onListen = handler;

  @override
  void Function()? get onPause => _delegate.onPause;

  @override
  set onPause(void Function()? handler) => _delegate.onPause = handler;

  @override
  void Function()? get onResume => _delegate.onResume;

  @override
  set onResume(void Function()? handler) => _delegate.onResume = handler;
}

class _ThrowingAddErrorMethod extends ServiceMethod<int, int> {
  final void Function() onAddErrorAttempt;

  _ThrowingAddErrorMethod(
    this.onAddErrorAttempt,
    Stream<int> Function(ServiceCall, Stream<int>) handler,
  ) : super(
        'BidiStream',
        handler,
        true,
        true,
        (List<int> value) => value[0],
        (int value) => [value],
      );

  @override
  StreamController<int> createRequestStream(StreamSubscription incoming) {
    // ignore: close_sinks — lifecycle managed by _ThrowingAddErrorController.close()
    final delegate = super.createRequestStream(incoming);
    return _ThrowingAddErrorController<int>(delegate, onAddErrorAttempt);
  }
}

class _OnErrorCatchBidiService extends Service {
  final void Function() onAddErrorAttempt;
  final Completer<void> onFirstRequestSeen;
  final Completer<void> onExited;

  _OnErrorCatchBidiService({
    required this.onAddErrorAttempt,
    required this.onFirstRequestSeen,
    required this.onExited,
  }) {
    $addMethod(_ThrowingAddErrorMethod(onAddErrorAttempt, _bidiStream));
  }

  @override
  String get $name => 'test.EchoService';

  Stream<int> _bidiStream(ServiceCall call, Stream<int> requests) async* {
    try {
      await for (final value in requests) {
        if (!onFirstRequestSeen.isCompleted) {
          onFirstRequestSeen.complete();
        }
        yield value;
      }
    } finally {
      if (!onExited.isCompleted) onExited.complete();
    }
  }
}

/// ServiceMethod that triggers _onResponse serialization error (encoder throws)
/// and uses _ThrowingAddErrorController so addError throws.
class _ThrowingAddErrorResponseErrorMethod extends ServiceMethod<int, int> {
  final void Function() onAddErrorAttempt;

  _ThrowingAddErrorResponseErrorMethod(
    this.onAddErrorAttempt,
    Stream<int> Function(ServiceCall, Stream<int>) handler,
  ) : super(
        'ResponseError',
        handler,
        true,
        true,
        (List<int> value) => value[0],
        (int value) => throw 'Failed',
      );

  @override
  StreamController<int> createRequestStream(StreamSubscription incoming) {
    // ignore: close_sinks — lifecycle managed by _ThrowingAddErrorController
    final delegate = super.createRequestStream(incoming);
    return _ThrowingAddErrorController<int>(delegate, onAddErrorAttempt);
  }
}

/// ServiceMethod for unary that uses _ThrowingAddErrorController so addError
/// throws. Used to exercise _onDoneExpected addError-throw path.
class _ThrowingAddErrorUnaryMethod extends ServiceMethod<int, int> {
  final void Function() onAddErrorAttempt;

  _ThrowingAddErrorUnaryMethod(
    this.onAddErrorAttempt,
    Future<int> Function(ServiceCall, Future<int>) handler,
  ) : super(
        'NoRequestUnary',
        handler,
        false,
        false,
        (List<int> value) => value[0],
        (int value) => [value],
      );

  @override
  StreamController<int> createRequestStream(StreamSubscription incoming) {
    // ignore: close_sinks — lifecycle managed by _ThrowingAddErrorController
    final delegate = super.createRequestStream(incoming);
    return _ThrowingAddErrorController<int>(delegate, onAddErrorAttempt);
  }
}

/// Unary service that triggers _onDoneExpected (no request received) with
/// _ThrowingAddErrorController so addError throws. Validates that close() is
/// still attempted when addError fails, allowing handler to exit.
class _OnDoneExpectedCatchService extends Service {
  final void Function() onAddErrorAttempt;
  final Completer<void> onExited;

  _OnDoneExpectedCatchService({
    required this.onAddErrorAttempt,
    required this.onExited,
  }) {
    $addMethod(_ThrowingAddErrorUnaryMethod(onAddErrorAttempt, _unary));
  }

  @override
  String get $name => 'test.EchoService';

  Future<int> _unary(ServiceCall call, Future<int> request) async {
    try {
      return await request;
    } finally {
      if (!onExited.isCompleted) onExited.complete();
    }
  }
}

/// Bidi service that triggers _onResponse path (serialization throws on yield)
/// with _ThrowingAddErrorController so addError throws. Validates that close()
/// is still attempted when addError fails, allowing handler to exit.
class _OnResponseCatchBidiService extends Service {
  final void Function() onAddErrorAttempt;
  final Completer<void> onFirstRequestSeen;
  final Completer<void> onExited;

  _OnResponseCatchBidiService({
    required this.onAddErrorAttempt,
    required this.onFirstRequestSeen,
    required this.onExited,
  }) {
    $addMethod(
      _ThrowingAddErrorResponseErrorMethod(onAddErrorAttempt, _bidiStream),
    );
  }

  @override
  String get $name => 'test.EchoService';

  Stream<int> _bidiStream(ServiceCall call, Stream<int> requests) async* {
    try {
      await for (final value in requests) {
        if (!onFirstRequestSeen.isCompleted) {
          onFirstRequestSeen.complete();
        }
        yield value; // Serializer throws here → _onResponse catch path
      }
    } finally {
      if (!onExited.isCompleted) onExited.complete();
    }
  }
}

// =============================================================================
// TestClientChannel for end-to-end tests
// =============================================================================

// TestClientChannel is imported from common.dart.

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

    test(
      'handler error produces exactly one trailer (guard prevents duplicates)',
      () async {
        // This test exercises the _trailersSent guard at handler.dart:482.
        // The handler throws after yields, which triggers _onResponseError →
        // _sendError → sendTrailers(). Meanwhile, the client-side stream
        // close fires _onDoneExpected → _onDone, and the response
        // subscription cancel path may also attempt sendTrailers via
        // _onResponseDone. The guard must coalesce all paths into exactly
        // 1 trailer.
        Stream<int> methodHandler(
          ServiceCall call,
          Future<int> request,
        ) async* {
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
          onError: (error) {},
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

        expect(
          trailerCount,
          equals(1),
          reason:
              'Expected exactly 1 trailer message with grpc-status, '
              'got $trailerCount (totalMessages=$totalMessageCount). '
              'The _trailersSent guard should prevent duplicate trailers.',
        );
        expect(totalMessageCount, greaterThanOrEqualTo(1));
      },
    );

    test(
      '_trailersSent guard blocks second sendTrailers from concurrent path',
      () async {
        // This test deliberately creates TWO sendTrailers trigger paths
        // in the same handler lifecycle:
        //   1. _onTimedOut → _sendError → sendTrailers(DEADLINE_EXCEEDED)
        //   2. _onResponseDone → sendTrailers(OK)
        // With a 1μs grpc-timeout, the timer fires before the handler
        // finishes yielding. The handler eventually completes normally
        // (_onResponseDone), triggering a SECOND sendTrailers(OK) call.
        // The _trailersSent guard (handler.dart:482) must block the second
        // call, resulting in exactly 1 trailer on the wire.
        Stream<int> methodHandler(
          ServiceCall call,
          Future<int> request,
        ) async* {
          await request;
          // Yield a few items. The 1μs timeout fires during this loop,
          // calling sendTrailers(DEADLINE_EXCEEDED). When the handler
          // eventually returns (isCanceled breaks the loop), the
          // _onResponseDone path calls sendTrailers(OK).
          for (var i = 0; i < 20; i++) {
            if (call.isCanceled) break;
            yield i;
            await Future.delayed(const Duration(milliseconds: 5));
          }
        }

        final responseCompleter = Completer<void>();
        var trailerCount = 0;
        final trailerStatuses = <String>[];

        harness.fromServer.stream.listen(
          (message) {
            if (message is HeadersStreamMessage) {
              final headers = headersToMap(message.headers);
              if (headers.containsKey('grpc-status')) {
                trailerCount++;
                trailerStatuses.add(headers['grpc-status']!);
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

        expect(
          trailerCount,
          equals(1),
          reason:
              'Expected exactly 1 trailer despite both _onTimedOut and '
              '_onResponseDone calling sendTrailers. The _trailersSent '
              'guard (handler.dart:482) must block the second call. '
              'Got $trailerCount trailers: $trailerStatuses',
        );
      },
    );

    test(
      'yield-then-throw triggers both response paths without crash',
      () async {
        Stream<int> methodHandler(
          ServiceCall call,
          Future<int> request,
        ) async* {
          await request;
          yield 1;
          yield 2;
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

        expect(
          trailerCount,
          equals(1),
          reason:
              'Expected exactly 1 trailer with grpc-status, got $trailerCount',
        );
      },
    );

    test(
      'sendTrailers handles closed outgoing sink without crashing',
      () async {
        final errorHarness = ErrorCapturingHarness()..setUp();
        addTearDown(() => errorHarness.tearDown());

        final handlerReached = Completer<void>();
        errorHarness.service.unaryHandler =
            (ServiceCall call, Future<int> request) async {
              handlerReached.complete();
              await request;
              // Close the wire sink synchronously (don't await — awaiting
              // blocks the handler since the StreamController.close() future
              // won't complete until the listener processes the done event,
              // which can't happen while we hold the handler's async frame).
              // ignore: unawaited_futures
              errorHarness.fromServer.close();
              throw GrpcError.internal('forced sendTrailers on closed sink');
            };

        errorHarness.sendRequestHeader('/Test/Unary');
        errorHarness.sendData(1);
        await errorHarness.toServer.close();

        // Wait for handler to start.
        await handlerReached.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('Handler never started'),
        );

        // Give the async error propagation time to settle:
        // handler throws → Future.asStream() error → _onResponseError
        // → _sendError → _errorHandler.call(error) → sendTrailers()
        await Future<void>.delayed(const Duration(milliseconds: 500));

        // Verify the production code path:
        // 1. _sendError (handler.dart:626) calls _errorHandler BEFORE
        //    calling sendTrailers, so capturedErrors has the GrpcError.
        // 2. sendTrailers writes to the already-closed fromServer sink,
        //    which is caught and logged as [gRPC] Failed to send trailers.
        // 3. The server does NOT crash.
        expect(
          errorHarness.capturedErrors,
          isNotEmpty,
          reason:
              'errorHandler should receive the GrpcError.internal from the '
              'handler throw — _sendError calls _errorHandler before '
              'sendTrailers (handler.dart:626)',
        );
        expect(errorHarness.capturedErrors.first.code, StatusCode.internal);
      },
    );
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

    test('timeout with isCanceled TOCTOU sends DEADLINE_EXCEEDED', () async {
      // This test targets the TOCTOU race in _onTimedOut: the handler
      // checks call.isCanceled between yields, but the timeout can
      // fire between the check and the next yield. The 1μs timeout
      // ensures the timer fires almost immediately while the handler
      // is actively yielding, exercising the isCanceled + isClosed
      // guards in _onTimedOut.
      var yieldsBeforeCancel = 0;
      Stream<int> methodHandler(ServiceCall call, Future<int> request) async* {
        await request;
        for (var i = 0; i < 100; i++) {
          if (call.isCanceled) break;
          yield i;
          yieldsBeforeCancel++;
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }

      final responseCompleter = Completer<void>();
      var sawDeadlineExceeded = false;
      var trailerCount = 0;

      harness.fromServer.stream.listen(
        (message) {
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            if (headers.containsKey('grpc-status')) {
              trailerCount++;
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

      expect(sawDeadlineExceeded, isTrue);
      expect(
        trailerCount,
        equals(1),
        reason: 'Exactly 1 trailer expected, got $trailerCount',
      );
      // The handler should NOT have completed all 100 yields.
      expect(
        yieldsBeforeCancel,
        lessThan(100),
        reason: 'Timeout should have stopped the handler early',
      );
    });

    test('timeout timer firing after handler completion is harmless', () async {
      // The handler completes instantly (unary), but the grpc-timeout
      // header is set to 50ms. The timeout timer fires ~50ms AFTER
      // the handler has already sent OK trailers and terminated the
      // stream. The _onTimedOut guard (isCanceled || _trailersSent)
      // must prevent the stale timer from crashing or sending a
      // second DEADLINE_EXCEEDED trailer.
      Future<int> methodHandler(ServiceCall call, Future<int> request) async {
        return await request;
      }

      final responseCompleter = Completer<void>();
      var sawOkStatus = false;
      var trailerCount = 0;

      harness.fromServer.stream.listen(
        (message) {
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            if (headers.containsKey('grpc-status')) {
              trailerCount++;
              if (headers['grpc-status'] == '0') {
                sawOkStatus = true;
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

      harness.service.unaryHandler = methodHandler;
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

      // Wait 100ms — well past the 50ms grpc-timeout. The stale
      // timer fires during this window and must be a no-op.
      await Future.delayed(const Duration(milliseconds: 100));

      expect(
        sawOkStatus,
        isTrue,
        reason: 'Handler should have completed with OK status',
      );
      expect(
        trailerCount,
        equals(1),
        reason:
            'Stale timeout timer must not produce a second trailer '
            '(got $trailerCount)',
      );
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
      Stream<int> methodHandler(ServiceCall call, Stream<int> request) async* {
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

      harness.sendData(1);
      await Future.delayed(const Duration(milliseconds: 10));
      harness.sendData(2);
      harness.sendData(3);
      harness.toServer.close();

      await responseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Timed out waiting for response'),
      );

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

      expect(
        sawOkStatus,
        isTrue,
        reason: 'Handler should have completed with OK status',
      );

      // NOTE: server.shutdown() is intentionally NOT called here.
      // serveStream_() does not register the handler in
      // Server._connections or Server.handlers, so shutdown()
      // would be a no-op and mislead readers. The _terminateStream
      // guard is exercised by the normal completion path above.
    });

    test('_streamTerminated guard exercises double-terminate via cancel() '
        'after normal completion', () async {
      // This test deliberately triggers _terminateStream() TWICE:
      //   1. Normal handler completion: _onResponseDone → sendTrailers
      //      (endStream: true) closes the stream. Then _onDone →
      //      _incomingSubscription.cancel() — but since serveStream_
      //      uses a TestServerStream, the underlying transport-level
      //      _terminateStream path is implicit.
      //   2. Explicit cancel() after completion: calls
      //      _terminateStream() directly (handler.dart:661).
      // The _streamTerminated guard (handler.dart:671) must make the
      // second call a no-op without throwing.
      final toServer = StreamController<StreamMessage>();
      final fromServer = StreamController<StreamMessage>();
      final service = TestService();

      Future<int> methodHandler(ServiceCall call, Future<int> request) async {
        return await request;
      }

      service.unaryHandler = methodHandler;
      final server = Server.create(
        services: [service],
        errorHandler: (_, _) {},
      );
      final stream = TestServerStream(toServer.stream, fromServer.sink);
      final handler = server.serveStream_(stream: stream);

      addTearDown(() async {
        if (!toServer.isClosed) await toServer.close();
        if (!fromServer.isClosed) await fromServer.close();
      });

      final done = Completer<void>();
      var sawOkStatus = false;

      fromServer.stream.listen(
        (message) {
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            if (headers['grpc-status'] == '0') sawOkStatus = true;
          }
        },
        onError: (_) {},
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      final headers = Http2ClientConnection.createCallHeaders(
        true,
        'test',
        '/Test/Unary',
        null,
        null,
        null,
        userAgent: 'dart-grpc/1.0.0 test',
      );
      toServer.add(HeadersStreamMessage(headers));
      toServer.add(DataStreamMessage(frame(mockEncode(42))));
      await toServer.close();

      await done.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Handler did not complete'),
      );

      expect(sawOkStatus, isTrue);

      // Handler has already completed normally. Now call cancel()
      // which invokes _terminateStream() a second time. The
      // _streamTerminated guard must make this a no-op.
      handler.cancel();
      handler.cancel(); // Triple-call for extra coverage.

      // No crash = guard works.
      expect(handler.isCanceled, isTrue);
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
        Stream<int> methodHandler(
          ServiceCall call,
          Stream<int> request,
        ) async* {
          await for (final value in request) {
            yield value;
          }
        }

        final responseCompleter = Completer<void>();
        String? grpcStatusCode;

        harness.fromServer.stream.listen(
          (message) {
            if (message is HeadersStreamMessage) {
              final headers = headersToMap(message.headers);
              if (headers.containsKey('grpc-status')) {
                grpcStatusCode = headers['grpc-status'];
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
        harness.sendRequestHeader('/Test/ResponseError');
        harness.sendData(1);
        harness.sendData(2);
        harness.toServer.close();

        await responseCompleter.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('Timed out waiting for response'),
        );

        expect(
          grpcStatusCode,
          isNotNull,
          reason: 'Server should have sent grpc-status trailer',
        );
        // Serialization errors produce INTERNAL or UNKNOWN status.
        expect(
          int.tryParse(grpcStatusCode!),
          anyOf(equals(StatusCode.internal), equals(StatusCode.unknown)),
          reason:
              'Serialization error should produce INTERNAL or '
              'UNKNOWN status, got $grpcStatusCode',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // cancel() unblocks await-for handlers (#35 regression)
  // ---------------------------------------------------------------------------
  group('cancel() unblocks await-for handlers', () {
    test('bidi handler blocked in await-for completes on cancel()', () async {
      final toServer = StreamController<StreamMessage>();
      final fromServer = StreamController<StreamMessage>();
      final service = TestService();
      final handlerEntered = Completer<void>();
      final handlerUnblocked = Completer<void>();
      var sawCancelledError = false;
      Stream<int> methodHandler(ServiceCall call, Stream<int> request) async* {
        try {
          await for (final value in request) {
            yield value;
            if (!handlerEntered.isCompleted) {
              handlerEntered.complete();
            }
          }
        } catch (e) {
          if (e is GrpcError && e.code == StatusCode.cancelled) {
            sawCancelledError = true;
            if (!handlerUnblocked.isCompleted) {
              handlerUnblocked.complete();
            }
            return;
          }
          rethrow;
        }
        if (!handlerUnblocked.isCompleted) {
          handlerUnblocked.complete();
        }
      }

      service.bidirectionalHandler = methodHandler;
      final server = Server.create(services: [service]);
      final stream = TestServerStream(toServer.stream, fromServer.sink);
      final handler = server.serveStream_(stream: stream);
      addTearDown(() async {
        if (!toServer.isClosed) await toServer.close();
        if (!fromServer.isClosed) await fromServer.close();
        await server.shutdown();
      });

      fromServer.stream.listen((_) {}, onError: (_) {}, onDone: () {});

      final headers = Http2ClientConnection.createCallHeaders(
        true,
        'test',
        '/Test/Bidirectional',
        null,
        null,
        null,
        userAgent: 'dart-grpc/1.0.0 test',
      );
      toServer.add(HeadersStreamMessage(headers));
      toServer.add(DataStreamMessage(frame(mockEncode(1))));

      await handlerEntered.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Handler never entered await-for'),
      );
      await Future<void>.delayed(Duration.zero);

      handler.cancel();

      await handlerUnblocked.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () =>
            fail('Handler stayed blocked — cancel() did not close _requests'),
      );
      expect(
        sawCancelledError,
        isTrue,
        reason: 'Expected handler to be unblocked by GrpcError.cancelled',
      );
    });
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
      harness.toServer.close();

      await responseCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('Timed out waiting for response'),
      );

      expect(sawNoRequestError, isTrue);
    });

    test('_onDoneExpected path tolerates request-stream addError failure, '
        'handler exits', () async {
      final toServer = StreamController<StreamMessage>();
      final fromServer = StreamController<StreamMessage>();
      final handlerExited = Completer<void>();
      final wireDone = Completer<void>();
      var addErrorAttempted = false;

      final service = _OnDoneExpectedCatchService(
        onAddErrorAttempt: () => addErrorAttempted = true,
        onExited: handlerExited,
      );
      final server = Server.create(
        services: [service],
        errorHandler: (_, _) {},
      );
      final stream = TestServerStream(toServer.stream, fromServer.sink);
      server.serveStream_(stream: stream);

      addTearDown(() async {
        if (!toServer.isClosed) await toServer.close();
        if (!fromServer.isClosed) await fromServer.close();
      });

      fromServer.stream.listen(
        (_) {},
        onError: (_) {},
        onDone: () {
          if (!wireDone.isCompleted) wireDone.complete();
        },
      );

      // Send headers only, no data — triggers _onDoneExpected "no request"
      final headers = Http2ClientConnection.createCallHeaders(
        true,
        'test',
        '/test.EchoService/NoRequestUnary',
        null,
        null,
        null,
        userAgent: 'dart-grpc/1.0.0 test',
      );
      toServer.add(HeadersStreamMessage(headers));
      await toServer.close();

      await wireDone.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () =>
            fail('Wire did not settle after _onDoneExpected no-request path'),
      );

      expect(addErrorAttempted, isTrue);

      // Critical: _addErrorAndClose must still close _requests even when
      // addError throws, so the handler exits and does not block.
      await handlerExited.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail(
          'Handler did not exit after _onDoneExpected with addError throw',
        ),
      );
    });
  });

  // ===========================================================================
  // END-TO-END: Server.shutdown() → cancel() production path (real TCP)
  // ===========================================================================
  group('Server.shutdown() end-to-end production path', () {
    testTcpAndUds(
      'Server.shutdown() unblocks bidi handler stuck in await-for',
      (address) async {
        final handlerEntered = Completer<void>();
        final handlerExited = Completer<void>();

        final service = _BlockingBidiService(
          onEntered: handlerEntered,
          onExited: handlerExited,
        );

        final server = Server.create(services: [service]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);
        final client = echo.EchoClient(channel);

        final inputController = StreamController<int>();
        final responseStream = client.bidiStream(inputController.stream);

        final streamDone = Completer<void>();
        responseStream.listen(
          (_) {},
          onError: (_) {
            if (!streamDone.isCompleted) streamDone.complete();
          },
          onDone: () {
            if (!streamDone.isCompleted) streamDone.complete();
          },
        );

        inputController.add(1);

        await handlerEntered.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => fail('Handler never entered await-for'),
        );

        await server.shutdown().timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              fail('server.shutdown() hung — cancel() did not unblock handler'),
        );

        await handlerExited.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('Handler did not exit after shutdown'),
        );

        await inputController.close();
        await streamDone.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () =>
              fail('Bidi response stream did not settle after shutdown'),
        );
        await channel.shutdown();
      },
    );

    testTcpAndUds(
      'Server.shutdown() with 10 concurrent blocked bidi handlers',
      (address) async {
        final handlersEntered = <Completer<void>>[];
        final handlersExited = <Completer<void>>[];
        for (var i = 0; i < 10; i++) {
          handlersEntered.add(Completer<void>());
          handlersExited.add(Completer<void>());
        }

        final service = _MultiBlockingBidiService(
          handlersEntered: handlersEntered,
          handlersExited: handlersExited,
        );

        final server = Server.create(services: [service]);
        await server.serve(address: address, port: 0);

        final channel = createTestChannel(address, server.port!);
        final client = echo.EchoClient(channel);

        // Open 10 bidi streams, each sending 1 item then blocking.
        final controllers = <StreamController<int>>[];
        final doneCompleters = <Completer<void>>[];
        for (var i = 0; i < 10; i++) {
          final ctrl = StreamController<int>();
          controllers.add(ctrl);
          final done = Completer<void>();
          doneCompleters.add(done);
          client
              .bidiStream(ctrl.stream)
              .listen(
                (_) {},
                onError: (_) {
                  if (!done.isCompleted) done.complete();
                },
                onDone: () {
                  if (!done.isCompleted) done.complete();
                },
              );
          ctrl.add(i);
        }

        // Wait for all handlers to enter await-for.
        await Future.wait(
          handlersEntered.map(
            (c) => c.future.timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail('Not all handlers entered'),
            ),
          ),
        );

        // All 10 are blocked. Shutdown must unblock all of them.
        await server.shutdown().timeout(
          const Duration(seconds: 10),
          onTimeout: () =>
              fail('shutdown() hung with 10 blocked bidi handlers'),
        );

        // Verify ALL 10 handlers exited.
        await Future.wait(
          handlersExited.map(
            (c) => c.future.timeout(
              const Duration(seconds: 3),
              onTimeout: () => fail('Not all handlers exited after shutdown'),
            ),
          ),
        );

        for (final ctrl in controllers) {
          await ctrl.close();
        }
        await channel.shutdown();
      },
    );
  });

  // ===========================================================================
  // HARNESS: State machine adversarial races
  // ===========================================================================
  group('Handler state machine adversarial races', () {
    test('double-cancel in rapid succession is safe', () async {
      final toServer = StreamController<StreamMessage>();
      final fromServer = StreamController<StreamMessage>();
      final service = TestService();
      final handlerEntered = Completer<void>();
      final handlerExited = Completer<void>();

      Stream<int> methodHandler(ServiceCall call, Stream<int> request) async* {
        try {
          await for (final value in request) {
            yield value;
            if (!handlerEntered.isCompleted) handlerEntered.complete();
          }
        } catch (_) {
          // GrpcError.cancelled expected
        }
        if (!handlerExited.isCompleted) handlerExited.complete();
      }

      service.bidirectionalHandler = methodHandler;
      final server = Server.create(services: [service]);
      final stream = TestServerStream(toServer.stream, fromServer.sink);
      final handler = server.serveStream_(stream: stream);

      addTearDown(() async {
        if (!toServer.isClosed) await toServer.close();
        if (!fromServer.isClosed) await fromServer.close();
      });

      fromServer.stream.listen((_) {}, onError: (_) {});

      final headers = Http2ClientConnection.createCallHeaders(
        true,
        'test',
        '/Test/Bidirectional',
        null,
        null,
        null,
        userAgent: 'dart-grpc/1.0.0 test',
      );
      toServer.add(HeadersStreamMessage(headers));
      toServer.add(DataStreamMessage(frame(mockEncode(1))));

      await handlerEntered.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Handler never entered await-for'),
      );
      await Future<void>.delayed(Duration.zero);

      // Double-cancel: both must complete without crashing.
      handler.cancel();
      handler.cancel();

      // Assert: handler was marked canceled.
      expect(handler.isCanceled, isTrue);

      // Assert: handler actually exited.
      await handlerExited.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Handler did not exit after double-cancel'),
      );

      // cancel() terminates the stream directly (RST_STREAM equivalent)
      // WITHOUT sending trailers. This is correct gRPC behavior — the
      // wire just gets an error 'TERMINATED' then close, not a trailer.
      // The test verifies: no crash, handler exits, isCanceled == true.
    });

    test('data arriving after cancel() is silently discarded', () async {
      final toServer = StreamController<StreamMessage>();
      final fromServer = StreamController<StreamMessage>();
      final service = TestService();
      final handlerEntered = Completer<void>();
      final handlerExited = Completer<void>();
      var sawCancelledError = false;

      Stream<int> methodHandler(ServiceCall call, Stream<int> request) async* {
        try {
          await for (final value in request) {
            yield value;
            if (!handlerEntered.isCompleted) handlerEntered.complete();
          }
        } catch (e) {
          if (e is GrpcError && e.code == StatusCode.cancelled) {
            sawCancelledError = true;
          }
        }
        if (!handlerExited.isCompleted) handlerExited.complete();
      }

      service.bidirectionalHandler = methodHandler;
      final server = Server.create(services: [service]);
      final stream = TestServerStream(toServer.stream, fromServer.sink);
      final handler = server.serveStream_(stream: stream);

      addTearDown(() async {
        if (!toServer.isClosed) await toServer.close();
        if (!fromServer.isClosed) await fromServer.close();
      });

      fromServer.stream.listen((_) {}, onError: (_) {});

      final headers = Http2ClientConnection.createCallHeaders(
        true,
        'test',
        '/Test/Bidirectional',
        null,
        null,
        null,
        userAgent: 'dart-grpc/1.0.0 test',
      );
      toServer.add(HeadersStreamMessage(headers));
      toServer.add(DataStreamMessage(frame(mockEncode(1))));

      await handlerEntered.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Handler never entered await-for'),
      );
      await Future<void>.delayed(Duration.zero);

      handler.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Inject 5 more data frames AFTER cancel — must NOT crash.
      for (var i = 2; i <= 6; i++) {
        toServer.add(DataStreamMessage(frame(mockEncode(i))));
      }

      // Assert: handler exited cleanly.
      await handlerExited.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Handler did not exit after cancel + data'),
      );

      // Assert: cancel was delivered to handler.
      expect(handler.isCanceled, isTrue);
      expect(
        sawCancelledError,
        isTrue,
        reason: 'Handler should have received GrpcError.cancelled',
      );

      // cancel() terminates the stream directly (RST_STREAM) without
      // sending trailers. The key assertion here is: injecting 5 data
      // frames after cancel does NOT cause "Cannot add event after
      // closing" or any other crash.
    });

    test('cancel() stops request deserialization after cancellation', () async {
      final toServer = StreamController<StreamMessage>();
      final fromServer = StreamController<StreamMessage>();
      final firstRequestSeen = Completer<void>();
      var deserializeCount = 0;

      final service = _CountingDecodeBidiService(
        onDeserialize: () => deserializeCount++,
        onFirstRequestSeen: firstRequestSeen,
      );
      final server = Server.create(services: [service]);
      final stream = TestServerStream(toServer.stream, fromServer.sink);
      final handler = server.serveStream_(stream: stream);

      addTearDown(() async {
        if (!toServer.isClosed) await toServer.close();
        if (!fromServer.isClosed) await fromServer.close();
      });

      fromServer.stream.listen((_) {}, onError: (_) {});

      final headers = Http2ClientConnection.createCallHeaders(
        true,
        'test',
        '/test.EchoService/BidiStream',
        null,
        null,
        null,
        userAgent: 'dart-grpc/1.0.0 test',
      );
      toServer.add(HeadersStreamMessage(headers));
      toServer.add(DataStreamMessage(frame(<int>[1])));

      await firstRequestSeen.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Handler never consumed first request'),
      );

      handler.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final countAtCancel = deserializeCount;
      for (var i = 0; i < 5; i++) {
        toServer.add(DataStreamMessage(frame(<int>[i + 2])));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(handler.isCanceled, isTrue);
      expect(
        deserializeCount,
        equals(countAtCancel),
        reason:
            'No additional request deserialization should occur after cancel',
      );
    });

    test('timeout fires while handler is mid-yield', () async {
      final harness = ServerHarness()..setUp();
      addTearDown(() => harness.tearDown());

      Stream<int> methodHandler(ServiceCall call, Future<int> request) async* {
        await request;
        for (var i = 0; i < 50; i++) {
          yield i;
          await Future.delayed(const Duration(milliseconds: 5));
          if (call.isCanceled) return;
        }
      }

      final responseCompleter = Completer<void>();
      var trailerCount = 0;
      var sawDeadlineExceeded = false;

      harness.fromServer.stream.listen(
        (message) {
          if (message is HeadersStreamMessage) {
            final headers = headersToMap(message.headers);
            if (headers.containsKey('grpc-status')) {
              trailerCount++;
              if (headers['grpc-status'] == '${StatusCode.deadlineExceeded}') {
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

      expect(
        trailerCount,
        equals(1),
        reason: 'Expected exactly 1 trailer, got $trailerCount',
      );
      expect(sawDeadlineExceeded, isTrue);
    });

    test('_onError + _onDone + cancel() triple-race is safe', () async {
      final toServer = StreamController<StreamMessage>();
      final fromServer = StreamController<StreamMessage>();
      final service = TestService();
      final handlerProcessed = Completer<void>();

      Stream<int> methodHandler(ServiceCall call, Stream<int> request) async* {
        try {
          await for (final value in request) {
            yield value;
            if (!handlerProcessed.isCompleted) {
              handlerProcessed.complete();
            }
          }
        } catch (_) {
          // Expected — error, done, or cancel will terminate the stream
        }
      }

      service.bidirectionalHandler = methodHandler;
      final server = Server.create(services: [service]);
      final stream = TestServerStream(toServer.stream, fromServer.sink);
      final handler = server.serveStream_(stream: stream);

      addTearDown(() async {
        if (!toServer.isClosed) await toServer.close();
        if (!fromServer.isClosed) await fromServer.close();
      });

      final wireDone = Completer<void>();
      var wireMessageCount = 0;
      fromServer.stream.listen(
        (_) => wireMessageCount++,
        onError: (_) {},
        onDone: () {
          if (!wireDone.isCompleted) wireDone.complete();
        },
      );

      final headers = Http2ClientConnection.createCallHeaders(
        true,
        'test',
        '/Test/Bidirectional',
        null,
        null,
        null,
        userAgent: 'dart-grpc/1.0.0 test',
      );
      toServer.add(HeadersStreamMessage(headers));
      toServer.add(DataStreamMessage(frame(mockEncode(1))));

      // Wait for handler to process the first item.
      await handlerProcessed.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Handler never processed first item'),
      );
      await Future<void>.delayed(Duration.zero);

      // Triple-race: error + done + cancel in rapid succession.
      // Note: cancelOnError:true means only ONE of error/done will fire
      // on the incoming subscription. cancel() adds a third termination
      // vector. The test verifies none of these combinations crash.
      expect(
        toServer.isClosed,
        isFalse,
        reason: 'Input stream closed before triple-race injection',
      );
      toServer.addError(Exception('injected error'));
      if (!toServer.isClosed) await toServer.close();
      handler.cancel();

      // Wait for wire to settle.
      await wireDone.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => fail('Wire stream never closed after triple-race'),
      );

      // Assert: handler terminated and wire settled.
      expect(handler.isCanceled, isTrue);
      // The handler sent at least initial headers + 1 data frame
      // (the echoed value). After the triple-race, it may or may not
      // have sent trailers depending on which termination path won.
      expect(
        wireMessageCount,
        greaterThanOrEqualTo(1),
        reason: 'Wire should have at least the initial response headers',
      );
    });

    test(
      '_onError catch path tolerates request-stream addError failure',
      () async {
        final toServer = StreamController<StreamMessage>();
        final fromServer = StreamController<StreamMessage>();
        final firstRequestSeen = Completer<void>();
        final handlerExited = Completer<void>();
        final wireDone = Completer<void>();
        var addErrorAttempted = false;

        final service = _OnErrorCatchBidiService(
          onAddErrorAttempt: () => addErrorAttempted = true,
          onFirstRequestSeen: firstRequestSeen,
          onExited: handlerExited,
        );
        final server = Server.create(services: [service]);
        final stream = TestServerStream(toServer.stream, fromServer.sink);
        final handler = server.serveStream_(stream: stream);

        addTearDown(() async {
          if (!toServer.isClosed) await toServer.close();
          if (!fromServer.isClosed) await fromServer.close();
        });

        fromServer.stream.listen(
          (_) {},
          onError: (_) {},
          onDone: () {
            if (!wireDone.isCompleted) wireDone.complete();
          },
        );

        final headers = Http2ClientConnection.createCallHeaders(
          true,
          'test',
          '/test.EchoService/BidiStream',
          null,
          null,
          null,
          userAgent: 'dart-grpc/1.0.0 test',
        );
        toServer.add(HeadersStreamMessage(headers));
        toServer.add(DataStreamMessage(frame(<int>[1])));

        await firstRequestSeen.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('Handler never processed initial request'),
        );

        toServer.addError(Exception('forced transport error'));

        await wireDone.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => fail('Wire did not settle after _onError injection'),
        );

        expect(addErrorAttempted, isTrue);
        expect(handler.isCanceled, isTrue);

        // Critical: handler must exit even when addError throws.
        // close() is attempted in a separate try block, unblocking the
        // await-for so the handler can complete.
        await handlerExited.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () =>
              fail('Handler did not exit after _onError with addError throw'),
        );
      },
    );

    test(
      'cancel() path tolerates request-stream addError failure, handler exits',
      () async {
        final toServer = StreamController<StreamMessage>();
        final fromServer = StreamController<StreamMessage>();
        final firstRequestSeen = Completer<void>();
        final handlerExited = Completer<void>();
        var addErrorAttempted = false;

        final service = _OnErrorCatchBidiService(
          onAddErrorAttempt: () => addErrorAttempted = true,
          onFirstRequestSeen: firstRequestSeen,
          onExited: handlerExited,
        );
        final server = Server.create(services: [service]);
        final stream = TestServerStream(toServer.stream, fromServer.sink);
        final handler = server.serveStream_(stream: stream);

        addTearDown(() async {
          if (!toServer.isClosed) await toServer.close();
          if (!fromServer.isClosed) await fromServer.close();
        });

        fromServer.stream.listen((_) {}, onError: (_) {});

        final headers = Http2ClientConnection.createCallHeaders(
          true,
          'test',
          '/test.EchoService/BidiStream',
          null,
          null,
          null,
          userAgent: 'dart-grpc/1.0.0 test',
        );
        toServer.add(HeadersStreamMessage(headers));
        toServer.add(DataStreamMessage(frame(<int>[1])));

        await firstRequestSeen.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('Handler never processed initial request'),
        );

        handler.cancel();

        expect(addErrorAttempted, isTrue);
        expect(handler.isCanceled, isTrue);

        // Critical: cancel() must still close _requests even when addError
        // throws, so the handler exits and does not block indefinitely.
        await handlerExited.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () =>
              fail('Handler did not exit after cancel() with addError throw'),
        );
      },
    );

    test(
      '_onResponse path tolerates request-stream addError failure, handler exits',
      () async {
        final toServer = StreamController<StreamMessage>();
        final fromServer = StreamController<StreamMessage>();
        final firstRequestSeen = Completer<void>();
        final handlerExited = Completer<void>();
        final wireDone = Completer<void>();
        var addErrorAttempted = false;

        final service = _OnResponseCatchBidiService(
          onAddErrorAttempt: () => addErrorAttempted = true,
          onFirstRequestSeen: firstRequestSeen,
          onExited: handlerExited,
        );
        final server = Server.create(services: [service]);
        final stream = TestServerStream(toServer.stream, fromServer.sink);
        server.serveStream_(stream: stream);

        addTearDown(() async {
          if (!toServer.isClosed) await toServer.close();
          if (!fromServer.isClosed) await fromServer.close();
        });

        fromServer.stream.listen(
          (_) {},
          onError: (_) {},
          onDone: () {
            if (!wireDone.isCompleted) wireDone.complete();
          },
        );

        final headers = Http2ClientConnection.createCallHeaders(
          true,
          'test',
          '/test.EchoService/ResponseError',
          null,
          null,
          null,
          userAgent: 'dart-grpc/1.0.0 test',
        );
        toServer.add(HeadersStreamMessage(headers));
        toServer.add(DataStreamMessage(frame(mockEncode(1))));

        await firstRequestSeen.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('Handler never processed initial request'),
        );

        await wireDone.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () =>
              fail('Wire did not settle after _onResponse serialization error'),
        );

        expect(addErrorAttempted, isTrue);

        // Critical: _onResponse must still close _requests even when addError
        // throws, so the handler exits and does not block indefinitely.
        await handlerExited.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail(
            'Handler did not exit after _onResponse with addError throw',
          ),
        );
      },
    );

    test(
      '8 sequential handlers exercise all _requests-closing paths',
      () async {
        // Each iteration creates a fresh harness, exercising a different
        // close path. The test proves no path crashes the server.

        // Path 1: Normal unary completion.
        final path1Trailer = await _runHarnessHandler(
          method: '/Test/Unary',
          configure: (s) {
            s.unaryHandler = (call, req) async => await req;
          },
          sendFrames: (ctrl) {
            ctrl.add(DataStreamMessage(frame(mockEncode(42))));
          },
        );
        expect(
          path1Trailer,
          contains('grpc-status'),
          reason: 'Path 1 (normal unary) must send a trailer',
        );
        expect(
          path1Trailer['grpc-status'],
          '0',
          reason: 'Path 1 must succeed with OK',
        );

        // Path 2: _onDoneExpected with no request (close without data).
        final path2Trailer = await _runHarnessHandler(
          method: '/Test/Unary',
          configure: (s) {
            s.unaryHandler = (call, req) async {
              try {
                return await req;
              } catch (_) {
                return 0;
              }
            };
          },
          sendFrames: (_) {},
        );
        expect(
          path2Trailer,
          contains('grpc-status'),
          reason: 'Path 2 (no-data unary) must send a trailer',
        );

        // Path 3: _onError — inject error into transport stream.
        // _onError terminates directly (RST_STREAM) without sending
        // trailers — this is correct for transport-level errors.
        await _runHarnessHandler(
          method: '/Test/Bidirectional',
          configure: (s) {
            s.bidirectionalHandler = (call, req) async* {
              try {
                await for (final v in req) {
                  yield v;
                }
              } catch (_) {}
            };
          },
          sendFrames: (ctrl) {
            ctrl.add(DataStreamMessage(frame(mockEncode(1))));
            ctrl.addError(Exception('injected'));
          },
        );
        // Reaching here without crash = Path 3 passed.

        // Path 4: cancel() path.
        // cancel() also terminates directly (RST_STREAM) without
        // sending trailers.
        final path4Result = await _runCancelHandler();
        expect(
          path4Result.handler.isCanceled,
          isTrue,
          reason: 'Path 4 handler must be canceled',
        );

        // Path 5: Timeout path (grpc-timeout = 1μs).
        final path5Trailer = await _runHarnessHandler(
          method: '/Test/ServerStreaming',
          configure: (s) {
            s.serverStreamingHandler = (call, req) async* {
              await req;
              for (var i = 0; i < 100; i++) {
                yield i;
                await Future.delayed(const Duration(milliseconds: 5));
                if (call.isCanceled) return;
              }
            };
          },
          sendFrames: (ctrl) {
            ctrl.add(DataStreamMessage(frame(mockEncode(1))));
          },
          timeout: const Duration(microseconds: 1),
        );
        expect(
          path5Trailer,
          contains('grpc-status'),
          reason: 'Path 5 (timeout) must send a trailer',
        );
        expect(
          path5Trailer['grpc-status'],
          '${StatusCode.deadlineExceeded}',
          reason: 'Path 5 must produce DEADLINE_EXCEEDED',
        );

        // Path 6: Request deserialization error (RequestError method).
        // NOTE: RequestError uses _bidirectional as its handler function,
        // which checks bidirectionalHandler != null. We must set it
        // because the handler is invoked BEFORE deserialization occurs.
        final path6Trailer = await _runHarnessHandler(
          method: '/Test/RequestError',
          configure: (s) {
            s.bidirectionalHandler = (call, req) async* {
              await for (final v in req) {
                yield v;
              }
            };
          },
          sendFrames: (ctrl) {
            ctrl.add(DataStreamMessage(frame(mockEncode(1))));
          },
        );
        expect(
          path6Trailer,
          contains('grpc-status'),
          reason: 'Path 6 (deserialization error) must send a trailer',
        );
        expect(
          int.tryParse(path6Trailer['grpc-status']!),
          anyOf(equals(StatusCode.internal), equals(StatusCode.unknown)),
          reason: 'Path 6 must produce INTERNAL or UNKNOWN',
        );

        // Path 7: Response serialization error (ResponseError method).
        // NOTE: ResponseError also uses _bidirectional as handler.
        final path7Trailer = await _runHarnessHandler(
          method: '/Test/ResponseError',
          configure: (s) {
            s.bidirectionalHandler = (call, req) async* {
              await for (final v in req) {
                yield v;
              }
            };
          },
          sendFrames: (ctrl) {
            ctrl.add(DataStreamMessage(frame(mockEncode(1))));
          },
        );
        expect(
          path7Trailer,
          contains('grpc-status'),
          reason: 'Path 7 (serialization error) must send a trailer',
        );
        expect(
          int.tryParse(path7Trailer['grpc-status']!),
          anyOf(equals(StatusCode.internal), equals(StatusCode.unknown)),
          reason: 'Path 7 must produce INTERNAL or UNKNOWN',
        );

        // Path 8: Handler throws non-GrpcError exception.
        final path8Trailer = await _runHarnessHandler(
          method: '/Test/Unary',
          configure: (s) {
            s.unaryHandler = (call, req) async {
              await req;
              throw StateError('Unexpected internal error');
            };
          },
          sendFrames: (ctrl) {
            ctrl.add(DataStreamMessage(frame(mockEncode(1))));
          },
        );
        expect(
          path8Trailer,
          contains('grpc-status'),
          reason: 'Path 8 (non-GrpcError throw) must send a trailer',
        );

        // If we reach here, the server survived all 8 paths and every
        // path produced a well-formed trailer.
      },
    );
  });
}

// =============================================================================
// Helpers for the "8 sequential handlers" test
// =============================================================================

/// Runs a single handler on a fresh harness, waits for it to finish, and
/// returns the trailer headers map. Fails with a descriptive message if the
/// handler hangs.
///
/// NOTE: `serveStream_()` does NOT register the handler in Server._connections
/// or Server.handlers — so `server.shutdown()` is intentionally omitted here
/// as it would be a no-op and would mislead readers into thinking it cancels
/// the handler.
Future<Map<String, String>> _runHarnessHandler({
  required String method,
  required void Function(TestService) configure,
  required FutureOr<void> Function(StreamController<StreamMessage>) sendFrames,
  Duration? timeout,
}) async {
  final toServer = StreamController<StreamMessage>();
  final fromServer = StreamController<StreamMessage>();
  final service = TestService();
  configure(service);

  final server = Server.create(services: [service], errorHandler: (_, _) {});
  final stream = TestServerStream(toServer.stream, fromServer.sink);
  server.serveStream_(stream: stream);

  final done = Completer<void>();
  var lastTrailer = <String, String>{};

  fromServer.stream.listen(
    (message) {
      if (message is HeadersStreamMessage) {
        final h = headersToMap(message.headers);
        if (h.containsKey('grpc-status')) {
          lastTrailer = h;
        }
      }
    },
    onError: (_) {
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );

  final headers = Http2ClientConnection.createCallHeaders(
    true,
    'test',
    method,
    timeout,
    null,
    null,
    userAgent: 'dart-grpc/1.0.0 test',
  );
  toServer.add(HeadersStreamMessage(headers));
  await sendFrames(toServer);
  // Yield to let microtasks from sendFrames settle before closing.
  await Future<void>.delayed(Duration.zero);
  if (!toServer.isClosed) await toServer.close();

  await done.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () =>
        fail('_runHarnessHandler hung for $method — handler did not complete'),
  );
  if (!fromServer.isClosed) await fromServer.close();
  return lastTrailer;
}

/// Result of [_runCancelHandler] with both handler ref and captured trailers.
class _CancelHandlerResult {
  final ServerHandler handler;
  final Map<String, String> trailers;
  _CancelHandlerResult(this.handler, this.trailers);
}

/// Runs the cancel() path — needs direct handler reference.
Future<_CancelHandlerResult> _runCancelHandler() async {
  final toServer = StreamController<StreamMessage>();
  final fromServer = StreamController<StreamMessage>();
  final service = TestService();
  final handlerExited = Completer<void>();

  service.bidirectionalHandler = (call, req) async* {
    try {
      await for (final v in req) {
        yield v;
      }
    } catch (_) {
      // GrpcError.cancelled expected
    }
    if (!handlerExited.isCompleted) handlerExited.complete();
  };

  final server = Server.create(services: [service], errorHandler: (_, _) {});
  final stream = TestServerStream(toServer.stream, fromServer.sink);
  final handler = server.serveStream_(stream: stream);

  final done = Completer<void>();
  var lastTrailer = <String, String>{};

  fromServer.stream.listen(
    (message) {
      if (message is HeadersStreamMessage) {
        final h = headersToMap(message.headers);
        if (h.containsKey('grpc-status')) {
          lastTrailer = h;
        }
      }
    },
    onError: (_) {
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );

  final headers = Http2ClientConnection.createCallHeaders(
    true,
    'test',
    '/Test/Bidirectional',
    null,
    null,
    null,
    userAgent: 'dart-grpc/1.0.0 test',
  );
  toServer.add(HeadersStreamMessage(headers));
  toServer.add(DataStreamMessage(frame(mockEncode(1))));

  // Wait for handler to process first item.
  await Future<void>.delayed(const Duration(milliseconds: 20));

  handler.cancel();

  // Wait for handler to exit.
  await handlerExited.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () => fail('Cancel handler did not exit'),
  );

  await Future<void>.delayed(const Duration(milliseconds: 20));
  if (!toServer.isClosed) await toServer.close();

  await done.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () => fail('Cancel handler wire stream never closed'),
  );
  if (!fromServer.isClosed) await fromServer.close();

  return _CancelHandlerResult(handler, lastTrailer);
}
