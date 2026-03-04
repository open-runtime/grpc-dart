// Copyright (c) 2025, the gRPC project authors. Please see the AUTHORS file
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

// Stub for platforms that don't support dart:ffi (e.g. web).
// The real implementation is in named_pipe_transport.dart.
import 'dart:async';

import 'package:http2/transport.dart';

import 'client_transport_connector.dart';

UnsupportedError _namedPipeTransportUnsupported(String member) {
  return UnsupportedError(
    '$member is not supported on this platform. '
    'Named pipes require dart:ffi, which is unavailable.',
  );
}

/// A [ClientTransportConnector] stub for platforms without `dart:ffi`.
class NamedPipeTransportConnector implements ClientTransportConnector {
  /// The name of the pipe (without the `\\.\pipe\` prefix).
  final String pipeName;

  /// Creates a named pipe transport connector.
  NamedPipeTransportConnector(this.pipeName) {
    throw _namedPipeTransportUnsupported('NamedPipeTransportConnector');
  }

  /// The full Windows path for the named pipe.
  String get pipePath => r'\\.\pipe\' + pipeName;

  @override
  String get authority => 'localhost';

  @override
  Future<ClientTransportConnection> connect() {
    return Future<ClientTransportConnection>.error(
      _namedPipeTransportUnsupported('NamedPipeTransportConnector.connect'),
    );
  }

  @override
  Future<void> get done => Future<void>.value();

  @override
  void shutdown() {}
}

/// Exception thrown when a named pipe operation fails.
class NamedPipeException implements Exception {
  /// Human-readable error message.
  final String message;

  /// Win32 error code.
  final int errorCode;

  NamedPipeException(this.message, this.errorCode);

  @override
  String toString() => 'NamedPipeException: $message (code: $errorCode)';
}
