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

import 'dart:async';
import 'dart:io';

import '../shared/codec_registry.dart';
import '../shared/local_ipc.dart';
import 'handler.dart' show GrpcErrorHandler;
import 'interceptor.dart';
import 'named_pipe_server_stub.dart' if (dart.library.ffi) 'named_pipe_server.dart';
import 'server.dart';
import 'server_keepalive.dart';
import 'service.dart';

/// A local-only gRPC server that uses the best IPC transport per platform.
///
/// - macOS/Linux: Unix domain sockets
/// - Windows: Named pipes
///
/// ```dart
/// final server = LocalGrpcServer('my-service', services: [MyServiceImpl()]);
/// await server.serve();
/// // Clients connect via: LocalGrpcChannel('my-service')
/// await server.shutdown();
/// ```
///
/// The service name determines the IPC address:
/// - macOS/Linux: `$XDG_RUNTIME_DIR/grpc-local/my-service.sock`
/// - Windows: `\\.\pipe\my-service`
///
/// Stale UDS socket files are cleaned up automatically during [serve]
/// and [shutdown]. Named pipes are cleaned up by the OS on process exit.
///
/// **Security**: This server uses plaintext (no TLS) because the transport
/// never leaves the machine. The UDS socket directory is created with
/// owner-only permissions (0700). On Windows, named pipes use
/// `PIPE_REJECT_REMOTE_CLIENTS`. Any process running as the same OS user
/// can connect — use a [ServerInterceptor] with a shared token if you
/// need per-process authentication.
class LocalGrpcServer {
  /// The service name used for address resolution.
  final String serviceName;

  final List<Service> _services;
  final List<Interceptor> _interceptors;
  final List<ServerInterceptor> _serverInterceptors;
  final CodecRegistry? _codecRegistry;
  final GrpcErrorHandler? _errorHandler;
  final ServerKeepAliveOptions _keepAliveOptions;
  final int? _maxInboundMessageSize;

  Object? _delegate;
  String? _udsPath;

  /// Creates a local gRPC server.
  ///
  /// [serviceName] must contain only `[a-zA-Z0-9._-]` and be at most
  /// 64 characters.
  LocalGrpcServer(
    this.serviceName, {
    required List<Service> services,
    List<Interceptor> interceptors = const <Interceptor>[],
    List<ServerInterceptor> serverInterceptors = const <ServerInterceptor>[],
    CodecRegistry? codecRegistry,
    GrpcErrorHandler? errorHandler,
    ServerKeepAliveOptions keepAliveOptions = const ServerKeepAliveOptions(),
    int? maxInboundMessageSize,
  }) : _services = services,
       _interceptors = interceptors,
       _serverInterceptors = serverInterceptors,
       _codecRegistry = codecRegistry,
       _errorHandler = errorHandler,
       _keepAliveOptions = keepAliveOptions,
       _maxInboundMessageSize = maxInboundMessageSize {
    validateServiceName(serviceName);
  }

  /// Whether the server is currently listening.
  bool get isServing {
    final d = _delegate;
    if (d is NamedPipeServer) return d.isRunning;
    if (d is Server) return d.port != null;
    return false;
  }

  /// The resolved IPC address (socket path or pipe path). Null before [serve].
  String? get address {
    if (_delegate is NamedPipeServer) return (_delegate as NamedPipeServer).pipePath;
    return _udsPath;
  }

  /// The underlying [ConnectionServer] for advanced access.
  ConnectionServer get connectionServer {
    final d = _delegate;
    if (d == null) throw StateError('Server not started. Call serve() first.');
    return d as ConnectionServer;
  }

  /// Starts listening for connections.
  ///
  /// Returns when the server is ready to accept clients.
  /// On macOS/Linux, creates the socket directory and cleans up stale files.
  Future<void> serve() async {
    if (_delegate != null) throw StateError('Already serving');

    if (Platform.isWindows) {
      final pipe = NamedPipeServer.create(
        services: _services,
        interceptors: _interceptors,
        serverInterceptors: _serverInterceptors,
        codecRegistry: _codecRegistry,
        errorHandler: _errorHandler,
        keepAliveOptions: _keepAliveOptions,
        maxInboundMessageSize: _maxInboundMessageSize,
      );
      await pipe.serve(pipeName: serviceName);
      _delegate = pipe;
    } else {
      final socketPath = udsSocketPath(serviceName);
      _udsPath = socketPath;

      final dir = Directory(defaultUdsDirectory());
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
        // Restrict to owner-only (0700) to prevent other local users
        // from connecting to our sockets on shared machines.
        Process.runSync('chmod', ['700', dir.path]);
      }

      final stale = File(socketPath);
      if (stale.existsSync()) stale.deleteSync();

      final server = Server.create(
        services: _services,
        interceptors: _interceptors,
        serverInterceptors: _serverInterceptors,
        codecRegistry: _codecRegistry,
        errorHandler: _errorHandler,
        keepAliveOptions: _keepAliveOptions,
        maxInboundMessageSize: _maxInboundMessageSize,
      );
      await server.serve(address: InternetAddress(socketPath, type: InternetAddressType.unix), port: 0);
      _delegate = server;
    }
  }

  /// Shuts down gracefully. In-flight RPCs are drained, then connections
  /// are terminated. On macOS/Linux, deletes the socket file.
  Future<void> shutdown() async {
    final d = _delegate;
    _delegate = null;

    if (d is NamedPipeServer) {
      await d.shutdown();
    } else if (d is Server) {
      await d.shutdown();
    }

    final path = _udsPath;
    if (path != null) {
      _udsPath = null;
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } on FileSystemException {
        // Socket file may already be gone (e.g., directory cleaned by OS).
      }
    }
  }
}
