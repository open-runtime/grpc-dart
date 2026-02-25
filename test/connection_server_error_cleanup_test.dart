// Copyright (c) 2024, the gRPC project authors. Please see the AUTHORS
// file for details. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied. See the License for the specific language governing
// permissions and limitations under the License.

/// Regression tests for the H4 fix: connection stream error cleanup.
///
/// When [ConnectionServer.serveConnection] receives an error on the
/// connection's [incomingStreams], it must clean up exactly the same
/// state that [onDone] cleans up:
///   - cancel all active handlers for that connection
///   - remove the connection from [_connections]
///   - remove the connection from [handlers]
///   - close the onDataReceived controller
///
/// Before the H4 fix, the onError callback only logged the error
/// and leaked all connection state.
@TestOn('vm')
library;

import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Mock ServerTransportConnection that allows injecting errors
// ---------------------------------------------------------------------------

/// A minimal mock of [ServerTransportConnection] whose
/// [incomingStreams] is driven by a [StreamController] the test
/// controls.
class MockServerTransportConnection implements ServerTransportConnection {
  final StreamController<ServerTransportStream> _incomingController =
      StreamController<ServerTransportStream>();

  bool terminateCalled = false;
  bool finishCalled = false;

  @override
  Stream<ServerTransportStream> get incomingStreams =>
      _incomingController.stream;

  /// Inject an error into the incoming streams.
  void emitError(Object error, [StackTrace? stackTrace]) {
    _incomingController.addError(error, stackTrace ?? StackTrace.current);
  }

  /// Close the incoming streams normally (triggers onDone).
  void closeIncoming() {
    _incomingController.close();
  }

  // -- TransportConnection interface stubs --

  @override
  Stream<int> get onPingReceived => const Stream.empty();

  @override
  Stream<void> get onFrameReceived => const Stream.empty();

  @override
  Future<void> get onInitialPeerSettingsReceived => Completer<void>().future;

  @override
  set onActiveStateChanged(ActiveStateHandler callback) {}

  @override
  Future<void> finish() async {
    finishCalled = true;
  }

  @override
  Future<void> terminate([int? errorCode]) async {
    terminateCalled = true;
  }

  @override
  Future<void> ping() async {}
}

// ---------------------------------------------------------------------------
// Minimal Service so ConnectionServer has something to register
// ---------------------------------------------------------------------------

class _NoOpService extends Service {
  @override
  String get $name => 'NoOp';

  _NoOpService() {
    $addMethod(
      ServiceMethod<int, int>(
        'Ping',
        _ping,
        false,
        false,
        (List<int> value) => value.length,
        (int value) => List.filled(value, 0),
      ),
    );
  }

  Future<int> _ping(ServiceCall call, Future<int> request) async {
    return await request;
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ConnectionServer.serveConnection error cleanup (H4)', () {
    late ConnectionServer server;
    late _NoOpService service;

    setUp(() {
      service = _NoOpService();
      server = ConnectionServer([service]);
    });

    test('onDone removes connection from handlers and '
        '_connections (baseline)', () async {
      final conn = MockServerTransportConnection();

      await server.serveConnection(connection: conn);

      // The connection should be tracked.
      expect(server.handlers.containsKey(conn), isTrue);

      // Close the stream normally (triggers onDone).
      conn.closeIncoming();

      // Allow microtasks to flush.
      await Future.delayed(Duration.zero);

      // After onDone, state should be fully cleaned up.
      expect(
        server.handlers.containsKey(conn),
        isFalse,
        reason: 'onDone must remove the connection from handlers',
      );
    });

    test('onError on incomingStreams cleans up connection '
        'state (non-Error)', () async {
      final conn = MockServerTransportConnection();

      await server.serveConnection(connection: conn);

      // Verify connection is tracked.
      expect(server.handlers.containsKey(conn), isTrue);

      // Emit a non-Error (e.g. Exception / String).
      // This exercises the path where the current code
      // (pre-fix) just swallows the error.
      conn.emitError(Exception('transport reset by peer'));

      // Allow microtasks to flush.
      await Future.delayed(Duration.zero);

      // H4 expectation: the connection must be removed
      // from handlers even when the stream errors.
      expect(
        server.handlers.containsKey(conn),
        isFalse,
        reason:
            'H4 fix: onError must remove the connection '
            'from handlers, just like onDone does',
      );
    });

    test('onError on incomingStreams cleans up when an Error '
        'is emitted', () async {
      final conn = MockServerTransportConnection();

      // Use a Zone to catch the re-thrown Error so it
      // does not escape the test.
      final errorsCaught = <Object>[];

      await runZonedGuarded(
        () async {
          await server.serveConnection(connection: conn);

          expect(server.handlers.containsKey(conn), isTrue);

          // Emit an actual Error (triggers the
          // Zone.current.handleUncaughtError path).
          conn.emitError(StateError('mock transport error'));

          // Allow microtasks to flush.
          await Future.delayed(Duration.zero);
        },
        (error, stack) {
          errorsCaught.add(error);
        },
      );

      // Allow any remaining microtasks to flush.
      await Future.delayed(Duration.zero);

      // The Error should have been forwarded to the zone.
      expect(
        errorsCaught,
        isNotEmpty,
        reason:
            'Errors should be forwarded to '
            'Zone.handleUncaughtError',
      );

      // H4 expectation: cleanup still happens.
      expect(
        server.handlers.containsKey(conn),
        isFalse,
        reason:
            'H4 fix: onError must clean up even when '
            'the error is an Error subclass',
      );
    });

    test('multiple connections: error on one does not affect '
        'the other', () async {
      final conn1 = MockServerTransportConnection();
      final conn2 = MockServerTransportConnection();

      await server.serveConnection(connection: conn1);
      await server.serveConnection(connection: conn2);

      expect(server.handlers.containsKey(conn1), isTrue);
      expect(server.handlers.containsKey(conn2), isTrue);

      // Error on conn1 only.
      conn1.emitError(Exception('conn1 transport error'));

      await Future.delayed(Duration.zero);

      // conn1 should be cleaned up, conn2 untouched.
      expect(
        server.handlers.containsKey(conn1),
        isFalse,
        reason:
            'Errored connection must be removed from '
            'handlers',
      );
      expect(
        server.handlers.containsKey(conn2),
        isTrue,
        reason: 'Healthy connection must remain in handlers',
      );

      // Clean up conn2 normally.
      conn2.closeIncoming();
      await Future.delayed(Duration.zero);
      expect(server.handlers.containsKey(conn2), isFalse);
    });

    test('error followed by done does not double-remove', () async {
      final conn = MockServerTransportConnection();

      await server.serveConnection(connection: conn);
      expect(server.handlers.containsKey(conn), isTrue);

      // Error then close: both should be safe.
      conn.emitError(Exception('transport hiccup'));

      await Future.delayed(Duration.zero);

      // Attempting to close after error should not throw.
      conn.closeIncoming();
      await Future.delayed(Duration.zero);

      expect(server.handlers.containsKey(conn), isFalse);
    });

    test('handlers list is empty after error cleanup '
        '(no leaked handlers)', () async {
      final conn = MockServerTransportConnection();

      await server.serveConnection(connection: conn);

      // Before error, handlers list exists (empty since
      // no streams were dispatched).
      expect(server.handlers[conn], isNotNull);
      expect(server.handlers[conn], isEmpty);

      conn.emitError(Exception('reset'));
      await Future.delayed(Duration.zero);

      // The entire entry should be gone.
      expect(
        server.handlers[conn],
        isNull,
        reason:
            'The handlers list for the connection must '
            'be fully removed, not just emptied',
      );
    });
  });
}
