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

// ==========================================================================
// Structured event logging (opt-in)
// ==========================================================================

/// A structured gRPC log event for production observability.
///
/// Provides typed fields for component, event type, context, and error,
/// enabling downstream loggers to filter, aggregate, and alert on
/// specific event patterns without parsing ad-hoc strings.
///
/// Example — integrating with a structured logging framework:
/// ```dart
/// grpcEventLogger = (event) {
///   myLogger.log(
///     severity: Level.WARNING,
///     message: event.formattedMessage,
///     labels: {
///       'component': event.component,
///       'event': event.event,
///       'context': event.context,
///     },
///     error: event.error,
///   );
/// };
/// ```
class GrpcLogEvent {
  /// Component that generated the event (e.g., `ServerHandler`,
  /// `NamedPipeServer`, `Http2Connection`).
  final String component;

  /// What happened (e.g., `deliver_error`, `close_stream`,
  /// `send_trailers`).
  final String event;

  /// Where it happened — typically the method name (e.g.,
  /// `_onDataActive`, `cancel`, `_readFromPipe`).
  final String context;

  /// The underlying error, if any.
  final Object? error;

  /// The pre-formatted log message string that was also passed to
  /// [grpcErrorLogger]. Preserved so structured consumers can use
  /// it as a human-readable fallback.
  final String formattedMessage;

  const GrpcLogEvent({
    required this.component,
    required this.event,
    required this.context,
    required this.formattedMessage,
    this.error,
  });

  @override
  String toString() => formattedMessage;
}

/// Callback type for structured gRPC event logging.
///
/// Set [grpcEventLogger] to receive typed [GrpcLogEvent] objects
/// alongside the existing string-based [grpcErrorLogger].
typedef GrpcEventLogger = void Function(GrpcLogEvent event);

/// Optional structured event logger.
///
/// When set, [logGrpcEvent] calls both [grpcErrorLogger] (with the
/// formatted string for backwards compatibility) and this callback
/// (with the structured [GrpcLogEvent]).
///
/// Defaults to `null` (structured logging disabled).
GrpcEventLogger? grpcEventLogger;

/// Logs a structured gRPC event.
///
/// Always calls [grpcErrorLogger] with [message] (preserving the
/// existing string-based logging behavior). Additionally calls
/// [grpcEventLogger] with a structured [GrpcLogEvent] if set.
void logGrpcEvent(
  String message, {
  required String component,
  required String event,
  required String context,
  Object? error,
}) {
  logGrpcError(message);
  final logger = grpcEventLogger;
  if (logger != null) {
    logger(GrpcLogEvent(component: component, event: event, context: context, formattedMessage: message, error: error));
  }
}
