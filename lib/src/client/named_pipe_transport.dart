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

import 'package:ffi/ffi.dart';
import 'package:http2/transport.dart';
import 'package:win32/win32.dart';

import '../shared/named_pipe_io.dart';
import 'client_transport_connector.dart';

/// Maximum number of retry attempts when the pipe is busy.
///
/// Uses exponential backoff starting at 100ms: 100ms, 200ms, 400ms.
/// This is a defense-in-depth measure for production scenarios where all pipe
/// instances are briefly in use (between the server accepting one connection
/// and creating the next pipe instance). The server's serve() method
/// guarantees the pipe exists, so ERROR_FILE_NOT_FOUND is NOT retried.
const int _kMaxPipeBusyRetries = 3;

/// Computes the backoff delay for a PIPE_BUSY retry attempt.
///
/// Uses simple exponential backoff: 100ms * 2^attempt.
/// attempt 0 → 100ms, attempt 1 → 200ms, attempt 2 → 400ms.
Duration _pipeBusyRetryDelay(int attempt) => Duration(milliseconds: 100 * (1 << attempt));

/// A [ClientTransportConnector] implementation for Windows named pipes.
///
/// This allows gRPC communication over Windows named pipes, which are the
/// Windows equivalent of Unix domain sockets. Named pipes provide secure,
/// local-only IPC without network exposure.
///
/// ## Usage
///
/// ```dart
/// final channel = NamedPipeClientChannel('my-service-12345');
/// final stub = MyServiceClient(channel);
/// final response = await stub.myMethod(request);
/// await channel.shutdown();
/// ```
///
/// ## Security
///
/// Named pipe connections are local-only and cannot be accessed remotely.
/// The server uses PIPE_REJECT_REMOTE_CLIENTS to prevent SMB tunneling.
class NamedPipeTransportConnector implements ClientTransportConnector {
  /// The name of the pipe (without the `\\.\pipe\` prefix).
  final String pipeName;

  /// Completer that signals when the connection is closed.
  final Completer<void> _doneCompleter = Completer<void>();

  /// The underlying pipe handle (valid only after connect).
  int? _pipeHandle;

  /// Stream wrapper for incoming data.
  _NamedPipeStream? _pipeStream;

  /// Creates a named pipe transport connector.
  ///
  /// [pipeName] is the name of the pipe to connect to.
  /// The full path will be `\\.\pipe\{pipeName}`.
  NamedPipeTransportConnector(this.pipeName);

  /// The full Windows path for the named pipe.
  String get pipePath => namedPipePath(pipeName);

  @override
  String get authority => 'localhost';

  @override
  Future<ClientTransportConnection> connect() async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Named pipes are only supported on Windows. '
        'Use Unix domain sockets on macOS/Linux.',
      );
    }

    // Use calloc allocator so the matching calloc.free() is correct.
    // toNativeUtf16() defaults to malloc — passing calloc explicitly
    // avoids an allocator mismatch.
    final pipePathPtr = pipePath.toNativeUtf16(allocator: calloc);

    try {
      // Open the named pipe for reading and writing.
      //
      // The server's serve() method guarantees the pipe exists in the Windows
      // namespace before returning, so CreateFile should succeed immediately
      // in the common case.
      //
      // Defense-in-depth: In production under load, ERROR_PIPE_BUSY (231) can
      // legitimately occur when all pipe instances are briefly in use — the
      // window between the server accepting one connection and creating the
      // next pipe instance. We retry with exponential backoff for this
      // specific error only.
      //
      // ERROR_FILE_NOT_FOUND is NOT retried because serve() guarantees the
      // pipe exists. If the pipe doesn't exist, that indicates a real problem
      // (server crashed, wrong pipe name, etc.) and should fail immediately.
      final hPipe = await _openPipeWithRetry(pipePathPtr);

      // Set pipe to byte-read mode for stream-oriented HTTP/2 framing.
      // IMPORTANT: Do not assign _pipeHandle until SetNamedPipeHandleState
      // succeeds — otherwise shutdown() would double-close an already-closed
      // handle if this step fails.
      final mode = calloc<DWORD>();
      mode.value = PIPE_READMODE_BYTE;
      final success = SetNamedPipeHandleState(hPipe, mode, nullptr, nullptr);
      calloc.free(mode);

      if (success == 0) {
        final error = GetLastError();
        CloseHandle(hPipe);
        throw NamedPipeException('Failed to set pipe mode: Win32 error $error', error);
      }

      // Handle is fully initialized — safe to track for shutdown cleanup.
      _pipeHandle = hPipe;

      // Create bidirectional stream wrapper
      _pipeStream = _NamedPipeStream(hPipe, _doneCompleter);

      // Create HTTP/2 connection over the pipe streams
      return ClientTransportConnection.viaStreams(_pipeStream!.incoming, _pipeStream!.outgoingSink);
    } finally {
      calloc.free(pipePathPtr);
    }
  }

  /// Opens the named pipe, retrying only on ERROR_PIPE_BUSY.
  ///
  /// This is a defense-in-depth retry for production scenarios where all
  /// server pipe instances are transiently occupied. The server creates
  /// PIPE_UNLIMITED_INSTANCES, so busy is always a transient condition
  /// that resolves once the server's accept loop creates the next instance.
  ///
  /// All other errors (including ERROR_FILE_NOT_FOUND) fail immediately.
  Future<int> _openPipeWithRetry(Pointer<Utf16> pipePathPtr) async {
    for (var attempt = 0; attempt <= _kMaxPipeBusyRetries; attempt++) {
      final hPipe = CreateFile(
        pipePathPtr,
        GENERIC_READ | GENERIC_WRITE,
        0, // No sharing
        nullptr, // Default security
        OPEN_EXISTING,
        0, // Normal attributes
        NULL, // No template
      );

      if (hPipe != INVALID_HANDLE_VALUE) {
        return hPipe;
      }

      final error = GetLastError();

      // Only retry on ERROR_PIPE_BUSY — all pipe instances are temporarily
      // in use. This is a normal transient condition under load.
      if (error == ERROR_PIPE_BUSY && attempt < _kMaxPipeBusyRetries) {
        await Future<void>.delayed(_pipeBusyRetryDelay(attempt));
        continue;
      }

      // All other errors fail immediately. ERROR_FILE_NOT_FOUND means
      // the pipe doesn't exist (server not running or wrong name).
      // ERROR_PIPE_BUSY after all retries exhausted also fails here.
      throw NamedPipeException(
        'Failed to connect to named pipe "$pipePath"'
        '${error == ERROR_PIPE_BUSY ? " (all $_kMaxPipeBusyRetries retries exhausted)" : ""}'
        ': Win32 error $error',
        error,
      );
    }
    // Required for Dart flow analysis — the loop above always returns or
    // throws, but the analyzer cannot prove this statically.
    throw StateError('Unreachable');
  }

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  void shutdown() {
    _pipeStream?.close();
    final handle = _pipeHandle;
    if (handle != null && handle != INVALID_HANDLE_VALUE) {
      // IMPORTANT: Do NOT call FlushFileBuffers here. It is a synchronous
      // FFI call that blocks until the server reads ALL pending data from
      // the pipe buffer. During shutdown, the server may not be reading
      // (e.g., it's also shutting down). In that case FlushFileBuffers
      // blocks the Dart isolate thread indefinitely — freezing the event
      // loop and preventing process exit.
      //
      // With synchronous pipe mode, WriteFile already ensures data is in
      // the pipe buffer before returning. CloseHandle releases the handle
      // and any unread data is discarded — acceptable during shutdown.
      CloseHandle(handle);
      _pipeHandle = null;
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}

/// Bidirectional stream wrapper for a named pipe.
///
/// Provides [Stream] and [StreamSink] interfaces for HTTP/2 framing.
class _NamedPipeStream {
  final int _handle;
  final Completer<void> _doneCompleter;

  final StreamController<List<int>> _incomingController = StreamController<List<int>>();
  final StreamController<List<int>> _outgoingController = StreamController<List<int>>();

  /// Subscription to outgoing data events, stored so it can be explicitly
  /// cancelled during [close]. Without explicit cancellation, a dangling
  /// subscription keeps the event loop alive when [_outgoingController.close]
  /// throws due to an active `addStream()` from the HTTP/2 transport.
  StreamSubscription<List<int>>? _outgoingSubscription;

  bool _isClosed = false;

  _NamedPipeStream(this._handle, this._doneCompleter) {
    // Start reading in a microtask to avoid blocking the constructor
    Future.microtask(_readLoop);

    // Forward outgoing data to the pipe
    _outgoingSubscription = _outgoingController.stream.listen(
      _writeData,
      onDone: close,
      onError: (error) {
        if (!_isClosed) {
          _incomingController.addError(error);
        }
        close();
      },
    );
  }

  /// Stream of incoming bytes from the pipe.
  Stream<List<int>> get incoming => _incomingController.stream;

  /// Sink for outgoing bytes to the pipe.
  StreamSink<List<int>> get outgoingSink => _outgoingController.sink;

  /// Continuously reads from the pipe and adds to incoming stream.
  ///
  /// Uses [PeekNamedPipe] to poll for data availability before calling
  /// [ReadFile]. This is critical because ReadFile with a synchronous pipe
  /// handle is a **blocking FFI call** that freezes the Dart event loop —
  /// preventing HTTP/2 writes, test timeouts, and all other async work.
  /// By only calling ReadFile when data is confirmed available, the event
  /// loop remains responsive between reads.
  ///
  /// **Error propagation**: When [ReadFile] fails with an unexpected Win32
  /// error (not BROKEN_PIPE / NO_DATA), a [NamedPipeException] is added to
  /// [_incomingController] as a stream error. This error propagates through:
  ///
  ///  1. [_incomingController.stream] (the [incoming] stream)
  ///  2. [ClientTransportConnection.viaStreams] — the HTTP/2 transport layer
  ///  3. The HTTP/2 transport detects the stream error and closes
  ///  4. [NamedPipeTransportConnector.done] completes, triggering connection
  ///     abandonment in [Http2ClientConnection]
  ///  5. Pending gRPC calls are failed with [GrpcError.unavailable], wrapping
  ///     the original [NamedPipeException] message
  ///
  /// This is the correct behavior: transport-level read failures surface as
  /// gRPC UNAVAILABLE errors, which clients can retry via standard gRPC
  /// retry policies.
  Future<void> _readLoop() async {
    final buffer = calloc<Uint8>(kNamedPipeBufferSize);
    final bytesRead = calloc<DWORD>();
    final peekAvail = calloc<DWORD>();

    try {
      while (!_isClosed && !_incomingController.isClosed) {
        // Non-blocking check: is there data available on the pipe?
        //
        // PeekNamedPipe returns immediately without blocking the thread.
        // This is essential because ReadFile with a synchronous pipe handle
        // blocks the entire Dart isolate thread (FFI calls cannot be
        // interrupted), which would prevent:
        //  - HTTP/2 outgoing writes (request/response framing)
        //  - dart:test timeout timers
        //  - Any other scheduled async work
        //
        // Without this check, the first ReadFile call would deadlock: the
        // client blocks waiting for server data, but the server is waiting
        // for the client's HTTP/2 connection preface that can never be sent.
        peekAvail.value = 0;
        final peekResult = PeekNamedPipe(
          _handle,
          nullptr, // Don't read data, just check availability
          0,
          nullptr,
          peekAvail,
          nullptr,
        );

        if (peekResult == 0) {
          // PeekNamedPipe failed — pipe is closed or broken.
          final error = GetLastError();
          if (error != ERROR_BROKEN_PIPE && error != ERROR_NO_DATA) {
            _incomingController.addError(NamedPipeException('Peek failed: Win32 error $error', error));
          }
          break;
        }

        if (peekAvail.value == 0) {
          // No data available yet. Yield to the event loop so HTTP/2
          // writes and other async work can proceed. Use 1ms delay
          // instead of Duration.zero to yield to the full event queue
          // (not just microtasks).
          await Future.delayed(const Duration(milliseconds: 1));
          continue;
        }

        // Data confirmed available — ReadFile will return immediately.
        bytesRead.value = 0;
        final success = ReadFile(_handle, buffer, kNamedPipeBufferSize, bytesRead, nullptr);

        if (success == 0) {
          final error = GetLastError();
          if (error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA) {
            break;
          }
          _incomingController.addError(NamedPipeException('Read failed: Win32 error $error', error));
          break;
        }

        final count = bytesRead.value;
        if (count > 0) {
          final data = copyFromNativeBuffer(buffer, count);
          _incomingController.add(data);
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
  void _writeData(List<int> data) {
    if (_isClosed) return;

    // Guard against zero-length writes: calloc<Uint8>(0) is undefined
    // behavior (may return nullptr on some platforms).
    if (data.isEmpty) return;

    final buffer = calloc<Uint8>(data.length);
    final bytesWritten = calloc<DWORD>();

    try {
      // Copy data to native buffer
      copyToNativeBuffer(buffer, data);

      var offset = 0;
      while (offset < data.length) {
        bytesWritten.value = 0;
        final remaining = data.length - offset;
        final success = WriteFile(_handle, buffer + offset, remaining, bytesWritten, nullptr);

        if (success == 0) {
          final error = GetLastError();
          _incomingController.addError(NamedPipeException('Write failed: Win32 error $error', error));
          close();
          return;
        }

        if (bytesWritten.value == 0) {
          _incomingController.addError(NamedPipeException('Write stalled: 0 bytes written', 0));
          close();
          return;
        }

        offset += bytesWritten.value;
      }
    } finally {
      calloc.free(buffer);
      calloc.free(bytesWritten);
    }
  }

  /// Closes the pipe streams.
  ///
  /// This method is safe to call from any context — including during active
  /// HTTP/2 `addStream()` operations. The HTTP/2 transport pipes frames into
  /// [outgoingSink] via `addStream()`, which locks the [StreamController].
  ///
  /// By cancelling [_outgoingSubscription] first, we trigger the cascade:
  ///  1. The single-subscription controller detects no listeners
  ///  2. The active `addStream()` cancels its source subscription
  ///  3. The `addStream()` Future completes, unlocking the controller
  ///  4. `_outgoingController.close()` succeeds normally
  ///
  /// Without this explicit cancellation, the subscription keeps the event
  /// loop alive indefinitely — causing the test process to hang for 20+
  /// minutes until the CI timeout kills it.
  ///
  /// Note: This does NOT close the underlying Win32 handle. The handle is
  /// owned by [NamedPipeTransportConnector] and closed in its [shutdown()]
  /// method, which closes the Win32 handle via CloseHandle.
  void close() {
    if (_isClosed) return;
    _isClosed = true;

    _incomingController.close();

    // Cancel the outgoing subscription BEFORE closing the controller.
    // This unlocks the controller if addStream() is active (see doc above).
    _outgoingSubscription?.cancel();
    _outgoingSubscription = null;

    // With the subscription cancelled, close() should succeed. Keep the
    // try-catch as defense-in-depth in case of unexpected edge cases.
    try {
      _outgoingController.close();
    } catch (_) {
      // Defensive: should not happen after subscription cancellation,
      // but must not fail during shutdown.
    }

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
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
