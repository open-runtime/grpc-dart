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
// The real implementation is in named_pipe_server.dart.
//
// Every public member of the real NamedPipeServer is mirrored here so that
// code importing via the conditional export in grpc.dart sees a consistent
// API surface regardless of platform. All members throw [UnsupportedError].
//
// NOTE: dart:isolate is unavailable on web, so [spawnAcceptLoopIsolate] uses
// [Object] for Isolate/SendPort types with `covariant` so native-platform
// overrides can narrow to the real types.
import 'dart:async';

import 'package:meta/meta.dart';

import '../shared/codec_registry.dart';
import 'handler.dart';
import 'interceptor.dart';
import 'server.dart';
import 'server_keepalive.dart';
import 'service.dart';

UnsupportedError _namedPipeServerUnsupported(String member) {
  return UnsupportedError(
    '$member is not supported on this platform. '
    'Named pipes require dart:ffi, which is unavailable.',
  );
}

/// Win32 PIPE_UNLIMITED_INSTANCES value (255). Duplicated here to avoid
/// importing package:win32 which depends on dart:ffi.
const int _pipeUnlimitedInstances = 255;

/// A gRPC server that listens on Windows named pipes.
///
/// This stub is selected on platforms without `dart:ffi` support.
class NamedPipeServer extends ConnectionServer {
  /// Create a named pipe server for the given [services].
  NamedPipeServer.create({
    required List<Service> services,
    ServerKeepAliveOptions keepAliveOptions = const ServerKeepAliveOptions(),
    List<Interceptor> interceptors = const <Interceptor>[],
    List<ServerInterceptor> serverInterceptors = const <ServerInterceptor>[],
    CodecRegistry? codecRegistry,
    GrpcErrorHandler? errorHandler,
    int? maxInboundMessageSize,
  }) : super(
         services,
         interceptors,
         serverInterceptors,
         codecRegistry,
         errorHandler,
         keepAliveOptions,
         maxInboundMessageSize,
       ) {
    throw _namedPipeServerUnsupported('NamedPipeServer');
  }

  // ---------------------------------------------------------------------------
  // Public getters
  // ---------------------------------------------------------------------------

  /// The full Windows path for the named pipe.
  String? get pipePath {
    throw _namedPipeServerUnsupported('NamedPipeServer.pipePath');
  }

  /// Whether the server is running.
  bool get isRunning {
    throw _namedPipeServerUnsupported('NamedPipeServer.isRunning');
  }

  // ---------------------------------------------------------------------------
  // @visibleForTesting getters
  // ---------------------------------------------------------------------------

  /// Number of active named-pipe stream wrappers currently tracked.
  @visibleForTesting
  int get activePipeStreamCount {
    throw _namedPipeServerUnsupported('NamedPipeServer.activePipeStreamCount');
  }

  @visibleForTesting
  bool get isWindowsPlatform {
    throw _namedPipeServerUnsupported('NamedPipeServer.isWindowsPlatform');
  }

  @visibleForTesting
  Duration get stopPortBootstrapTimeout {
    throw _namedPipeServerUnsupported('NamedPipeServer.stopPortBootstrapTimeout');
  }

  @visibleForTesting
  Duration get readinessSignalTimeout {
    throw _namedPipeServerUnsupported('NamedPipeServer.readinessSignalTimeout');
  }

  // ---------------------------------------------------------------------------
  // Public methods
  // ---------------------------------------------------------------------------

  /// Starts the named pipe server.
  Future<void> serve({required String pipeName, int maxInstances = _pipeUnlimitedInstances}) {
    return Future<void>.error(_namedPipeServerUnsupported('NamedPipeServer.serve'));
  }

  /// Shuts down the server gracefully.
  Future<void> shutdown() {
    return Future<void>.error(_namedPipeServerUnsupported('NamedPipeServer.shutdown'));
  }

  // ---------------------------------------------------------------------------
  // @visibleForTesting methods
  // ---------------------------------------------------------------------------

  /// Spawn the accept-loop isolate.
  ///
  /// Uses [Object] for `mainPort`/`stopPort` (dart:isolate SendPort) and
  /// returns `Future<Object>` (dart:isolate Isolate) because dart:isolate is
  /// unavailable on web. Native-platform overrides narrow via covariant.
  @visibleForTesting
  Future<Object> spawnAcceptLoopIsolate({
    required String pipeName,
    required covariant Object mainPort,
    required covariant Object stopPort,
    required int maxInstances,
  }) {
    return Future<Object>.error(_namedPipeServerUnsupported('NamedPipeServer.spawnAcceptLoopIsolate'));
  }

  @visibleForTesting
  Future<void> handlePostStartupAcceptLoopErrorForTest(String error) {
    return Future<void>.error(_namedPipeServerUnsupported('NamedPipeServer.handlePostStartupAcceptLoopErrorForTest'));
  }

  @visibleForTesting
  void markRunningForTest() {
    throw _namedPipeServerUnsupported('NamedPipeServer.markRunningForTest');
  }

  @visibleForTesting
  void markReadyForTest() {
    throw _namedPipeServerUnsupported('NamedPipeServer.markReadyForTest');
  }
}
