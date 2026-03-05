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

/// Regression tests for Http2ClientConnection hardening fixes.
///
/// - **H1**: `finish()` catchError in `_refreshConnectionIfUnhealthy` —
///   when the transport is dead or the connection timeout has elapsed,
///   `finish()` may return a failed Future. Without `.catchError()`, the
///   unhandled async error crashes the isolate.
/// - **M5**: `!isOpen` path in `_refreshConnectionIfUnhealthy` — when
///   `transport.isOpen` returns false but `connectionTimeout` has NOT
///   elapsed, the connection should be abandoned without calling
///   `finish()`.
@TestOn('vm')
library;

import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import 'src/client_utils.dart';

/// Awaits [future] and swallows any [GrpcError].
/// Returns `true` if [future] completed with a [GrpcError],
/// `false` otherwise.
Future<bool> awaitSwallowingGrpcError(Future future) async {
  try {
    await future;
    return false;
  } on GrpcError {
    return true;
  }
}

void main() {
  // -------------------------------------------------------------------
  // H1: finish() catchError in _refreshConnectionIfUnhealthy
  // -------------------------------------------------------------------
  group('H1: finish() catchError in '
      '_refreshConnectionIfUnhealthy', () {
    late ClientHarness harness;

    setUp(() {
      harness = ClientHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    Future<void> makeFirstRpc() async {
      void handleRequest(StreamMessage message) {
        harness
          ..sendResponseHeader()
          ..sendResponseValue(1)
          ..sendResponseTrailer();
      }

      await harness.runTest(
        clientCall: harness.client.unary(1),
        expectedResult: 1,
        expectedPath: '/Test/Unary',
        serverHandlers: [handleRequest],
      );
    }

    test('finish() returning a failed Future during '
        'connection refresh does not produce an '
        'unhandled async error', () async {
      await makeFirstRpc();

      // Force shouldRefresh = true: set connectionTimeout
      // to zero so any elapsed time exceeds it.
      harness.channelOptions.connectionTimeout = Duration.zero;

      // Make finish() return a failed Future (simulates
      // calling finish() on an already-terminated
      // transport).
      when(harness.transport.finish()).thenAnswer(
        (_) => Future.error(StateError('Transport already terminated')),
      );

      // Block reconnection.
      harness.connection!.connectionError = 'Blocked for test';

      // The next dispatchCall triggers
      // _refreshConnectionIfUnhealthy which calls
      // finish(). Without .catchError() on finish(),
      // the failed Future becomes an unhandled async
      // error and the test framework catches it,
      // failing the test.
      final call2Future = awaitSwallowingGrpcError(harness.client.unary(2));

      // Give time for the unhandled error from finish()
      // to surface (if it exists).
      await Future.delayed(const Duration(milliseconds: 200));

      // Wait for call2 to complete (it will fail with
      // a GrpcError from the blocked reconnection).
      await call2Future;

      await harness.channel.terminate();
    });

    test('finish() throwing synchronously during '
        'connection refresh does not crash dispatchCall', () async {
      await makeFirstRpc();

      harness.channelOptions.connectionTimeout = Duration.zero;

      // Make finish() throw synchronously.
      when(
        harness.transport.finish(),
      ).thenThrow(StateError('Already terminated'));

      // Block reconnection.
      harness.connection!.connectionError = 'Blocked for test';

      // dispatchCall should not propagate the synchronous
      // throw from finish() to the caller.
      final call2Future = awaitSwallowingGrpcError(harness.client.unary(2));

      await Future.delayed(const Duration(milliseconds: 200));

      await call2Future;

      await harness.channel.terminate();
    });

    test('transport dead AND connectionTimeout elapsed: '
        'finish() error is caught', () async {
      await makeFirstRpc();

      // Both conditions: transport reports not open AND
      // timeout has elapsed.
      harness.channelOptions.connectionTimeout = Duration.zero;
      when(harness.transport.isOpen).thenReturn(false);
      when(harness.transport.finish()).thenAnswer(
        (_) => Future.error(StateError('Transport already terminated')),
      );

      // Block reconnection.
      harness.connection!.connectionError = 'Blocked for test';

      final call2Future = awaitSwallowingGrpcError(harness.client.unary(2));

      await Future.delayed(const Duration(milliseconds: 200));

      // Connection should have been abandoned.
      expect(
        harness.connection!.state,
        anyOf(ConnectionState.idle, ConnectionState.transientFailure),
      );

      await call2Future;

      await harness.channel.terminate();
    });
  });

  // -------------------------------------------------------------------
  // M5: !isOpen path in _refreshConnectionIfUnhealthy
  // -------------------------------------------------------------------
  group('M5: !isOpen path in '
      '_refreshConnectionIfUnhealthy '
      '(transport dead, timeout not elapsed)', () {
    late ClientHarness harness;
    late List<ConnectionState> connectionStates;

    setUp(() {
      harness = ClientHarness()..setUp();
      connectionStates = <ConnectionState>[];
      harness.connection!.onStateChanged = (state) {
        connectionStates.add(state);
      };
    });

    tearDown(() {
      harness.tearDown();
    });

    Future<void> makeFirstRpc() async {
      void handleRequest(StreamMessage message) {
        harness
          ..sendResponseHeader()
          ..sendResponseValue(1)
          ..sendResponseTrailer();
      }

      await harness.runTest(
        clientCall: harness.client.unary(1),
        expectedResult: 1,
        expectedPath: '/Test/Unary',
        serverHandlers: [handleRequest],
      );
    }

    test('dispatchCall abandons and reconnects when '
        'transport isOpen returns false', () async {
      await makeFirstRpc();

      // Connection is ready.
      expect(harness.connection!.state, ConnectionState.ready);
      expect(connectionStates, contains(ConnectionState.ready));

      when(harness.transport.isOpen).thenReturn(false);

      // Block reconnection to prevent loops.
      harness.connection!.connectionError = 'Blocked for test';

      // Clear interactions from the initial connection
      // so we can verify finish() is not called.
      clearInteractions(harness.transport);

      // Clear recorded states.
      connectionStates.clear();

      // Start second call.
      final call2Future = awaitSwallowingGrpcError(harness.client.unary(2));

      await Future.delayed(const Duration(milliseconds: 200));

      // The connection should have been abandoned.
      expect(harness.connection!.state, isNot(ConnectionState.ready));

      await call2Future;

      await harness.channel.terminate();
    });

    test('dispatchCall with dead transport does not '
        'call finish() (only abandons)', () async {
      await makeFirstRpc();

      // Clear interactions from initial connection.
      clearInteractions(harness.transport);

      // Transport is dead but timeout has not elapsed.
      when(harness.transport.isOpen).thenReturn(false);

      // Block reconnection.
      harness.connection!.connectionError = 'Blocked for test';

      final call2Future = awaitSwallowingGrpcError(harness.client.unary(2));

      await Future.delayed(const Duration(milliseconds: 200));

      // finish() should NOT have been called because
      // shouldRefresh is false (connectionTimeout not
      // elapsed yet).
      verifyNever(harness.transport.finish());

      await call2Future;

      await harness.channel.terminate();
    });

    test('dead transport triggers state transition '
        'away from ready', () async {
      await makeFirstRpc();

      // After first RPC, should have connecting->ready.
      expect(connectionStates, contains(ConnectionState.ready));

      // Clear to track only new transitions.
      connectionStates.clear();

      when(harness.transport.isOpen).thenReturn(false);

      // Block reconnection.
      harness.connection!.connectionError = 'Blocked for test';

      final call2Future = awaitSwallowingGrpcError(harness.client.unary(2));

      await Future.delayed(const Duration(milliseconds: 200));

      // Should have transitioned away from ready.
      expect(
        connectionStates,
        isNotEmpty,
        reason: 'Expected state transition after transport died',
      );
      // First new state should be idle (from
      // _abandonConnection, no pending calls at that
      // point).
      expect(connectionStates.first, ConnectionState.idle);

      await call2Future;

      await harness.channel.terminate();
    });
  });
}
