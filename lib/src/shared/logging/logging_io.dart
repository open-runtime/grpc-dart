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

import 'dart:io' show stderr;

/// Callback type for gRPC internal error logging.
///
/// Replace [grpcErrorLogger] to integrate with your application's logging
/// framework (e.g., `package:logging`, Sentry, etc.).
typedef GrpcErrorLogger = void Function(String message);

/// The active gRPC error logger. Defaults to writing to stderr.
///
/// Override this to capture gRPC internal errors in your logging framework:
/// ```dart
/// grpcErrorLogger = (message) => myLogger.warning(message);
/// ```
GrpcErrorLogger grpcErrorLogger = _defaultLogger;

void _defaultLogger(String message) {
  stderr.writeln(message);
}

/// Logs a gRPC internal error using the configured [grpcErrorLogger].
void logGrpcError(String message) {
  grpcErrorLogger(message);
}
