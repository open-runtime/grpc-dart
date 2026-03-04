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
  }) : super(services, interceptors, serverInterceptors, codecRegistry, errorHandler, keepAliveOptions) {
    throw _namedPipeServerUnsupported('NamedPipeServer');
  }

  /// The full Windows path for the named pipe.
  String? get pipePath {
    throw _namedPipeServerUnsupported('NamedPipeServer.pipePath');
  }

  /// Whether the server is running.
  bool get isRunning {
    throw _namedPipeServerUnsupported('NamedPipeServer.isRunning');
  }

  /// Starts the named pipe server.
  Future<void> serve({required String pipeName}) {
    return Future<void>.error(_namedPipeServerUnsupported('NamedPipeServer.serve'));
  }

  /// Shuts down the server gracefully.
  Future<void> shutdown() {
    return Future<void>.error(_namedPipeServerUnsupported('NamedPipeServer.shutdown'));
  }
}
