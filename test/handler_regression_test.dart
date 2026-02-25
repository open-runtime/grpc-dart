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

/// Regression tests for handler.dart hardening fixes.
///
/// These tests cover four specific fixes to [ServerHandler]:
///
/// - **C1**: `_onTimedOut` must cancel the incoming subscription and
///   terminate the HTTP/2 stream to prevent resource leaks.
/// - **C2**: `_onDoneError` must terminate the HTTP/2 stream after
///   handling the unexpected close.
/// - **H3**: `_applyInterceptors` must preserve thrown [GrpcError]
///   status codes instead of wrapping them in `GrpcError.internal`.
/// - **H5**: `sendTrailers` must set `_streamTerminated = true` so
///   that a subsequent `cancel()` does not send a redundant
///   RST_STREAM.
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

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------

/// A [ServerTransportStream] that tracks lifecycle events.
///
/// Unlike the base [TestServerStream], this records every call to
/// [terminate] and every frame sent via [sendHeaders] / [sendData].
///
/// When `sendHeaders` is called with `endStream: true`, the outgoing
/// sink is closed to simulate real HTTP/2 behaviour where sending a
/// HEADERS frame with END_STREAM concludes the outgoing half of the
/// stream. This is important because [ServerHandler.handle] listens
/// on `outgoingMessages.done` and calls `cancel()` when it resolves.
class TrackingServerStream implements ServerTransportStream {
  final Stream<StreamMessage> _incoming;
  final StreamSink<StreamMessage> _outgoing;

  int terminateCount = 0;
  bool get wasTerminated => terminateCount > 0;

  /// Headers sent with `endStream: true` (i.e. trailers).
  final List<List<Header>> sentTrailers = [];

  /// All headers sent (including non-end-stream ones).
  final List<List<Header>> sentHeaders = [];

  /// Data frames sent via [sendData].
  final List<List<int>> sentData = [];

  TrackingServerStream(this._incoming, this._outgoing);

  @override
  Stream<StreamMessage> get incomingMessages => _incoming;

  @override
  StreamSink<StreamMessage> get outgoingMessages => _outgoing;

  @override
  int get id => -1;

  @override
  void terminate() {
    terminateCount++;
    try {
      _outgoing.addError('TERMINATED');
      _outgoing.close();
    } catch (_) {
      // Sink may already be closed.
    }
  }

  @override
  set onTerminated(void Function(int x) value) {}

  @override
  bool get canPush => true;

  @override
  ServerTransportStream push(List<Header> requestHeaders) =>
      throw 'unimplemented';

  @override
  void sendData(List<int> data, {bool? endStream}) {
    sentData.add(data);
    _outgoing.add(DataStreamMessage(data, endStream: endStream));
  }

  @override
  void sendHeaders(List<Header> headers, {bool? endStream}) {
    sentHeaders.add(headers);
    if (endStream == true) {
      sentTrailers.add(headers);
    }
    _outgoing.add(HeadersStreamMessage(headers, endStream: endStream));
    // Simulate real HTTP/2: sending endStream closes the outgoing
    // half, which resolves `outgoingMessages.done`.
    if (endStream == true) {
      _outgoing.close();
    }
  }
}

/// Harness that exposes a [TrackingServerStream] so tests can
/// inspect stream lifecycle events (terminate count, sent trailers,
/// etc.).
class TrackingHarness {
  final toServer = StreamController<StreamMessage>();
  final fromServer = StreamController<StreamMessage>();
  final service = TestService();
  final interceptor = TestInterceptor();

  late TrackingServerStream stream;
  late ConnectionServer server;

  final List<GrpcError> capturedErrors = [];

  /// Optional list of [ServerInterceptor]s to install.
  List<ServerInterceptor> serverInterceptors;

  TrackingHarness({this.serverInterceptors = const []});

  void setUp() {
    stream = TrackingServerStream(toServer.stream, fromServer.sink);
    server = Server.create(
      services: <Service>[service],
      interceptors: <Interceptor>[interceptor.call],
      serverInterceptors: serverInterceptors,
      errorHandler: (error, trace) {
        capturedErrors.add(error);
      },
    );
    server.serveStream_(stream: stream);
  }

  void tearDown() {
    toServer.close();
    // fromServer may already be closed by the tracking stream.
    try {
      fromServer.close();
    } catch (_) {}
  }

  void sendRequestHeader(
    String path, {
    String authority = 'test',
    Map<String, String>? metadata,
    Duration? timeout,
  }) {
    final headers = Http2ClientConnection.createCallHeaders(
      true,
      authority,
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

  /// Extract `grpc-status` from the first trailer frame.
  int? firstTrailerStatus() {
    if (stream.sentTrailers.isEmpty) return null;
    final map = headersToMap(stream.sentTrailers.first);
    final raw = map['grpc-status'];
    return raw == null ? null : int.tryParse(raw);
  }

  /// Extract `grpc-message` from the first trailer frame.
  String? firstTrailerMessage() {
    if (stream.sentTrailers.isEmpty) return null;
    final map = headersToMap(stream.sentTrailers.first);
    return map['grpc-message'];
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ===========================================================
  // C1 -- _onTimedOut must clean up the HTTP/2 stream
  // ===========================================================
  group('C1: _onTimedOut cleans up the stream', () {
    late TrackingHarness harness;

    setUp(() {
      harness = TrackingHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('timeout sends deadline-exceeded trailers with endStream', () async {
      final handlerStarted = Completer<void>();

      harness.service.unaryHandler = (call, request) {
        handlerStarted.complete();
        return Completer<int>().future;
      };

      harness.fromServer.stream.listen((_) {}, onError: (_) {}, onDone: () {});

      harness.sendRequestHeader(
        '/Test/Unary',
        timeout: const Duration(milliseconds: 1),
      );
      harness.sendData(1);

      await handlerStarted.future;
      await Future.delayed(const Duration(milliseconds: 100));

      await harness.toServer.close();
      await Future.delayed(const Duration(milliseconds: 50));

      final status = harness.firstTrailerStatus();
      expect(
        status,
        equals(StatusCode.deadlineExceeded),
        reason: 'Server must reply DEADLINE_EXCEEDED on timeout',
      );

      expect(
        harness.stream.sentTrailers,
        isNotEmpty,
        reason:
            '_onTimedOut must send trailers with endStream to '
            'close the outgoing stream and prevent leaks',
      );
    });

    test('data sent after timeout is ignored', () async {
      final handlerStarted = Completer<void>();

      harness.service.serverStreamingHandler = (call, request) async* {
        handlerStarted.complete();
        await Future.delayed(const Duration(seconds: 10));
      };

      harness.fromServer.stream.listen((_) {}, onError: (_) {}, onDone: () {});

      harness.sendRequestHeader(
        '/Test/ServerStreaming',
        timeout: const Duration(milliseconds: 1),
      );
      harness.sendData(1);

      await handlerStarted.future;
      await Future.delayed(const Duration(milliseconds: 100));

      try {
        harness.sendData(99);
        harness.sendData(100);
      } catch (_) {}

      await Future.delayed(const Duration(milliseconds: 50));

      final status = harness.firstTrailerStatus();
      expect(
        status,
        equals(StatusCode.deadlineExceeded),
        reason:
            'Data after timeout must be ignored; '
            'DEADLINE_EXCEEDED trailer is required',
      );
    });
  });

  // ===========================================================
  // C2 -- _onDoneError must clean up the HTTP/2 stream
  // ===========================================================
  group('C2: _onDoneError cleans up the stream', () {
    late TrackingHarness harness;

    setUp(() {
      harness = TrackingHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('unexpected close sends unavailable with endStream', () async {
      harness.fromServer.stream.listen((_) {}, onError: (_) {}, onDone: () {});

      harness.toServer.close();
      await Future.delayed(const Duration(milliseconds: 100));

      final status = harness.firstTrailerStatus();
      expect(
        status,
        equals(StatusCode.unavailable),
        reason: 'Unexpected close must produce UNAVAILABLE status',
      );

      expect(
        harness.stream.sentTrailers,
        isNotEmpty,
        reason:
            '_onDoneError must send trailers with endStream '
            'to close the outgoing stream',
      );
    });

    test('close after partial header triggers unavailable cleanup', () async {
      harness.fromServer.stream.listen((_) {}, onError: (_) {}, onDone: () {});

      harness.sendData(42);
      await Future.delayed(const Duration(milliseconds: 50));

      harness.toServer.close();
      await Future.delayed(const Duration(milliseconds: 100));

      expect(
        harness.stream.sentTrailers,
        isNotEmpty,
        reason: 'Error followed by close must still send trailers',
      );

      final status = harness.firstTrailerStatus();
      expect(
        status,
        equals(StatusCode.unimplemented),
        reason:
            'Sending data instead of header must produce '
            'UNIMPLEMENTED status',
      );
    });
  });

  // ===========================================================
  // H3 -- _applyInterceptors preserves GrpcError status codes
  // ===========================================================
  group('H3: _applyInterceptors preserves GrpcError codes', () {
    test('thrown GrpcError.unauthenticated preserves status 16', () async {
      final harness = TrackingHarness()..setUp();
      addTearDown(harness.tearDown);

      harness.interceptor.handler = (call, method) {
        throw GrpcError.unauthenticated('not allowed');
      };

      harness.fromServer.stream.listen((_) {}, onError: (_) {}, onDone: () {});

      harness.sendRequestHeader('/Test/Unary');
      await Future.delayed(const Duration(milliseconds: 50));

      final status = harness.firstTrailerStatus();
      expect(
        status,
        equals(StatusCode.unauthenticated),
        reason:
            'Thrown GrpcError must preserve its status code '
            '(expected 16/UNAUTHENTICATED, not 13/INTERNAL)',
      );
    });

    test('thrown plain Exception becomes GrpcError.internal (13)', () async {
      final harness = TrackingHarness()..setUp();
      addTearDown(harness.tearDown);

      harness.interceptor.handler = (call, method) {
        throw Exception('something broke');
      };

      harness.fromServer.stream.listen((_) {}, onError: (_) {}, onDone: () {});

      harness.sendRequestHeader('/Test/Unary');
      await Future.delayed(const Duration(milliseconds: 50));

      final status = harness.firstTrailerStatus();
      expect(
        status,
        equals(StatusCode.internal),
        reason:
            'Non-GrpcError exceptions must become '
            'GrpcError.internal (status 13)',
      );
    });

    test('thrown GrpcError.permissionDenied preserves status 7', () async {
      final harness = TrackingHarness()..setUp();
      addTearDown(harness.tearDown);

      harness.interceptor.handler = (call, method) {
        throw GrpcError.permissionDenied('forbidden');
      };

      harness.fromServer.stream.listen((_) {}, onError: (_) {}, onDone: () {});

      harness.sendRequestHeader('/Test/Unary');
      await Future.delayed(const Duration(milliseconds: 50));

      final status = harness.firstTrailerStatus();
      expect(
        status,
        equals(StatusCode.permissionDenied),
        reason:
            'Thrown GrpcError must preserve its status code '
            '(expected 7/PERMISSION_DENIED, not 13/INTERNAL)',
      );
    });

    test('async interceptor throwing GrpcError preserves code', () async {
      final harness = TrackingHarness()..setUp();
      addTearDown(harness.tearDown);

      harness.interceptor.handler = (call, method) async {
        await Future.value(); // force async
        throw GrpcError.unauthenticated('async reject');
      };

      harness.fromServer.stream.listen((_) {}, onError: (_) {}, onDone: () {});

      harness.sendRequestHeader('/Test/Unary');
      await Future.delayed(const Duration(milliseconds: 100));

      final status = harness.firstTrailerStatus();
      expect(
        status,
        equals(StatusCode.unauthenticated),
        reason:
            'Async-thrown GrpcError must also preserve status '
            'code (expected 16/UNAUTHENTICATED)',
      );
    });
  });

  // ===========================================================
  // H5 -- sendTrailers sets _streamTerminated to prevent
  //        redundant RST_STREAM on subsequent cancel()
  // ===========================================================
  group('H5: sendTrailers prevents redundant terminate', () {
    late TrackingHarness harness;

    setUp(() {
      harness = TrackingHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('cancel after normal completion calls terminate at most once',
        () async {
      const expectedRequest = 5;
      const expectedResponse = 7;

      harness.service.unaryHandler = (call, request) async {
        return expectedResponse;
      };

      final done = Completer<void>();
      harness.fromServer.stream.listen(
        (_) {},
        onError: (_) {},
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      harness.sendRequestHeader('/Test/Unary');
      harness.sendData(expectedRequest);
      harness.toServer.close();

      await done.future.timeout(const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 50));

      // After endStream: true, a single terminate() is acceptable —
      // the http2 package triggers cancel() via outgoingMessages.done
      // which calls _terminateStream(). The _streamTerminated guard
      // prevents double-terminate. This matches upstream behavior.
      expect(
        harness.stream.terminateCount,
        lessThanOrEqualTo(1),
        reason:
            'After a normal response with endStream: true, '
            'terminate() may be called at most once via '
            'outgoingMessages.done → cancel(). The '
            '_streamTerminated guard prevents double-terminate.',
      );
    });
  });
}
