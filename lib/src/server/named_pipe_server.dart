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
  int get activePipeStreamCount => _activeStreams.length;

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
    if (!Platform.isWindows) {
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

    // Listen for incoming connections from the isolate
    _receivePortSubscription = _receivePort!.listen(_handleIsolateMessage);

    // Start the accept loop in a separate isolate
    _serverIsolate = await Isolate.spawn(
      _acceptLoop,
      _AcceptLoopConfig(pipeName: pipeName, mainPort: _receivePort!.sendPort, maxInstances: maxInstances),
    );

    // Wait for the isolate to confirm the pipe has been created.
    // This guarantees the pipe exists in the Windows namespace and clients
    // can successfully call CreateFile when serve() returns.
    try {
      await _readyCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw StateError(
          'NamedPipeServer timed out waiting for pipe creation. '
          'The server isolate may have crashed.',
        ),
      );
    } catch (_) {
      // Cleanup on failure: the isolate and receive port would otherwise leak
      // because _isRunning is never set to true, so shutdown() would no-op.
      _serverIsolate?.kill(priority: Isolate.immediate);
      _serverIsolate = null;
      await _receivePortSubscription?.cancel();
      _receivePortSubscription = null;
      _receivePort?.close();
      _receivePort = null;
      _pipeName = null;
      _readyCompleter = null;
      rethrow;
    }

    _isRunning = true;
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
        logGrpcEvent(
          '[gRPC] NamedPipeServer error: ${message.error}',
          component: 'NamedPipeServer',
          event: 'isolate_error',
          context: '_handleIsolateMessage',
          error: message.error,
        );
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
      stream.close(force: true);
    }
  }

  /// Shuts down the server gracefully.
  ///
  /// This method:
  /// 1. Stops accepting new connections (`_isRunning = false`)
  /// 1.5. Cancels all active gRPC handlers and finishes HTTP/2
  ///    connections (via [ConnectionServer.shutdownActiveConnections])
  /// 2. Closes all active pipe streams (breaking their PeekNamedPipe
  ///    read loops and cleaning up Win32 handles)
  /// 3. Opens a dummy client connection to unblock the server
  ///    isolate's blocking ConnectNamedPipe call (Isolate.kill cannot
  ///    interrupt FFI)
  /// 4. Kills the server isolate
  /// 5. Cleans up the receive port
  Future<void> shutdown() async {
    if (!_isRunning) return;

    // Step 1: Stop handling new connections. _handleIsolateMessage checks
    // this flag before processing _PipeHandle messages, so any straggler
    // messages from the isolate are safely ignored.
    _isRunning = false;
    final pipeName = _pipeName;

    // Step 1.5: Cancel all active gRPC handlers and finish HTTP/2
    // connections. Must happen BEFORE closing pipe streams (step 2) so
    // that in-flight RPCs are terminated first, preventing the HTTP/2
    // transport from waiting indefinitely for streams that will never
    // complete.
    //
    // Uses the shared shutdownActiveConnections() from ConnectionServer,
    // which mirrors the Server.shutdown() pattern from server.dart.
    await shutdownActiveConnections();

    // Step 2: Force-close all active pipe streams. Using force: true
    // calls DisconnectNamedPipe to immediately terminate connections,
    // discarding any unread data in the pipe buffer. This is necessary
    // during shutdown because FlushFileBuffers would block the event loop
    // and normal close (just CloseHandle) could leave resources dangling.
    for (final stream in _activeStreams.toList()) {
      stream.close(force: true);
    }
    _activeStreams.clear();

    // Step 3: Queue kill BEFORE the dummy client connection.
    // The accept loop has a yield point (await Future.delayed) after each
    // ConnectNamedPipe. By queuing the kill first, the kill flag is already
    // set when the accept loop reaches the yield point after being unblocked
    // by the dummy client in step 4. This prevents the loop from creating
    // another pipe instance and blocking on ConnectNamedPipe again.
    //
    // Use beforeNextEvent so the accept loop's current event (up to the
    // yield point) completes, and the isolate exits before the next event.
    _serverIsolate?.kill(priority: Isolate.beforeNextEvent);

    // Step 4: Unblock the server isolate's blocking ConnectNamedPipe call.
    // ConnectNamedPipe is a synchronous Win32 call that blocks the isolate's
    // thread — Isolate.kill() cannot interrupt it. Opening a dummy client
    // connection satisfies ConnectNamedPipe, allowing the isolate to reach
    // the yield point where the kill takes effect.
    //
    // IMPORTANT: Do this BEFORE closing the receive port. The dummy
    // connection unblocks the isolate which may try to send a
    // _PipeHandle message — the port must still be open for that send
    // (it will be a no-op because _isRunning is false).
    if (pipeName != null) {
      _connectDummyClient(pipeName);
    }

    _serverIsolate = null;

    // Step 5: Clean up the receive port AFTER killing the isolate.
    await _receivePortSubscription?.cancel();
    _receivePortSubscription = null;
    _receivePort?.close();
    _receivePort = null;

    _pipeName = null;
    _readyCompleter = null;
  }

  /// Opens and immediately closes a dummy client connection to unblock
  /// a blocking ConnectNamedPipe call in the server isolate.
  static void _connectDummyClient(String pipeName) {
    final path = namedPipePath(pipeName);
    // Allocate with calloc so the matching calloc.free() is correct.
    // toNativeUtf16() defaults to malloc — passing calloc explicitly
    // avoids an allocator mismatch.
    final pipePathPtr = path.toNativeUtf16(allocator: calloc);
    try {
      final hPipe = CreateFile(pipePathPtr, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, NULL);
      if (hPipe != INVALID_HANDLE_VALUE) {
        CloseHandle(hPipe);
      } else {
        final error = GetLastError();
        logGrpcEvent(
          '[gRPC] Dummy pipe connect failed during shutdown: Win32 error $error',
          component: 'NamedPipeServer',
          event: 'dummy_connect_failed',
          context: '_connectDummyClient',
          error: error,
        );
      }
    } finally {
      calloc.free(pipePathPtr);
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

    try {
      while (!_isClosed) {
        // Non-blocking check for available data.
        peekAvail.value = 0;
        final peekResult = PeekNamedPipe(_handle, nullptr, 0, nullptr, peekAvail, nullptr);

        if (peekResult == 0) {
          final error = GetLastError();
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

        final count = bytesRead.value;
        if (count > 0) {
          _incomingController.add(copyFromNativeBuffer(buffer, count));
        }
      }
    } finally {
      calloc.free(buffer);
      calloc.free(bytesRead);
      calloc.free(peekAvail);
      close();
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
    _closeHandle(disconnect: false);
    if (!_isClosed) {
      close();
    }
  }

  void _cancelDeferredCloseTimer() {
    _deferredCloseTimer?.cancel();
    _deferredCloseTimer = null;
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

      _outgoingSubscription?.cancel();
      _outgoingSubscription = null;
      try {
        _outgoingController.close();
      } catch (_) {}
      _closeHandle(disconnect: false);
    });
  }

  /// Closes the pipe stream and cleans up resources.
  ///
  /// ## Normal close (force=false)
  ///
  /// Used when the read loop exits (broken pipe, peer disconnect, etc.).
  /// Stops incoming data by closing [_incomingController], but **does NOT
  /// cancel the outgoing subscription**. The HTTP/2 transport may still be
  /// writing response frames via `addStream()` — cancelling the subscription
  /// would drop those frames, causing data loss.
  ///
  /// Instead, handle cleanup is deferred to [_onOutgoingDone], which fires
  /// when the transport finishes writing and the outgoing stream completes.
  /// At that point, all data has been written to the pipe buffer and
  /// [CloseHandle] preserves it for the client to drain before seeing
  /// `ERROR_BROKEN_PIPE`.
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
        _outgoingSubscription?.cancel();
        _outgoingSubscription = null;
        try {
          _outgoingController.close();
        } catch (_) {}
        _closeHandle(disconnect: true);
      }
      return;
    }
    _isClosed = true;

    // Close incoming first — stops the read loop from adding more data.
    _incomingController.close();

    if (force) {
      _cancelDeferredCloseTimer();
      // Forced shutdown: cancel outgoing subscription immediately.
      // This triggers the addStream() cascade (see doc above) that unlocks
      // the controller so close() succeeds.
      _outgoingSubscription?.cancel();
      _outgoingSubscription = null;

      try {
        _outgoingController.close();
      } catch (_) {
        // Defensive: should not happen after subscription cancellation,
        // but must not fail during shutdown.
      }

      _closeHandle(disconnect: true);
    }
    // Normal close: Do NOT cancel the outgoing subscription. The HTTP/2
    // transport may still be writing frames. Handle cleanup is deferred
    // to _onOutgoingDone() which fires when the transport finishes.
    //
    // If there's no outgoing subscription (already drained or never started),
    // close the handle now since _onOutgoingDone won't fire.
    else if (_outgoingSubscription == null) {
      _closeHandle(disconnect: false);
    } else {
      // Deferred cleanup path: allow normal drain, but force-close if it
      // does not complete within the safety window.
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

  _AcceptLoopConfig({required this.pipeName, required this.mainPort, required this.maxInstances});
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
/// main isolate. This is because [ConnectNamedPipe] blocks the isolate's
/// entire thread (it's a synchronous Win32 call), which would prevent any
/// event-loop-based operations (like [PeekNamedPipe] polling or [WriteFile]
/// processing) from running. By isolating the blocking accept call, the
/// main isolate's event loop remains responsive for concurrent data I/O.
Future<void> _acceptLoop(_AcceptLoopConfig config) async {
  final pipePath = namedPipePath(config.pipeName);
  // Use calloc allocator so the matching calloc.free() is correct.
  final pipePathPtr = pipePath.toNativeUtf16(allocator: calloc);
  var readySent = false;
  var pipeBusyBackoffMs = 1;

  try {
    while (true) {
      // Create a new pipe instance for each connection
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

      // Send the raw handle to the main isolate for data I/O.
      // The main isolate will handle all reads/writes using PeekNamedPipe
      // polling, keeping its event loop responsive.
      config.mainPort.send(_PipeHandle(hPipe));

      // Yield to the event loop so Isolate.kill(beforeNextEvent) can take
      // effect. Without this, the loop immediately calls CreateNamedPipe →
      // ConnectNamedPipe with no event-loop checkpoint, making the isolate
      // unkillable — causing the test process to hang for 20+ minutes until
      // the CI timeout kills it.
      //
      // During shutdown, the main isolate sends Isolate.kill() BEFORE the
      // dummy client connection that unblocks ConnectNamedPipe. This ensures
      // the kill flag is queued before we reach this yield point, so the
      // isolate exits cleanly here instead of looping back to block again.
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    calloc.free(pipePathPtr);
  }
}
