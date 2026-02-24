// Copyright (c) 2020, the gRPC project authors. Please see the AUTHORS file
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
import 'dart:io';
import 'package:test/test.dart';

/// Test functionality for Unix domain socket.
void testUds(String name, FutureOr<void> Function(InternetAddress) testCase) {
  test(
    name,
    skip: Platform.isWindows
        ? 'Unix domain sockets are not supported on Windows'
        : null,
    () async {
      final tempDir = await Directory.systemTemp.createTemp();
      final address = InternetAddress(
        '${tempDir.path}/socket',
        type: InternetAddressType.unix,
      );
      addTearDown(() => tempDir.delete(recursive: true));
      await testCase(address);
    },
  );
}

/// Test functionality for both TCP and Unix domain sockets.
void testTcpAndUds(
  String name,
  FutureOr<void> Function(InternetAddress) testCase, {
  String host = 'localhost',
}) {
  test(name, () async {
    final address = await InternetAddress.lookup(host);
    await testCase(address.first);
  });

  testUds('$name (over uds)', testCase);
}

/// Monotonically increasing counter used by [testNamedPipe] to guarantee
/// globally unique pipe names even when tests start within the same
/// microsecond (e.g., parallel test execution via `dart test --concurrency`).
int _pipeNameCounter = 0;

/// Test functionality for Windows named pipes.
///
/// [pipeName] is the base name for the pipe. A unique suffix will be added.
/// Only runs on Windows.
///
/// Each test has a 30-second timeout to prevent CI hangs. Named pipe tests
/// can hang indefinitely if the server isolate's blocking ConnectNamedPipe
/// call is never satisfied (e.g., due to a race condition or resource leak).
void testNamedPipe(
  String name,
  FutureOr<void> Function(String pipeName) testCase, {
  String basePipeName = 'grpc-test',
  Timeout timeout = const Timeout(Duration(seconds: 30)),
}) {
  test(
    '$name (over named pipe)',
    timeout: timeout,
    skip: Platform.isWindows ? null : 'Named pipes are Windows-only',
    () async {
      // Generate unique pipe name to avoid conflicts between parallel tests.
      //
      // Uniqueness is ensured by combining three components:
      //  1. microsecondsSinceEpoch — coarse time-based uniqueness
      //  2. _pipeNameCounter — monotonic counter for same-microsecond starts
      //  3. pid — differentiates across parallel test runner processes
      //
      // Previous approach used two separate DateTime.now() calls and
      // DateTime.microsecond (0-999 within the current second) which could
      // collide when tests start within the same millisecond.
      final now = DateTime.now();
      final counter = _pipeNameCounter++;
      final uniquePipeName =
          '$basePipeName-${now.microsecondsSinceEpoch}-$counter-$pid';
      await testCase(uniquePipeName);
    },
  );
}

/// Test functionality for all supported transports: TCP, Unix domain sockets, and named pipes.
///
/// On Windows: runs TCP and named pipe tests.
/// On macOS/Linux: runs TCP and Unix domain socket tests.
void testAllTransports(
  String name, {
  required FutureOr<void> Function(InternetAddress) tcpTestCase,
  FutureOr<void> Function(InternetAddress)? udsTestCase,
  FutureOr<void> Function(String pipeName)? namedPipeTestCase,
  String host = 'localhost',
  String basePipeName = 'grpc-test',
}) {
  // TCP test (all platforms)
  test(name, () async {
    final address = await InternetAddress.lookup(host);
    await tcpTestCase(address.first);
  });

  // Unix domain socket test (macOS/Linux only)
  if (udsTestCase != null) {
    testUds('$name (over uds)', udsTestCase);
  }

  // Named pipe test (Windows only)
  if (namedPipeTestCase != null) {
    testNamedPipe(name, namedPipeTestCase, basePipeName: basePipeName);
  }
}
