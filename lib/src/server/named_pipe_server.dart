// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba
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
import 'dart:ffi';
import 'dart:io' show Platform, stderr;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http2/transport.dart';
import 'package:win32/win32.dart';

import '../shared/codec_registry.dart';
import 'handler.dart';
import 'interceptor.dart';
import 'server.dart';
import 'server_keepalive.dart';
import 'service.dart';

/// Buffer size for pipe I/O operations.
const int _kBufferSize = 65536;

/// A gRPC server that listens on Windows named pipes.
///
/// Named pipes provide secure, local-only IPC on Windows. They are the
/// Windows equivalent of Unix domain sockets.
///
/// ## Usage
///
/// ```dart
/// // Create server with services
/// final server = NamedPipeServer.create(
///   services: [MyServiceImpl()],
/// );
///
/// // Start listening on a named pipe
/// await server.serve(pipeName: 'my-service-12345');
///
/// // Server is now accepting connections at \\.\pipe\my-service-12345
///
/// // Shutdown when done
/// await server.shutdown();
/// ```
///
/// ## Security
///
/// - Uses PIPE_REJECT_REMOTE_CLIENTS to prevent SMB-based remote access
/// - Connections are local-only (same machine)
/// - No network exposure
///
/// ## Platform Support
///
/// This server only works on Windows. On macOS/Linux, use Unix domain sockets
/// with the regular [Server]:
///
/// ```dart
/// // Unix domain socket (macOS/Linux)
/// final server = Server.create(services: [MyServiceImpl()]);
/// await server.serve(
///   address: InternetAddress('/tmp/my-service.sock', type: InternetAddressType.unix),
/// );
/// ```
class NamedPipeServer extends ConnectionServer {
  /// Isolate running the pipe accept loop.
  Isolate? _serverIsolate;

  /// Port for receiving pipe handles from the isolate.
  ReceivePort? _receivePort;

  /// Subscription to the receive port.
  StreamSubscription<dynamic>? _receivePortSubscription;

  /// The name of the pipe being served.
  String? _pipeName;

  /// Whether the server is currently running.
  bool _isRunning = false;

  /// Completer that resolves when the server isolate has created the first
  /// pipe instance and is ready to accept client connections.
  Completer<void>? _readyCompleter;

  /// Create a named pipe server for the given [services].
  NamedPipeServer.create({
    required List<Service> services,
    ServerKeepAliveOptions keepAliveOptions = const ServerKeepAliveOptions(),
    List<Interceptor> interceptors = const <Interceptor>[],
    List<ServerInterceptor> serverInterceptors = const <ServerInterceptor>[],
    CodecRegistry? codecRegistry,
    GrpcErrorHandler? errorHandler,
  }) : super(services, interceptors, serverInterceptors, codecRegistry, errorHandler, keepAliveOptions);

  /// The full Windows path for the named pipe.
  String? get pipePath => _pipeName != null ? r'\\.\pipe\' + _pipeName! : null;

  /// Whether the server is running.
  bool get isRunning => _isRunning;

  /// Starts the named pipe server.
  ///
  /// [pipeName] is the name of the pipe (e.g., 'my-service-12345').
  /// The full path will be `\\.\pipe\{pipeName}`.
  ///
  /// This method returns only after the pipe has been created in the Windows
  /// namespace and is ready to accept client connections. This eliminates
  /// race conditions where clients attempt to connect before the pipe exists.
  ///
  /// Throws [UnsupportedError] if not running on Windows.
  /// Throws [StateError] if the server is already running.
  Future<void> serve({required String pipeName}) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Named pipes are only supported on Windows. '
        'Use Unix domain sockets on macOS/Linux.',
      );
    }

    if (_isRunning) {
      throw StateError('NamedPipeServer is already running');
    }

    _pipeName = pipeName;
    _receivePort = ReceivePort();
    _readyCompleter = Completer<void>();

    // Listen for incoming connections from the isolate
    _receivePortSubscription = _receivePort!.listen(_handleIsolateMessage);

    // Start the accept loop in a separate isolate
    _serverIsolate = await Isolate.spawn(
      _acceptLoop,
      _AcceptLoopConfig(pipeName: pipeName, mainPort: _receivePort!.sendPort),
    );

    // Wait for the isolate to confirm the pipe has been created.
    // This guarantees the pipe exists in the Windows namespace and clients
    // can successfully call CreateFile when serve() returns.
    await _readyCompleter!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError(
        'NamedPipeServer timed out waiting for pipe creation. '
        'The server isolate may have crashed.',
      ),
    );

    _isRunning = true;
  }

  /// Handles messages from the server isolate.
  void _handleIsolateMessage(dynamic message) {
    if (message is _ServerReady) {
      // Pipe has been created — serve() can return.
      if (!(_readyCompleter?.isCompleted ?? true)) {
        _readyCompleter!.complete();
      }
    } else if (message is _PipeConnection) {
      if (_isRunning) {
        _handleNewConnection(message);
      }
    } else if (message is _ServerError) {
      // If we haven't signaled readiness yet, propagate the error to serve().
      if (!(_readyCompleter?.isCompleted ?? true)) {
        _readyCompleter!.completeError(StateError(message.error));
      } else {
        stderr.writeln('NamedPipeServer error: ${message.error}');
      }
    }
  }

  /// Handles a new pipe connection.
  void _handleNewConnection(_PipeConnection connection) {
    // Create streams for the connection
    // ignore: close_sinks, closed via responsePort listener lifecycle
    final incoming = StreamController<List<int>>();
    // ignore: close_sinks, closed when connection ends
    final outgoing = StreamController<List<int>>();

    // Set up bidirectional communication with the isolate
    final responsePort = ReceivePort();
    responsePort.listen((message) {
      if (message is _PipeData) {
        incoming.add(message.data);
      } else if (message is _PipeClosed) {
        incoming.close();
        responsePort.close();
      }
    });

    // Forward outgoing data to the isolate
    outgoing.stream.listen(
      (data) {
        connection.sendPort.send(_PipeData(Uint8List.fromList(data)));
      },
      onDone: () {
        connection.sendPort.send(_PipeClosed());
      },
    );

    // Tell the connection handler where to send incoming data
    connection.sendPort.send(_SetResponsePort(responsePort.sendPort));

    // Create HTTP/2 connection and serve it
    final transportConnection = ServerTransportConnection.viaStreams(incoming.stream, outgoing);

    serveConnection(connection: transportConnection);
  }

  /// Shuts down the server gracefully.
  ///
  /// This method:
  /// 1. Stops accepting new connections
  /// 2. Opens a dummy client connection to unblock the server isolate's
  ///    blocking ConnectNamedPipe call (Isolate.kill cannot interrupt FFI)
  /// 3. Kills the server isolate
  Future<void> shutdown() async {
    if (!_isRunning) return;

    _isRunning = false;
    final pipeName = _pipeName;

    // Cancel the receive port subscription
    await _receivePortSubscription?.cancel();
    _receivePortSubscription = null;

    // Close the receive port
    _receivePort?.close();
    _receivePort = null;

    // Unblock the server isolate's blocking ConnectNamedPipe call.
    // ConnectNamedPipe is a synchronous Win32 call that blocks the isolate's
    // thread — Isolate.kill() cannot interrupt it. Opening a dummy client
    // connection satisfies ConnectNamedPipe, allowing the isolate to reach
    // its next event-loop checkpoint where the kill can take effect.
    if (pipeName != null) {
      _connectDummyClient(pipeName);
    }

    // Kill the server isolate (now unblocked)
    _serverIsolate?.kill(priority: Isolate.immediate);
    _serverIsolate = null;

    _pipeName = null;
    _readyCompleter = null;
  }

  /// Opens and immediately closes a dummy client connection to unblock
  /// a blocking ConnectNamedPipe call in the server isolate.
  static void _connectDummyClient(String pipeName) {
    final pipePath = r'\\.\pipe\' + pipeName;
    final pipePathPtr = pipePath.toNativeUtf16();
    try {
      final hPipe = CreateFile(pipePathPtr, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, NULL);
      if (hPipe != INVALID_HANDLE_VALUE) {
        CloseHandle(hPipe);
      }
    } finally {
      calloc.free(pipePathPtr);
    }
  }
}

// =============================================================================
// Isolate Communication Messages
// =============================================================================

/// Configuration for the accept loop isolate.
class _AcceptLoopConfig {
  final String pipeName;
  final SendPort mainPort;

  _AcceptLoopConfig({required this.pipeName, required this.mainPort});
}

/// Message indicating the server has created the first pipe instance and is
/// ready to accept client connections.
class _ServerReady {}

/// Message indicating a new pipe connection.
class _PipeConnection {
  final SendPort sendPort;

  _PipeConnection(this.sendPort);
}

/// Message containing pipe data.
class _PipeData {
  final Uint8List data;

  _PipeData(this.data);
}

/// Message indicating the pipe is closed.
class _PipeClosed {}

/// Message to set the response port for a connection.
class _SetResponsePort {
  final SendPort sendPort;

  _SetResponsePort(this.sendPort);
}

/// Message indicating a server error.
class _ServerError {
  final String error;

  _ServerError(this.error);
}

// =============================================================================
// Server Isolate
// =============================================================================

/// The accept loop running in a separate isolate.
///
/// Creates named pipe instances in a loop, waiting for client connections.
/// Sends [_ServerReady] after the first pipe is created so the main isolate
/// knows clients can connect.
Future<void> _acceptLoop(_AcceptLoopConfig config) async {
  final pipePath = r'\\.\pipe\' + config.pipeName;
  final pipePathPtr = pipePath.toNativeUtf16();
  var readySent = false;

  try {
    while (true) {
      // Create a new pipe instance for each connection
      final hPipe = CreateNamedPipe(
        pipePathPtr,
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        PIPE_UNLIMITED_INSTANCES,
        _kBufferSize,
        _kBufferSize,
        0, // Default timeout
        nullptr, // Default security
      );

      if (hPipe == INVALID_HANDLE_VALUE) {
        final error = GetLastError();
        config.mainPort.send(_ServerError('CreateNamedPipe failed: $error'));
        break;
      }

      // Signal readiness after the first pipe instance is created.
      // At this point the pipe exists in the Windows namespace and
      // clients can successfully call CreateFile to connect.
      if (!readySent) {
        config.mainPort.send(_ServerReady());
        readySent = true;
      }

      // Wait for a client to connect (blocking).
      // This blocks the isolate thread until a client calls CreateFile on the
      // pipe, or until the server shuts down (via dummy client connection).
      final connected = ConnectNamedPipe(hPipe, nullptr);
      if (connected == 0 && GetLastError() != ERROR_PIPE_CONNECTED) {
        CloseHandle(hPipe);
        continue;
      }

      // Handle this connection in a separate handler
      _spawnConnectionHandler(hPipe, config.mainPort);
    }
  } finally {
    calloc.free(pipePathPtr);
  }
}

/// Spawns a handler for a single pipe connection.
void _spawnConnectionHandler(int hPipe, SendPort mainPort) {
  // Create a port for this connection's communication
  final connectionPort = ReceivePort();
  SendPort? responsePort;

  // Notify main isolate of new connection
  mainPort.send(_PipeConnection(connectionPort.sendPort));

  // Handle messages for this connection
  connectionPort.listen((message) {
    if (message is _SetResponsePort) {
      responsePort = message.sendPort;
      // Start reading from the pipe
      _startPipeReader(hPipe, responsePort!);
    } else if (message is _PipeData) {
      // Write data to the pipe
      _writeToPipe(hPipe, message.data);
    } else if (message is _PipeClosed) {
      // Close the pipe
      FlushFileBuffers(hPipe);
      DisconnectNamedPipe(hPipe);
      CloseHandle(hPipe);
      connectionPort.close();
    }
  });
}

/// Starts reading from a pipe and sending data to the response port.
Future<void> _startPipeReader(int hPipe, SendPort responsePort) async {
  final buffer = calloc<Uint8>(_kBufferSize);
  final bytesRead = calloc<DWORD>();

  try {
    while (true) {
      bytesRead.value = 0;

      final success = ReadFile(hPipe, buffer, _kBufferSize, bytesRead, nullptr);

      if (success == 0) {
        final error = GetLastError();
        if (error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA) {
          break;
        }
        stderr.writeln('Pipe read error: $error');
        break;
      }

      final count = bytesRead.value;
      if (count == 0) {
        // Use a 1ms delay to yield to the event loop without busy-waiting.
        // Duration.zero only yields to microtasks, causing a CPU-wasting
        // spin loop.
        await Future.delayed(const Duration(milliseconds: 1));
        continue;
      }

      // Copy and send data
      final data = Uint8List(count);
      for (var i = 0; i < count; i++) {
        data[i] = buffer[i];
      }
      responsePort.send(_PipeData(data));
    }
  } finally {
    calloc.free(buffer);
    calloc.free(bytesRead);
    responsePort.send(_PipeClosed());
  }
}

/// Writes data to a pipe.
void _writeToPipe(int hPipe, Uint8List data) {
  final buffer = calloc<Uint8>(data.length);
  final bytesWritten = calloc<DWORD>();

  try {
    for (var i = 0; i < data.length; i++) {
      buffer[i] = data[i];
    }

    final success = WriteFile(hPipe, buffer, data.length, bytesWritten, nullptr);

    if (success == 0) {
      final error = GetLastError();
      stderr.writeln('Pipe write error: $error');
    }
  } finally {
    calloc.free(buffer);
    calloc.free(bytesWritten);
  }
}
