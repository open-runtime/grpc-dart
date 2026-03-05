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
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:http2/transport.dart';
import 'package:meta/meta.dart';
import 'package:win32/win32.dart';

import '../shared/codec_registry.dart';
import '../shared/logging/logging.dart' show logGrpcEvent;
import '../shared/named_pipe_io.dart';
import 'handler.dart';
import 'interceptor.dart';
import 'server.dart';
import 'server_keepalive.dart';
import 'service.dart';

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
/// ## Architecture
///
/// The server uses a two-isolate architecture:
///
/// - **Server isolate**: Runs the accept loop (`CreateNamedPipe` +
///   `ConnectNamedPipe`). This isolate's only job is to accept connections
///   and send the raw Win32 pipe handle to the main isolate. It blocks on
///   `ConnectNamedPipe` which is a synchronous Win32 call — this is fine
///   because the isolate does nothing else while waiting.
///
/// - **Main isolate**: Handles all data I/O (reads and writes) for every
///   connection. Uses `PeekNamedPipe` polling to check for available data
///   before calling `ReadFile`, keeping the event loop responsive. This is
///   critical because the main isolate's event loop must remain unblocked
///   to process HTTP/2 framing, handle timeouts, and manage multiple
///   concurrent connections.
///
/// The previous architecture (data I/O in the server isolate) deadlocked
/// because `ConnectNamedPipe` blocked the server isolate's event loop,
/// preventing `PeekNamedPipe` polling and `WriteFile` calls from executing.
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

  /// Port for sending a cooperative stop signal to the accept loop isolate.
  ///
  /// The accept loop creates a [ReceivePort] and sends its [SendPort] back
  /// through a bootstrap port. During shutdown, the main isolate sends a
  /// message through this port to set the accept loop's `shouldStop` flag.
  /// This ensures the loop exits at the next yield point instead of
  /// re-entering the blocking [ConnectNamedPipe] FFI call.
  SendPort? _stopSendPort;

  /// The name of the pipe being served.
  String? _pipeName;

  /// Whether the server is currently running.
  bool _isRunning = false;

  /// Completer that resolves when the server isolate has created the first
  /// pipe instance and is ready to accept client connections.
  Completer<void>? _readyCompleter;

  /// Active pipe streams for connections being served.
  /// Tracked so shutdown() can close them all, causing their PeekNamedPipe
  /// read loops to exit and their Win32 handles to be cleaned up.
  final List<_ServerPipeStream> _activeStreams = [];

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
  String? get pipePath => _pipeName != null ? namedPipePath(_pipeName!) : null;

  /// Whether the server is running.
  bool get isRunning => _isRunning;

  /// Number of active named-pipe stream wrappers currently tracked.
  ///
  /// Exposed for transport lifecycle tests that verify stream cleanup.
  @visibleForTesting
  int get activePipeStreamCount => _activeStreams.length;

  @visibleForTesting
  bool get isWindowsPlatform => Platform.isWindows;

  @visibleForTesting
  Duration get stopPortBootstrapTimeout => const Duration(seconds: 5);

  @visibleForTesting
  Duration get readinessSignalTimeout => const Duration(seconds: 10);

  @visibleForTesting
  Future<Isolate> spawnAcceptLoopIsolate({
    required String pipeName,
    required SendPort mainPort,
    required SendPort stopPort,
    required int maxInstances,
  }) {
    return Isolate.spawn(
      _acceptLoop,
      _AcceptLoopConfig(pipeName: pipeName, mainPort: mainPort, maxInstances: maxInstances, stopPort: stopPort),
    );
  }

  /// Starts the named pipe server.
  ///
  /// [pipeName] is the name of the pipe (e.g., 'my-service-12345').
  /// The full path will be `\\.\pipe\{pipeName}`.
  ///
  /// [maxInstances] controls the maximum number of simultaneous named-pipe
  /// instances created by the server accept loop. Defaults to
  /// [PIPE_UNLIMITED_INSTANCES].
  ///
  /// This is primarily useful in tests that need to force
  /// `ERROR_PIPE_BUSY` conditions.
  ///
  /// This method returns only after the pipe has been created in the Windows
  /// namespace and is ready to accept client connections. This eliminates
  /// race conditions where clients attempt to connect before the pipe exists.
  ///
  /// Throws [UnsupportedError] if not running on Windows.
  /// Throws [StateError] if the server is already running.
  Future<void> serve({required String pipeName, int maxInstances = PIPE_UNLIMITED_INSTANCES}) async {
    if (!isWindowsPlatform) {
      throw UnsupportedError(
        'Named pipes are only supported on Windows. '
        'Use Unix domain sockets on macOS/Linux.',
      );
    }

    if (_isRunning) {
      throw StateError('NamedPipeServer is already running');
    }
    if (maxInstances < 1 || maxInstances > PIPE_UNLIMITED_INSTANCES) {
      throw ArgumentError.value(maxInstances, 'maxInstances', 'must be between 1 and $PIPE_UNLIMITED_INSTANCES');
    }

    _pipeName = pipeName;
    _receivePort = ReceivePort();
    _readyCompleter = Completer<void>();

    // Bootstrap port: the accept loop isolate creates a ReceivePort and
    // sends its SendPort back through this port. We store it in
    // _stopSendPort to send a cooperative stop signal during shutdown.
    final stopBootstrapPort = ReceivePort();
    final stopBootstrapCompleter = Completer<SendPort>();
    final stopBootstrapSub = stopBootstrapPort.listen((message) {
      if (message is SendPort && !stopBootstrapCompleter.isCompleted) {
        stopBootstrapCompleter.complete(message);
      }
    });

    try {
      // Listen for incoming connections from the isolate.
      _receivePortSubscription = _receivePort!.listen(_handleIsolateMessage);

      try {
        // Start the accept loop in a separate isolate.
        _serverIsolate = await spawnAcceptLoopIsolate(
          pipeName: pipeName,
          mainPort: _receivePort!.sendPort,
          maxInstances: maxInstances,
          stopPort: stopBootstrapPort.sendPort,
        );

        // Wait for the isolate to send back its stop SendPort.
        _stopSendPort = await stopBootstrapCompleter.future.timeout(
          stopPortBootstrapTimeout,
          onTimeout: () => throw StateError('NamedPipeServer timed out waiting for stop port from accept loop.'),
        );

        // Wait for the isolate to confirm the pipe has been created.
        // This guarantees the pipe exists in the Windows namespace and clients
        // can successfully call CreateFile when serve() returns.
        await _readyCompleter!.future.timeout(
          readinessSignalTimeout,
          onTimeout: () => throw StateError(
            'NamedPipeServer timed out waiting for pipe creation. '
            'The server isolate may have crashed.',
          ),
        );
        _isRunning = true;
      } finally {
        await stopBootstrapSub.cancel();
        stopBootstrapPort.close();
      }
    } catch (error, stackTrace) {
      await _cleanupAfterServeStartupFailureAndRethrow(startupError: error, startupStackTrace: stackTrace);
    }
  }

  /// Cleans up startup resources after serve() fails before isRunning=true.
  ///
  /// This path is used for both stop-port bootstrap timeout failures and
  /// readiness timeout/error failures so shutdown() does not need to recover
  /// partially initialized startup state.
  Future<Never> _cleanupAfterServeStartupFailureAndRethrow({
    required Object startupError,
    required StackTrace startupStackTrace,
  }) async {
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    try {
      _serverIsolate?.kill(priority: Isolate.immediate);
      _serverIsolate = null;
      _stopSendPort = null;

      await _receivePortSubscription?.cancel();
      _receivePortSubscription = null;
      _receivePort?.close();
      _receivePort = null;

      _pipeName = null;
      _readyCompleter = null;
      _isRunning = false;
    } catch (error, stackTrace) {
      cleanupError = error;
      cleanupStackTrace = stackTrace;
    }

    if (cleanupError != null && cleanupStackTrace != null) {
      Error.throwWithStackTrace(
        StateError(
          'NamedPipeServer startup failed: $startupError. '
          'Cleanup also failed: $cleanupError',
        ),
        cleanupStackTrace,
      );
    }

    Error.throwWithStackTrace(startupError, startupStackTrace);
  }

  /// Handles a fatal accept-loop error after startup readiness.
  ///
  /// Before startup readiness, serve() receives the error via
  /// [_readyCompleter]. After readiness, there is no waiting caller, so
  /// this path triggers a fail-safe shutdown to avoid a "running but no
  /// longer accepting connections" state.
  Future<void> _handlePostStartupAcceptLoopError(String error) async {
    logGrpcEvent(
      '[gRPC] NamedPipeServer error: $error',
      component: 'NamedPipeServer',
      event: 'isolate_error',
      context: '_handleIsolateMessage',
      error: error,
    );

    final readySignaled = _readyCompleter?.isCompleted ?? false;
    if (!_isRunning && !readySignaled) return;

    // Handle the tiny serve() transition window where readiness is complete
    // but _isRunning has not yet been observed as true.
    if (!_isRunning && readySignaled) {
      _isRunning = true;
    }

    try {
      await shutdown();
    } catch (shutdownError) {
      logGrpcEvent(
        '[gRPC] NamedPipeServer fail-safe shutdown failed after isolate error: '
        '$shutdownError',
        component: 'NamedPipeServer',
        event: 'isolate_error_shutdown_failed',
        context: '_handlePostStartupAcceptLoopError',
        error: shutdownError,
      );
    }
  }

  @visibleForTesting
  Future<void> handlePostStartupAcceptLoopErrorForTest(String error) {
    return _handlePostStartupAcceptLoopError(error);
  }

  @visibleForTesting
  void markRunningForTest() {
    _isRunning = true;
  }

  @visibleForTesting
  void markReadyForTest() {
    _readyCompleter ??= Completer<void>();
    if (!_readyCompleter!.isCompleted) {
      _readyCompleter!.complete();
    }
  }

  /// Handles messages from the server isolate.
  void _handleIsolateMessage(dynamic message) {
    if (message is _ServerReady) {
      // Pipe has been created — serve() can return.
      if (!(_readyCompleter?.isCompleted ?? true)) {
        _readyCompleter!.complete();
      }
    } else if (message is _PipeHandle) {
      if (_isRunning) {
        _handleNewConnection(message.handle);
      } else {
        // Server is shutting down — clean up the handle immediately.
        DisconnectNamedPipe(message.handle);
        CloseHandle(message.handle);
      }
    } else if (message is _ServerError) {
      // If we haven't signaled readiness yet, propagate the error to serve().
      if (!(_readyCompleter?.isCompleted ?? true)) {
        _readyCompleter!.completeError(StateError(message.error));
      } else {
        unawaited(_handlePostStartupAcceptLoopError(message.error));
      }
    }
  }

  /// Handles a new pipe connection.
  ///
  /// All data I/O (reads and writes) runs in the main isolate using
  /// [PeekNamedPipe] polling for reads and direct [WriteFile] for writes.
  /// Win32 pipe handles are valid across isolates (same process), so the
  /// handle obtained by ConnectNamedPipe in the server isolate can be used
  /// here in the main isolate.
  void _handleNewConnection(int hPipe) {
    if (hPipe == 0 || hPipe == INVALID_HANDLE_VALUE) {
      logGrpcEvent(
        '[gRPC] Received invalid pipe handle: $hPipe',
        component: 'NamedPipeServer',
        event: 'invalid_pipe_handle',
        context: '_handleNewConnection',
        error: hPipe,
      );
      return;
    }

    final stream = _ServerPipeStream(hPipe);
    _activeStreams.add(stream);

    // Remove from tracking when the stream closes (broken pipe, shutdown, etc.)
    stream._closeFuture.then((_) => _activeStreams.remove(stream));

    try {
      // Create HTTP/2 connection and serve it
      final transportConnection = ServerTransportConnection.viaStreams(stream.incoming, stream.outgoingSink);
      serveConnection(connection: transportConnection);
    } catch (e) {
      // HTTP/2 initialization failure — clean up the pipe handle.
      logGrpcEvent(
        '[gRPC] HTTP/2 initialization failed on'
        ' pipe connection: $e',
        component: 'NamedPipeServer',
        event: 'http2_init_failed',
        context: '_handleNewConnection',
        error: e,
      );
      stream.close(force: true);
    }
  }

  /// Shuts down the server gracefully.
  ///
  /// This method:
  /// 1. Stops accepting new connections (`_isRunning = false`)
  /// 1.5. Starts active gRPC handler/connection shutdown
  ///    ([ConnectionServer.shutdownActiveConnections]), which snapshots
  ///    active connections up-front.
  /// 2. Force-closes active pipe streams to break blocking named-pipe I/O
  ///    and release Win32 handles, then awaits shutdown completion.
  /// 3. Sends cooperative stop signal to the accept loop isolate
  /// 4. Kills the server isolate and waits for confirmed termination
  /// 5. Cleans up the receive port
  Future<void> shutdown() async {
    if (!_isRunning) return;

    // Step 1: Stop handling new connections. _handleIsolateMessage checks
    // this flag before processing _PipeHandle messages, so any straggler
    // messages from the isolate are safely ignored.
    _isRunning = false;

    // All port/isolate cleanup is in a try/finally to guarantee resources
    // are released even if shutdownActiveConnections throws. Leaked
    // ReceivePorts or live isolates keep the Dart VM process alive.
    ReceivePort? exitPort;
    StreamSubscription<dynamic>? exitPortSub;
    try {
      // Step 1.5: Start connection shutdown first so ConnectionServer takes
      // a stable snapshot of active connections before transport teardown.
      final shutdownConnectionsFuture = shutdownActiveConnections();

      // Step 2: Force-close all active pipe streams. On Windows,
      // WriteFile/ReadFile are synchronous FFI calls; under heavy load a
      // stream can block in pipe I/O and starve shutdown progression.
      // Closing handles breaks those blocking paths so the in-flight
      // shutdownActiveConnections future can complete instead of stalling.
      //
      // Using force: true
      // calls DisconnectNamedPipe to immediately terminate connections,
      // discarding any unread data in the pipe buffer. This is necessary
      // during shutdown because FlushFileBuffers would block the event loop
      // and normal close (just CloseHandle) could leave resources dangling.
      for (final stream in _activeStreams.toList()) {
        stream.close(force: true);
      }
      _activeStreams.clear();

      // Step 2.5: Wait for handler/connection shutdown to complete.
      await shutdownConnectionsFuture;

      // Step 3: Send cooperative stop signal to the accept loop.
      //
      // The accept loop uses non-blocking ConnectNamedPipe (PIPE_NOWAIT
      // mode) and polls with 1ms yields. The stop signal sets
      // `shouldStop = true`, causing the loop to exit within 1-2ms.
      // No dummy client connections are needed because the accept loop
      // is never blocked in a synchronous FFI call.
      _stopSendPort?.send(null);
      _stopSendPort = null;

      // Step 4: Wait for cooperative exit, then kill only as last resort.
      //
      // CRITICAL: Do NOT call Isolate.kill() before the cooperative stop
      // signal has been processed. Isolate.kill(immediate) uses a control
      // event which has HIGHER PRIORITY than regular SendPort messages.
      // If kill fires before the stop signal is processed, the accept
      // loop's finally block never runs — leaking the CreateNamedPipe
      // handle. The leaked pipe instance stays in "listening" state in
      // the Windows kernel namespace. When the next server cycle starts,
      // CreateFile may connect to the leaked instance instead of the new
      // server's instance, causing RPCs to hang indefinitely.
      //
      // The accept loop polls ConnectNamedPipe with PIPE_NOWAIT and yields
      // every ~1ms (real: ~15.6ms on Windows due to timer resolution).
      // After the stop signal sets shouldStop=true, the loop exits within
      // one yield cycle and calls Isolate.exit() in its finally block.
      // 500ms is >30x the worst-case single yield, providing ample margin.
      final serverIsolate = _serverIsolate;
      if (serverIsolate != null) {
        exitPort = ReceivePort();
        final exitCompleter = Completer<void>();
        exitPortSub = exitPort.listen((_) {
          if (!exitCompleter.isCompleted) exitCompleter.complete();
        });
        serverIsolate.addOnExitListener(exitPort.sendPort);

        // Wait for the accept loop to process the stop signal and exit
        // cooperatively via Isolate.exit().
        try {
          await exitCompleter.future.timeout(const Duration(milliseconds: 500));
        } on TimeoutException {
          // Cooperative exit failed — force kill as last resort.
          // This may leak a CreateNamedPipe handle, but it's better than
          // hanging indefinitely.
          logGrpcEvent(
            '[gRPC] Accept loop did not exit cooperatively within 500ms. '
            'Forcing kill. Pipe handles may leak.',
            component: 'NamedPipeServer',
            event: 'cooperative_exit_timeout',
            context: 'shutdown',
          );
          serverIsolate.kill(priority: Isolate.immediate);
          try {
            await exitCompleter.future.timeout(const Duration(seconds: 5));
          } on TimeoutException {
            logGrpcEvent(
              '[gRPC] Server isolate did not confirm exit after forced kill.',
              component: 'NamedPipeServer',
              event: 'isolate_exit_timeout',
              context: 'shutdown',
            );
          }
        }
      }
    } finally {
      _serverIsolate = null;
      await exitPortSub?.cancel();
      exitPort?.close();

      // Step 5: Clean up the receive port AFTER killing the isolate.
      await _receivePortSubscription?.cancel();
      _receivePortSubscription = null;
      _receivePort?.close();
      _receivePort = null;

      _pipeName = null;
      _readyCompleter = null;
    }
  }
}

// =============================================================================
// Server Pipe Stream (Main Isolate)
// =============================================================================

/// Bidirectional stream wrapper for a server-side named pipe connection.
///
/// Runs entirely in the **main isolate** — NOT in the server isolate.
/// This is critical because the server isolate's event loop is blocked by
/// [ConnectNamedPipe] waiting for the next client. If reads/writes ran in
/// the server isolate, `await Future.delayed(...)` in the PeekNamedPipe
/// polling loop could never resume, deadlocking all data transfer.
///
/// The main isolate's event loop is never blocked by FFI calls (PeekNamedPipe
/// returns immediately, ReadFile only runs when data is confirmed available),
/// so polling, timeouts, and concurrent connections all work correctly.
class _ServerPipeStream {
  static const Duration _deferredCloseTimeout = Duration(seconds: 5);

  final int _handle;

  final StreamController<List<int>> _incomingController = StreamController<List<int>>();
  final StreamController<List<int>> _outgoingController = StreamController<List<int>>();

  /// Subscription to outgoing data events, stored so it can be explicitly
  /// cancelled during forced [close]. In normal close, the subscription is
  /// allowed to drain naturally so the HTTP/2 transport can finish writing
  /// all frames before the handle is closed.
  StreamSubscription<List<int>>? _outgoingSubscription;

  bool _isClosed = false;

  /// Whether the Win32 handle has been closed. Prevents double-close when
  /// both normal close (via [_onOutgoingDone]) and forced close paths run.
  bool _handleClosed = false;

  /// Completes when this stream is closed (for external tracking).
  final Completer<void> _closeCompleter = Completer<void>();

  /// Safety-net timer for deferred normal-close cleanup.
  ///
  /// Armed when normal close defers handle cleanup to [_onOutgoingDone].
  /// If the outgoing subscription never completes, this timer force-closes
  /// resources so the isolate does not stay alive indefinitely.
  Timer? _deferredCloseTimer;

  /// Future that completes when this stream closes.
  Future<void> get _closeFuture => _closeCompleter.future;

  _ServerPipeStream(this._handle) {
    // Start reading in a microtask to avoid blocking the constructor.
    Future.microtask(_readLoop);

    // Forward outgoing data to the pipe via WriteFile.
    // onDone calls _onOutgoingDone (NOT close) so the outgoing subscription
    // can drain naturally during normal close before the handle is released.
    _outgoingSubscription = _outgoingController.stream.listen(
      _writeData,
      onDone: _onOutgoingDone,
      onError: (error) {
        if (!_isClosed) {
          _incomingController.addError(error);
        }
        close(force: true);
      },
    );
  }

  /// Stream of incoming bytes from the pipe.
  Stream<List<int>> get incoming => _incomingController.stream;

  /// Sink for outgoing bytes to the pipe.
  StreamSink<List<int>> get outgoingSink => _outgoingController.sink;

  /// Continuously reads from the pipe using PeekNamedPipe polling.
  ///
  /// [PeekNamedPipe] returns immediately without blocking, so the main
  /// isolate's event loop remains responsive. [ReadFile] is only called
  /// when data is confirmed available, making it effectively non-blocking.
  ///
  /// The 1ms delay between polls yields to the full event queue (timers,
  /// I/O callbacks, incoming messages), allowing concurrent connections
  /// and HTTP/2 writes to proceed between read checks.
  Future<void> _readLoop() async {
    final buffer = calloc<Uint8>(kNamedPipeBufferSize);
    final bytesRead = calloc<DWORD>();
    final peekAvail = calloc<DWORD>();
    final noDataRetry = NoDataRetryState();

    try {
      while (!_isClosed) {
        // Non-blocking check for available data.
        peekAvail.value = 0;
        final peekResult = PeekNamedPipe(_handle, nullptr, 0, nullptr, peekAvail, nullptr);

        if (peekResult == 0) {
          final error = GetLastError();
          if (error == ERROR_NO_DATA) {
            if (noDataRetry.recordNoData() == NoDataRetryResult.retry) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
              continue;
            }
            logGrpcEvent(
              '[gRPC] Server pipe no-data retries exhausted during peek',
              component: 'NamedPipeServer',
              event: 'pipe_no_data_retries_exhausted',
              context: '_readFromPipe',
              error: error,
            );
          }
          if (error != ERROR_BROKEN_PIPE && error != ERROR_NO_DATA) {
            logGrpcEvent(
              '[gRPC] Server pipe peek error: $error',
              component: 'NamedPipeServer',
              event: 'pipe_peek_error',
              context: '_readFromPipe',
              error: error,
            );
          }
          break;
        }
        noDataRetry.reset();

        if (peekAvail.value == 0) {
          // No data yet — yield to event loop.
          await Future.delayed(const Duration(milliseconds: 1));
          continue;
        }

        // Data confirmed available — ReadFile returns immediately.
        bytesRead.value = 0;
        final success = ReadFile(_handle, buffer, kNamedPipeBufferSize, bytesRead, nullptr);

        if (success == 0) {
          final error = GetLastError();
          if (error == ERROR_NO_DATA) {
            if (noDataRetry.recordNoData() == NoDataRetryResult.retry) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
              continue;
            }
            logGrpcEvent(
              '[gRPC] Server pipe no-data retries exhausted during read',
              component: 'NamedPipeServer',
              event: 'pipe_no_data_retries_exhausted',
              context: '_readFromPipe',
              error: error,
            );
          }
          if (error != ERROR_BROKEN_PIPE && error != ERROR_NO_DATA) {
            logGrpcEvent(
              '[gRPC] Server pipe read error: $error',
              component: 'NamedPipeServer',
              event: 'pipe_read_error',
              context: '_readFromPipe',
              error: error,
            );
          }
          break;
        }
        noDataRetry.reset();

        final count = bytesRead.value;
        if (count > 0) {
          _incomingController.add(copyFromNativeBuffer(buffer, count));
        }
      }
    } finally {
      calloc.free(buffer);
      calloc.free(bytesRead);
      calloc.free(peekAvail);
      // Force-close: the read loop exiting means the pipe is dead (broken pipe,
      // error, or _isClosed). Deferring cleanup to a 5-second timer is dangerous
      // — if the event loop can't process timers (Windows timer starvation),
      // _incomingController never closes, and the entire connection teardown
      // chain stalls indefinitely. Force-close runs synchronously within this
      // event turn, closing controllers and handle immediately.
      close(force: true);
    }
  }

  /// Writes data to the pipe, handling partial writes.
  ///
  /// [WriteFile] can succeed but write fewer bytes than requested when the
  /// pipe's internal buffer is nearly full. A partial write silently drops
  /// the remaining bytes, which corrupts HTTP/2 framing. This method loops
  /// until all bytes are written or an error occurs.
  ///
  /// Guards on [_handleClosed] rather than [_isClosed] because during normal
  /// close (force=false), the outgoing subscription continues draining while
  /// the handle remains open. Using [_isClosed] would silently drop all
  /// remaining HTTP/2 frames — causing data loss in high-throughput streaming.
  void _writeData(List<int> data) {
    if (_handleClosed) return;

    // Guard against zero-length writes: calloc<Uint8>(0) is undefined
    // behavior (may return nullptr on some platforms).
    if (data.isEmpty) return;

    final buffer = calloc<Uint8>(data.length);
    final bytesWritten = calloc<DWORD>();

    try {
      copyToNativeBuffer(buffer, data);

      var offset = 0;
      while (offset < data.length) {
        bytesWritten.value = 0;
        final remaining = data.length - offset;
        final success = WriteFile(_handle, buffer + offset, remaining, bytesWritten, nullptr);

        if (success == 0) {
          final error = GetLastError();
          logGrpcEvent(
            '[gRPC] Server pipe write error: $error',
            component: 'NamedPipeServer',
            event: 'pipe_write_error',
            context: '_writeToPipe',
            error: error,
          );
          close(force: true);
          return;
        }

        if (bytesWritten.value == 0) {
          logGrpcEvent(
            '[gRPC] Server pipe write stalled: 0 bytes written',
            component: 'NamedPipeServer',
            event: 'pipe_write_stall',
            context: '_writeToPipe',
          );
          close(force: true);
          return;
        }

        offset += bytesWritten.value;
      }
    } finally {
      calloc.free(buffer);
      calloc.free(bytesWritten);
    }
  }

  /// Called when the outgoing subscription's stream completes naturally.
  ///
  /// This is the deferred cleanup path for normal (non-forced) close. When
  /// the read loop ends and calls `close()` without force, the outgoing
  /// subscription is left running so the HTTP/2 transport can finish writing
  /// all response frames. Once the transport closes the outgoing stream
  /// (completing the `addStream()`), this callback fires and we can safely
  /// close the Win32 handle — all data has been written to the pipe buffer.
  ///
  /// This separation is critical for high-throughput streaming: without it,
  /// `close()` would cancel the subscription immediately, dropping HTTP/2
  /// frames that haven't been written yet (causing 232/1000 item failures
  /// in tests).
  void _onOutgoingDone() {
    _cancelDeferredCloseTimer();
    _outgoingSubscription = null;
    // Close the incoming controller now that all outgoing frames are written.
    // This is deferred from close(force=false) because closing _incomingController
    // signals the HTTP/2 transport that the byte stream ended. If closed too early
    // (before all response frames are written), the transport interprets it as
    // connection EOF and shuts down the outgoing stream — dropping frames and
    // causing data loss (e.g. 232/1000 items delivered in high-throughput tests).
    if (!_incomingController.isClosed) {
      _incomingController.close();
    }
    _closeHandle(disconnect: false);
    if (!_isClosed) {
      close();
    }
  }

  void _cancelDeferredCloseTimer() {
    _deferredCloseTimer?.cancel();
    _deferredCloseTimer = null;
  }

  /// Cancels the outgoing subscription and chains controller close AFTER
  /// the cancellation completes.
  ///
  /// Closing a [StreamController] while an [addStream] is active throws
  /// [StateError] ("Cannot close while a stream is being added"). The
  /// HTTP/2 transport writes frames via [addStream] on the outgoing
  /// controller. Cancelling the subscription triggers the addStream
  /// cascade that unlocks the controller, but this cascade is async.
  ///
  /// Previously, `cancel()` was fire-and-forget followed by a synchronous
  /// `close()` — which threw, leaving the controller open. The unclosed
  /// controller's internal addStream subscription kept the Dart VM event
  /// loop alive indefinitely, causing 30-minute process hangs on Windows CI.
  void _cancelOutgoingAndCloseController() {
    final sub = _outgoingSubscription;
    _outgoingSubscription = null;
    if (sub != null) {
      unawaited(
        sub
            .cancel()
            .timeout(
              const Duration(seconds: 2),
              onTimeout: () {
                // sub.cancel() hung — the HTTP/2 transport's addStream() is
                // likely stuck on a closed pipe handle. Proceed to close the
                // controller so the VM event loop can drain.
                logGrpcEvent(
                  '[gRPC] Outgoing subscription cancel timed out after 2s; '
                  'forcing controller close',
                  component: 'NamedPipeServer',
                  event: 'cancel_timeout',
                  context: '_ServerPipeStream._cancelOutgoingAndCloseController',
                );
              },
            )
            .whenComplete(() {
              if (!_outgoingController.isClosed) {
                try {
                  _outgoingController.close();
                } catch (_) {}
              }
            }),
      );
    } else if (!_outgoingController.isClosed) {
      try {
        _outgoingController.close();
      } catch (_) {}
    }
  }

  void _armDeferredCloseTimer() {
    _cancelDeferredCloseTimer();
    _deferredCloseTimer = Timer(_deferredCloseTimeout, () {
      // Timer can race with _onOutgoingDone/forced close. Re-check state.
      if (_handleClosed || _outgoingSubscription == null) {
        return;
      }

      logGrpcEvent(
        '[gRPC] Deferred pipe close timed out; forcing cleanup',
        component: 'NamedPipeServer',
        event: 'deferred_close_timeout',
        context: '_ServerPipeStream.close',
      );

      // Chain controller close AFTER subscription cancel completes.
      // See _cancelOutgoingAndCloseController doc for why this is critical.
      _cancelOutgoingAndCloseController();
      if (!_incomingController.isClosed) {
        _incomingController.close();
      }
      _closeHandle(disconnect: false);
    });
  }

  /// Closes the pipe stream and cleans up resources.
  ///
  /// ## Normal close (force=false)
  ///
  /// Used when the read loop exits (broken pipe, peer disconnect, etc.).
  /// Does NOT cancel the outgoing subscription OR close [_incomingController]
  /// when there is an active outgoing subscription. Both are deferred to
  /// [_onOutgoingDone] which fires when the transport finishes writing.
  ///
  /// Closing [_incomingController] prematurely signals the HTTP/2 transport
  /// that the byte stream has ended. The transport interprets this as
  /// connection EOF and shuts down the outgoing stream — dropping response
  /// frames not yet written (e.g. 232/1000 items in high-throughput tests).
  ///
  /// When [_onOutgoingDone] fires, all data has been written to the pipe
  /// buffer and [CloseHandle] preserves it for the client to drain before
  /// seeing `ERROR_BROKEN_PIPE`.
  ///
  /// ## Forced close (force=true)
  ///
  /// Used by [NamedPipeServer.shutdown] for immediate resource cleanup.
  /// Cancels the outgoing subscription (triggering the `addStream()` cascade
  /// that unlocks the controller), calls [DisconnectNamedPipe] to discard
  /// unread data, and [CloseHandle] to release the handle.
  ///
  /// The `addStream()` cascade when cancelling the subscription:
  ///  1. Cancelling `.listen()` → controller detects no listeners
  ///  2. Active `addStream()` cancels its source subscription
  ///  3. `addStream()` Future completes, unlocking the controller
  ///  4. `_outgoingController.close()` succeeds normally
  ///
  /// Without explicit cancellation in the forced path, the subscription keeps
  /// the event loop alive indefinitely — causing the test process to hang for
  /// 20+ minutes until the CI timeout kills it.
  ///
  /// ## FlushFileBuffers
  ///
  /// **Intentionally omitted.** It is a synchronous FFI call that blocks
  /// until the client reads ALL pending data. In our architecture, server and
  /// client pipe I/O share the same Dart event loop (two-isolate model:
  /// accept loop in separate isolate, data I/O in main). FlushFileBuffers
  /// would block the event loop, preventing the client's `PeekNamedPipe`
  /// polling from running — a guaranteed deadlock for any response larger
  /// than the pipe buffer.
  void close({bool force = false}) {
    if (_isClosed) {
      // Already closed normally. If forced close is requested (e.g., by
      // server.shutdown()), upgrade to forced: cancel the outgoing
      // subscription and close the handle immediately. This handles the case
      // where normal close deferred handle cleanup to _onOutgoingDone, but
      // the server is shutting down before the transport finishes writing.
      if (force) {
        _cancelDeferredCloseTimer();
        // Chain controller close AFTER subscription cancel completes.
        // Closing the controller while addStream() is active throws
        // StateError ("Cannot close while a stream is being added").
        // The unawaited cancel() left the addStream() source alive,
        // keeping the VM process alive indefinitely (30-minute CI hang).
        _cancelOutgoingAndCloseController();
        // Close incoming if deferred from normal close (see below).
        if (!_incomingController.isClosed) {
          _incomingController.close();
        }
        _closeHandle(disconnect: true);
      }
      return;
    }
    _isClosed = true;

    if (force) {
      // Close incoming immediately — forced shutdown tears everything down.
      _incomingController.close();
      _cancelDeferredCloseTimer();
      // Chain controller close AFTER subscription cancel completes.
      // See _cancelOutgoingAndCloseController doc for why this is critical.
      _cancelOutgoingAndCloseController();
      _closeHandle(disconnect: true);
    }
    // Normal close: Do NOT cancel the outgoing subscription. The HTTP/2
    // transport may still be writing frames. Handle cleanup is deferred
    // to _onOutgoingDone() which fires when the transport finishes.
    //
    // If there's no outgoing subscription (already drained or never started),
    // close the handle now since _onOutgoingDone won't fire.
    else if (_outgoingSubscription == null) {
      _incomingController.close();
      _closeHandle(disconnect: false);
    } else {
      // Deferred cleanup path: allow the outgoing subscription to drain
      // naturally. Do NOT close _incomingController here — the HTTP/2
      // transport treats incoming stream closure as connection EOF and
      // shuts down the outgoing stream immediately, dropping any response
      // frames not yet written. The incoming controller is closed in
      // _onOutgoingDone() (after all frames are written) or in the
      // deferred close timer callback (safety timeout).
      _armDeferredCloseTimer();
    }
  }

  /// Closes the Win32 pipe handle, with optional [DisconnectNamedPipe].
  ///
  /// Safe to call multiple times — tracks state with [_handleClosed].
  ///
  /// When [disconnect] is `true`, [DisconnectNamedPipe] is called first to
  /// immediately terminate the connection and discard unread buffer data.
  /// When `false`, only [CloseHandle] is called, preserving buffered data
  /// for the client to drain.
  void _closeHandle({required bool disconnect}) {
    if (_handleClosed) return;
    _cancelDeferredCloseTimer();
    _handleClosed = true;

    if (disconnect) {
      DisconnectNamedPipe(_handle);
    }
    CloseHandle(_handle);

    // Signal completion only after the handle is truly closed. This keeps the
    // stream in NamedPipeServer._activeStreams until cleanup is complete, so
    // server.shutdown() can force-close streams that are still draining.
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
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
  final int maxInstances;

  /// Port that the accept loop listens on for a stop signal.
  ///
  /// When the main isolate sends ANY message through this port, the accept
  /// loop sets `shouldStop = true` and breaks at the next polling yield
  /// (within 1ms). The non-blocking ConnectNamedPipe poll never blocks
  /// the isolate's thread, so the stop signal is always processed promptly.
  final SendPort stopPort;

  _AcceptLoopConfig({
    required this.pipeName,
    required this.mainPort,
    required this.maxInstances,
    required this.stopPort,
  });
}

/// Message indicating the server has created the first pipe instance and is
/// ready to accept client connections.
class _ServerReady {}

/// Message carrying a raw Win32 pipe handle for a newly accepted connection.
///
/// The handle was obtained by [ConnectNamedPipe] in the server isolate but
/// is valid in the main isolate because Dart isolates share the same OS
/// process (and therefore the same Win32 handle table).
class _PipeHandle {
  final int handle;

  _PipeHandle(this.handle);
}

/// Message indicating a server error.
class _ServerError {
  final String error;

  _ServerError(this.error);
}

// =============================================================================
// Server Isolate (Accept Loop Only)
// =============================================================================

/// The accept loop running in a separate isolate.
///
/// Creates named pipe instances in a loop, waiting for client connections.
/// Sends [_ServerReady] after the first pipe is created so the main isolate
/// knows clients can connect.
///
/// **This isolate only accepts connections.** All data I/O happens in the
/// main isolate. [ConnectNamedPipe] is called in `PIPE_NOWAIT` mode (set
/// via [SetNamedPipeHandleState]) so it returns immediately. The isolate
/// polls for connections with 1ms yields, keeping the event loop responsive
/// to stop signals and [Isolate.kill] messages. After a client connects,
/// the pipe is switched back to `PIPE_WAIT` mode for synchronous data I/O
/// in the main isolate. By running the accept poll in a separate isolate,
/// the main isolate's event loop remains responsive for concurrent data I/O.
Future<void> _acceptLoop(_AcceptLoopConfig config) async {
  final pipePath = namedPipePath(config.pipeName);
  // Use calloc allocator so the matching calloc.free() is correct.
  final pipePathPtr = pipePath.toNativeUtf16(allocator: calloc);
  var readySent = false;
  var pipeBusyBackoffMs = 1;

  // Listen for stop signal from main isolate. The main isolate sends
  // a message through this port during shutdown, BEFORE killing the
  // isolate. This cooperative signal lets the loop exit at the next
  // yield point (within 1ms of delivery, since the non-blocking
  // ConnectNamedPipe poll yields every millisecond).
  var shouldStop = false;
  final stopPort = ReceivePort();
  config.stopPort.send(stopPort.sendPort);
  stopPort.listen((_) {
    shouldStop = true;
  });

  // Reusable buffer for SetNamedPipeHandleState mode changes.
  final mode = calloc<DWORD>();

  try {
    while (!shouldStop) {
      // Create a new pipe instance for each connection.
      // Created in PIPE_WAIT mode (the default for data I/O).
      final hPipe = CreateNamedPipe(
        pipePathPtr,
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        config.maxInstances,
        kNamedPipeBufferSize,
        kNamedPipeBufferSize,
        0, // Default timeout
        nullptr, // Default security
      );

      if (hPipe == INVALID_HANDLE_VALUE) {
        final error = GetLastError();
        // With a bounded maxInstances configuration (e.g. maxInstances=1),
        // CreateNamedPipe can transiently fail with ERROR_PIPE_BUSY while all
        // current instances are connected. Retry instead of failing the server.
        if (error == ERROR_PIPE_BUSY) {
          await Future<void>.delayed(Duration(milliseconds: pipeBusyBackoffMs));
          if (pipeBusyBackoffMs < 50) {
            pipeBusyBackoffMs = (pipeBusyBackoffMs * 2).clamp(1, 50);
          }
          continue;
        }
        config.mainPort.send(_ServerError('CreateNamedPipe failed: $error'));
        break;
      }

      // Reset backoff once CreateNamedPipe succeeds.
      pipeBusyBackoffMs = 1;

      // Switch to PIPE_NOWAIT for non-blocking ConnectNamedPipe polling.
      //
      // In PIPE_NOWAIT mode, ConnectNamedPipe returns immediately:
      //   - TRUE: a new client connected
      //   - FALSE + ERROR_PIPE_CONNECTED: client was already connected
      //   - FALSE + ERROR_PIPE_LISTENING: no client yet (poll again)
      //
      // This eliminates the blocking FFI problem that caused process hangs:
      // a synchronous ConnectNamedPipe blocks the isolate's OS thread,
      // preventing Isolate.kill() and stop signals from being processed.
      // With PIPE_NOWAIT, the isolate yields every 1ms, allowing the
      // event loop to process kill messages and stop signals promptly.
      mode.value = PIPE_READMODE_BYTE | PIPE_NOWAIT;
      if (SetNamedPipeHandleState(hPipe, mode, nullptr, nullptr) == 0) {
        final error = GetLastError();
        config.mainPort.send(_ServerError('SetNamedPipeHandleState(NOWAIT) failed: $error'));
        CloseHandle(hPipe);
        break;
      }

      // Signal readiness after the first pipe instance is created.
      // At this point the pipe exists in the Windows namespace and
      // clients can successfully call CreateFile to connect.
      if (!readySent) {
        config.mainPort.send(_ServerReady());
        readySent = true;
      }

      // Poll for a client connection (non-blocking).
      // Each iteration: ConnectNamedPipe returns immediately → check
      // result → yield 1ms. The isolate is never blocked in FFI,
      // so stop signals and Isolate.kill fire within 1-2ms.
      var connected = false;
      while (!shouldStop) {
        final result = ConnectNamedPipe(hPipe, nullptr);
        if (result != 0) {
          connected = true;
          break;
        }
        final error = GetLastError();
        if (error == ERROR_PIPE_CONNECTED) {
          connected = true;
          break;
        }
        if (error != ERROR_PIPE_LISTENING) {
          // Unexpected error (e.g. broken pipe, access denied).
          // Close this instance and retry with a new pipe.
          break;
        }
        // No client yet — yield to the event loop. This is the
        // shutdown checkpoint: stop signals and kill messages are
        // processed here, setting shouldStop = true.
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      if (!connected) {
        CloseHandle(hPipe);
        // If stopped, exit the outer loop. Otherwise, retry with
        // a new pipe instance (handles transient errors).
        if (shouldStop) break;
        await Future<void>.delayed(Duration.zero);
        continue;
      }

      // Client connected. Check stop flag before doing any work.
      if (shouldStop) {
        CloseHandle(hPipe);
        break;
      }

      // Switch back to PIPE_WAIT (blocking) mode for data I/O.
      // The main isolate's _ServerPipeStream uses synchronous
      // ReadFile/WriteFile which require PIPE_WAIT to function
      // correctly. PIPE_NOWAIT ReadFile can falsely report
      // completion with zero bytes when no data is available.
      mode.value = PIPE_READMODE_BYTE | PIPE_WAIT;
      if (SetNamedPipeHandleState(hPipe, mode, nullptr, nullptr) == 0) {
        // Can't switch mode — close handle and retry.
        CloseHandle(hPipe);
        continue;
      }

      // Send the raw handle to the main isolate for data I/O.
      // The main isolate will handle all reads/writes using PeekNamedPipe
      // polling, keeping its event loop responsive.
      config.mainPort.send(_PipeHandle(hPipe));

      // Yield to the event loop for a clean shutdown checkpoint.
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    calloc.free(mode);
    stopPort.close();
    calloc.free(pipePathPtr);
    // Explicitly terminate this isolate so the Dart VM process can exit.
    // Without Isolate.exit(), the isolate stays alive if pending Timers
    // or ReceivePorts keep the event loop active. Isolate.exit() is
    // unconditional — it terminates regardless of open resources.
    Isolate.exit();
  }
}
