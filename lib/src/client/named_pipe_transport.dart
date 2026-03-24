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
import '../http2/transport.dart';
import 'package:win32/win32.dart';

import '../shared/logging/logging.dart' show logGrpcEvent;
import '../shared/named_pipe_io.dart';
import 'client_transport_connector.dart';

// WaitNamedPipeW is not exported by the win32 package (v5.15),
// so we bind it directly from kernel32.dll.
typedef _WaitNamedPipeWNative = Int32 Function(Pointer<Utf16> lpNamedPipeName, Uint32 nTimeOut);
typedef _WaitNamedPipeWDart = int Function(Pointer<Utf16> lpNamedPipeName, int nTimeOut);

/// Calls the Win32 `WaitNamedPipeW` function.
///
/// Returns non-zero if an instance of the pipe is available before the
/// timeout elapses, or zero on failure (check `GetLastError()`).
_WaitNamedPipeWDart? _waitNamedPipeFn;
int _waitNamedPipe(Pointer<Utf16> pipeName, int timeoutMs) {
  final waitFn = _waitNamedPipeFn ??= DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<_WaitNamedPipeWNative, _WaitNamedPipeWDart>('WaitNamedPipeW');
  return waitFn(pipeName, timeoutMs);
}

/// Maximum number of retry attempts when the pipe is busy.
///
/// Uses exponential backoff starting at 100ms: 100, 200, 400, 800, 1600ms.
/// This is a defense-in-depth measure for production scenarios where all pipe
/// instances are briefly in use (between the server accepting one connection
/// and creating the next pipe instance).
///
/// ERROR_FILE_NOT_FOUND (2) is also retried: with bounded maxInstances (or
/// under heavy load with PIPE_UNLIMITED_INSTANCES), all existing instances
/// can be connected simultaneously. Windows returns FILE_NOT_FOUND rather
/// than PIPE_BUSY when there are zero unconnected instances in the namespace,
/// even though the pipe name is valid and the server is running.
const int _kMaxPipeBusyRetries = 5;

/// Computes the backoff delay for a PIPE_BUSY retry attempt.
///
/// Uses simple exponential backoff: 100ms * 2^attempt.
/// attempt 0 → 100ms, 1 → 200ms, 2 → 400ms, 3 → 800ms, 4 → 1600ms.
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

  /// Maximum time to wait for pipe connection establishment.
  ///
  /// Mirrors [ChannelOptions.connectTimeout] semantics used by socket
  /// connectors. `null` means no additional connector-level timeout.
  final Duration? connectTimeout;

  /// Completer that signals when the active connection is closed.
  ///
  /// This is reset at the start of every [connect] call so each logical
  /// transport generation has its own done Future.
  Completer<void> _doneCompleter = Completer<void>();

  /// The underlying pipe handle (valid only after connect).
  int? _pipeHandle;

  /// Stream wrapper for incoming data.
  _NamedPipeStream? _pipeStream;

  /// Creates a named pipe transport connector.
  ///
  /// [pipeName] is the name of the pipe to connect to.
  /// The full path will be `\\.\pipe\{pipeName}`.
  NamedPipeTransportConnector(this.pipeName, {this.connectTimeout});

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

    // Reconnection path safety: if a previous stream/handle is still tracked
    // in this connector instance, dispose it before creating a new transport.
    // This prevents stale handle retention across reconnect generations.
    _disposeCurrentPipeResources();
    _doneCompleter = Completer<void>();

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
      // Defense-in-depth: In production under load, ERROR_PIPE_BUSY (231) or
      // ERROR_FILE_NOT_FOUND (2) can legitimately occur when all pipe
      // instances are briefly in use — the window between the server
      // accepting one connection and creating the next pipe instance. We
      // retry with exponential backoff for these transient errors.
      final hPipe = await _openPipeWithRetry(pipePathPtr);

      // First shutdown race guard: connect() yields in _openPipeWithRetry (retry
      // delays on PIPE_BUSY). If shutdown() runs during that wait, it completes
      // _doneCompleter and disposes resources. When we resume, we must not
      // assign the newly opened handle to _pipeHandle (would cause double-close
      // in shutdown's _disposeCurrentPipeResources). Instead: close the handle
      // directly and fail deterministically. Per-connect done lifecycle: we
      // reset _doneCompleter at connect start, so completion here means
      // shutdown() ran during our async wait.
      if (_doneCompleter.isCompleted) {
        CloseHandle(hPipe);
        throw NamedPipeException(
          'Connect aborted: connector was shutdown during connect',
          995, // ERROR_OPERATION_ABORTED
        );
      }

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

      // Second shutdown race guard: between the first guard (after
      // _openPipeWithRetry) and this return, connect() performs synchronous
      // work (SetNamedPipeHandleState, handle assignment, stream creation).
      // In single-threaded Dart this block does not yield, but defense-in-depth
      // protects against: (a) future awaits added to this path, (b) cross-
      // isolate usage. If shutdown() ran during this window, _doneCompleter
      // is completed. We must not return a transport — clean any resources
      // we just created (shutdown may have run before we assigned _pipeHandle,
      // so our handle might not have been disposed yet) and fail deterministically.
      // _disposeCurrentPipeResources is idempotent; if shutdown already closed
      // the handle, it is a no-op. Avoids double-close.
      if (_doneCompleter.isCompleted) {
        _disposeCurrentPipeResources();
        throw NamedPipeException(
          'Connect aborted: connector was shutdown during connect',
          995, // ERROR_OPERATION_ABORTED
        );
      }

      // Create HTTP/2 connection over the pipe streams
      return ClientTransportConnection.viaStreams(_pipeStream!.incoming, _pipeStream!.outgoingSink);
    } finally {
      calloc.free(pipePathPtr);
    }
  }

  /// Opens the named pipe, retrying on transient pipe-availability errors.
  ///
  /// Retries on ERROR_PIPE_BUSY (231), ERROR_FILE_NOT_FOUND (2), and
  /// error 0 (WaitNamedPipe-succeeded-but-CreateFile-failed race).
  ///
  /// All three are transient when the server is running: the window between
  /// accepting one connection and creating the next pipe instance can
  /// surface any of these depending on Windows internals and maxInstances.
  Future<int> _openPipeWithRetry(Pointer<Utf16> pipePathPtr) async {
    final startedAt = DateTime.now();

    bool timedOut() {
      final timeout = connectTimeout;
      if (timeout == null) return false;
      return DateTime.now().difference(startedAt) >= timeout;
    }

    Duration? remainingTimeout() {
      final timeout = connectTimeout;
      if (timeout == null) return null;
      return timeout - DateTime.now().difference(startedAt);
    }

    NamedPipeException timeoutException() => NamedPipeException(
      'Failed to connect to named pipe "$pipePath": '
      'timed out after ${connectTimeout!.inMilliseconds}ms',
      1460, // ERROR_TIMEOUT
    );

    for (var attempt = 0; attempt <= _kMaxPipeBusyRetries; attempt++) {
      if (timedOut()) {
        throw timeoutException();
      }

      final remaining = remainingTimeout();
      if (remaining != null) {
        if (remaining <= Duration.zero) {
          throw timeoutException();
        }
        final waitMs = remaining.inMilliseconds.clamp(1, 0x7fffffff).toInt();
        final waitResult = _waitNamedPipe(pipePathPtr, waitMs);
        if (waitResult == 0 && GetLastError() == ERROR_SEM_TIMEOUT) {
          throw timeoutException();
        }
      } else if (attempt > 0) {
        // No explicit connectTimeout — still exercise the OS-native wait so
        // the kernel can wake us as soon as an instance is available rather
        // than relying solely on the dart-level exponential backoff sleep.
        // 100ms is brief enough to avoid starving the single-threaded event
        // loop while still covering the common server accept-loop yield gap.
        _waitNamedPipe(pipePathPtr, 100);
      }

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

      // Retry on transient pipe-availability errors:
      //  - ERROR_PIPE_BUSY (231): all instances are connected.
      //  - ERROR_FILE_NOT_FOUND (2): zero unconnected instances in the
      //    namespace (common with bounded maxInstances; also possible
      //    with PIPE_UNLIMITED_INSTANCES during accept-loop yield).
      //  - Error 0: WaitNamedPipe succeeded but CreateFile failed because
      //    the accept loop hasn't called ConnectNamedPipe yet. Common on
      //    Windows arm64 under x64 emulation (~15.6ms event loop ticks).
      if ((error == ERROR_PIPE_BUSY || error == ERROR_FILE_NOT_FOUND || error == 0) && attempt < _kMaxPipeBusyRetries) {
        final retryDelay = _pipeBusyRetryDelay(attempt);
        final remaining = remainingTimeout();
        if (remaining == null) {
          await Future<void>.delayed(retryDelay);
        } else {
          if (remaining <= Duration.zero) {
            throw timeoutException();
          }
          await Future<void>.delayed(remaining < retryDelay ? remaining : retryDelay);
        }
        continue;
      }

      // All other errors (invalid pipe name, access denied, etc.) fail
      // immediately. Retryable errors also fall through here after all
      // retry attempts are exhausted.
      final retriesExhausted =
          (error == ERROR_PIPE_BUSY || error == ERROR_FILE_NOT_FOUND || error == 0) && attempt >= _kMaxPipeBusyRetries;
      throw NamedPipeException(
        'Failed to connect to named pipe "$pipePath"'
        '${retriesExhausted ? " (all $_kMaxPipeBusyRetries retries exhausted)" : ""}'
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
    _disposeCurrentPipeResources();
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  /// Disposes current stream and OS handle tracked by this connector.
  ///
  /// Safe to call repeatedly — both stream close and handle close paths
  /// are idempotent in this connector.
  void _disposeCurrentPipeResources() {
    _pipeStream?.close(force: true);
    _pipeStream = null;

    final handle = _pipeHandle;
    if (handle != null && handle != INVALID_HANDLE_VALUE) {
      // IMPORTANT: Do NOT call FlushFileBuffers here. It is a synchronous
      // FFI call that blocks until the server reads ALL pending data from
      // the pipe buffer. During shutdown/reconnect cleanup, the peer may not
      // be reading. A blocking flush can freeze the isolate event loop.
      //
      // With synchronous pipe mode, WriteFile already ensures data is in
      // the pipe buffer before returning. CloseHandle releases the handle,
      // and unread data may be discarded as part of teardown.
      CloseHandle(handle);
      _pipeHandle = null;
    }
  }
}

/// Bidirectional stream wrapper for a named pipe.
///
/// Provides [Stream] and [StreamSink] interfaces for HTTP/2 framing.
class _NamedPipeStream {
  static const Duration _deferredCloseTimeout = Duration(seconds: 5);

  final int _handle;
  final Completer<void> _doneCompleter;

  final StreamController<List<int>> _incomingController = StreamController<List<int>>();
  final StreamController<List<int>> _outgoingController = StreamController<List<int>>();

  /// Subscription to outgoing data events, stored so it can be explicitly
  /// cancelled during [close]. Without explicit cancellation, a dangling
  /// subscription keeps the event loop alive when [_outgoingController.close]
  /// throws due to an active `addStream()` from the HTTP/2 transport.
  StreamSubscription<List<int>>? _outgoingSubscription;

  Timer? _deferredCloseTimer;
  bool _isClosed = false;
  bool _writesClosed = false;

  /// Write queue for non-blocking outgoing data.
  ///
  /// Data is enqueued by the synchronous listener callback and drained
  /// asynchronously by [_drainWriteQueue], which yields to the event loop
  /// between chunks. This prevents a deadlock where a blocking [WriteFile]
  /// on a full pipe buffer starves the read loop (which needs the event
  /// loop to process its PeekNamedPipe polling).
  final List<List<int>> _writeQueue = [];
  bool _draining = false;
  bool _outgoingStreamDone = false;

  _NamedPipeStream(this._handle, this._doneCompleter) {
    // Start reading in a microtask to avoid blocking the constructor
    Future.microtask(_readLoop);

    // Forward outgoing data to the pipe
    _outgoingSubscription = _outgoingController.stream.listen(
      _writeData,
      onDone: _onOutgoingDone,
      onError: (error) {
        if (!_isClosed && !_incomingController.isClosed) {
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
    final noDataRetry = NoDataRetryState();
    final idleBackoff = IdlePollBackoff();

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
          if (error == ERROR_NO_DATA) {
            if (noDataRetry.recordNoData() == NoDataRetryResult.retry) {
              await Future<void>.delayed(idleBackoff.nextDelay());
              continue;
            }
            if (!_incomingController.isClosed) {
              _incomingController.addError(
                NamedPipeException('Peek no-data retries exhausted: Win32 error $error', error),
              );
            }
          }
          if (error != ERROR_BROKEN_PIPE && error != ERROR_NO_DATA && !_incomingController.isClosed) {
            _incomingController.addError(NamedPipeException('Peek failed: Win32 error $error', error));
          }
          break;
        }
        noDataRetry.reset();

        if (peekAvail.value == 0) {
          // No data available yet. Yield to the event loop so HTTP/2
          // writes and other async work can proceed. Uses exponential
          // backoff (1ms → 2ms → ... → 50ms cap) to reduce CPU wakeups
          // on idle connections while still reacting quickly when data
          // starts flowing.
          await Future.delayed(idleBackoff.nextDelay());
          continue;
        }
        // Data available — reset backoff to minimum for responsive reads.
        idleBackoff.reset();

        // Data confirmed available — ReadFile will return immediately.
        bytesRead.value = 0;
        final success = ReadFile(_handle, buffer, kNamedPipeBufferSize, bytesRead, nullptr);

        if (success == 0) {
          final error = GetLastError();
          if (error == ERROR_NO_DATA) {
            if (noDataRetry.recordNoData() == NoDataRetryResult.retry) {
              await Future<void>.delayed(idleBackoff.nextDelay());
              continue;
            }
          } else if (error == ERROR_BROKEN_PIPE) {
            break;
          }
          if (!_incomingController.isClosed) {
            _incomingController.addError(NamedPipeException('Read failed: Win32 error $error', error));
          }
          break;
        }
        noDataRetry.reset();
        idleBackoff.reset();

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
      // Force-close: the read loop exiting means the pipe is dead (broken pipe,
      // error, or _isClosed). Deferring cleanup to a 5-second timer is dangerous
      // — if the event loop can't process timers (Windows timer starvation),
      // _incomingController never closes, _doneCompleter never completes, and
      // the entire RPC settlement chain stalls indefinitely. Force-close runs
      // synchronously within this event turn, completing _doneCompleter and
      // triggering error propagation through microtasks (timer-independent).
      close(force: true);
    }
  }

  /// Writes data to the pipe, handling partial writes.
  ///
  /// Enqueues [data] for asynchronous writing to the pipe.
  ///
  /// Data is written by [_drainWriteQueue] which yields to the event loop
  /// between chunks. This prevents a deadlock where a blocking [WriteFile]
  /// on a full pipe buffer starves the read loop running on the same
  /// isolate.
  void _writeData(List<int> data) {
    if (_writesClosed) return;
    if (data.isEmpty) return;
    _enqueueWriteChunks(data);
    if (!_draining) {
      _draining = true;
      Future.microtask(_drainWriteQueue);
    }
  }

  /// Enqueues [data] as bounded write chunks.
  ///
  /// A single large [WriteFile] request (for example, 100KB) can block the
  /// isolate thread until the peer reads enough bytes. Splitting payloads
  /// into bounded chunks allows [_drainWriteQueue] to yield between chunks,
  /// so read polling can continue making progress in both directions.
  void _enqueueWriteChunks(List<int> data) {
    if (data.length <= kNamedPipeWriteChunkSize) {
      _writeQueue.add(data);
      return;
    }

    var offset = 0;
    while (offset < data.length) {
      final end = (offset + kNamedPipeWriteChunkSize < data.length) ? offset + kNamedPipeWriteChunkSize : data.length;
      _writeQueue.add(data.sublist(offset, end));
      offset = end;
    }
  }

  /// Asynchronously drains [_writeQueue], yielding to the event loop
  /// between writes so the read loop can progress.
  ///
  /// Coalesces multiple small queue entries into a single [WriteFile] call
  /// (up to [kNamedPipeWriteChunkSize] bytes per batch). Without batching,
  /// each entry triggers a separate WriteFile + event-loop yield, which
  /// lets producers (HTTP/2 stream handlers) add entries faster than the
  /// drain loop can remove them — unbounded queue growth under concurrency.
  Future<void> _drainWriteQueue() async {
    try {
      while (_writeQueue.isNotEmpty) {
        if (_writesClosed) break;

        final batch = _coalesceWriteQueue();
        if (!await _writeChunk(batch)) break;

        // Yield to the event loop so the read loop (and other async
        // work) can run between write operations. Duration.zero timers
        // use the Dart VM's internal zero-timer fast path (not the OS
        // timer queue), so this does not incur the 15.6 ms Windows
        // timer resolution floor.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _draining = false;
      if (_writeQueue.isNotEmpty && !_writesClosed) {
        _draining = true;
        Future.microtask(_drainWriteQueue);
      } else {
        _finalizeCloseIfReady();
      }
    }
  }

  /// Removes entries from [_writeQueue] and coalesces them into a single
  /// buffer up to [kNamedPipeWriteChunkSize] bytes. If the first entry
  /// alone exceeds the limit, it is returned as-is (already bounded by
  /// [_enqueueWriteChunks]).
  List<int> _coalesceWriteQueue() {
    final first = _writeQueue.removeAt(0);
    if (_writeQueue.isEmpty || first.length >= kNamedPipeWriteChunkSize) {
      return first;
    }

    var totalLength = first.length;
    final parts = <List<int>>[first];
    while (_writeQueue.isNotEmpty && totalLength + _writeQueue.first.length <= kNamedPipeWriteChunkSize) {
      final next = _writeQueue.removeAt(0);
      parts.add(next);
      totalLength += next.length;
    }

    if (parts.length == 1) return first;

    final merged = List<int>.filled(totalLength, 0);
    var offset = 0;
    for (final part in parts) {
      merged.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return merged;
  }

  /// Writes a single chunk to the pipe. Returns `false` on error.
  ///
  /// The client pipe handle is in PIPE_WAIT mode. In this mode, WriteFile
  /// blocks until all bytes are written. The 32 KiB chunk limit (enforced
  /// by [_enqueueWriteChunks]) keeps each blocking window short: WriteFile
  /// only blocks when the 64 KiB buffer is >50% full, giving the server's
  /// read loop time to drain between chunks.
  ///
  /// The zero-byte retry path is defense-in-depth for edge cases where
  /// WriteFile succeeds but writes zero bytes (e.g., handle invalidation
  /// during shutdown). In normal PIPE_WAIT operation this path is not
  /// expected to execute.
  Future<bool> _writeChunk(List<int> data) async {
    if (data.isEmpty) return true;

    final buffer = calloc<Uint8>(data.length);
    final bytesWritten = calloc<DWORD>();

    try {
      copyToNativeBuffer(buffer, data);

      var offset = 0;
      final backoff = IdlePollBackoff();
      var zeroByteRetries = 0;
      const maxZeroByteRetries = 1000;
      while (offset < data.length) {
        if (_writesClosed) return false;

        bytesWritten.value = 0;
        final remaining = data.length - offset;
        final success = WriteFile(_handle, buffer + offset, remaining, bytesWritten, nullptr);

        if (success == 0) {
          final error = GetLastError();
          if (!_incomingController.isClosed) {
            _incomingController.addError(NamedPipeException('Write failed: Win32 error $error', error));
          }
          close(force: true);
          return false;
        }

        if (bytesWritten.value == 0) {
          zeroByteRetries++;
          if (zeroByteRetries >= maxZeroByteRetries) {
            if (!_incomingController.isClosed) {
              _incomingController.addError(
                NamedPipeException(
                  'Write stalled: $maxZeroByteRetries '
                  'consecutive zero-byte writes',
                  0,
                ),
              );
            }
            close(force: true);
            return false;
          }
          await Future<void>.delayed(backoff.nextDelay());
          continue;
        }

        zeroByteRetries = 0;
        backoff.reset();
        offset += bytesWritten.value;
      }
      return true;
    } finally {
      calloc.free(buffer);
      calloc.free(bytesWritten);
    }
  }

  /// Called when outgoing stream finishes naturally.
  void _onOutgoingDone() {
    _cancelDeferredCloseTimer();
    _outgoingSubscription = null;
    _outgoingStreamDone = true;
    _finalizeCloseIfReady();
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
  /// `close()` via `_finalizeClose()` — which threw, leaving the controller
  /// open. The unclosed controller's internal addStream subscription kept the
  /// Dart VM event loop alive indefinitely, causing 30-minute process hangs
  /// on Windows CI.
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
                  component: 'NamedPipeTransport',
                  event: 'cancel_timeout',
                  context: 'NamedPipeTransportConnector._cancelOutgoingAndCloseController',
                );
              },
            )
            .whenComplete(() {
              if (!_outgoingController.isClosed) {
                try {
                  _outgoingController.close();
                } catch (error, _) {
                  logGrpcEvent(
                    '[gRPC] Failed to close outgoing named-pipe controller: $error',
                    component: 'NamedPipeTransport',
                    event: 'close_outgoing_controller_failed',
                    context: '_cancelOutgoingAndCloseController.whenComplete',
                    error: error,
                  );
                }
              }
            }),
      );
    } else if (!_outgoingController.isClosed) {
      try {
        _outgoingController.close();
      } catch (error, _) {
        logGrpcEvent(
          '[gRPC] Failed to close outgoing named-pipe controller: $error',
          component: 'NamedPipeTransport',
          event: 'close_outgoing_controller_failed',
          context: '_cancelOutgoingAndCloseController',
          error: error,
        );
      }
    }
  }

  void _armDeferredCloseTimer() {
    _cancelDeferredCloseTimer();
    _deferredCloseTimer = Timer(_deferredCloseTimeout, () {
      if (_outgoingSubscription == null) {
        return;
      }
      // Chain controller close AFTER subscription cancel completes.
      // See _cancelOutgoingAndCloseController doc for why this is critical.
      _cancelOutgoingAndCloseController();
      if (!_incomingController.isClosed) {
        _incomingController.close();
      }
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    });
  }

  void _finalizeCloseIfReady({bool allowWithoutOutgoingDone = false}) {
    if (_writesClosed || _draining || _writeQueue.isNotEmpty) {
      return;
    }
    if (!_outgoingStreamDone && !allowWithoutOutgoingDone) {
      return;
    }
    _finalizeClose();
  }

  void _finalizeClose() {
    if (_writesClosed) {
      return;
    }
    _writesClosed = true;
    _writeQueue.clear();
    if (!_incomingController.isClosed) {
      _incomingController.close();
    }

    try {
      _outgoingController.close();
    } catch (e) {
      logGrpcEvent(
        '[gRPC] named pipe close error: $e',
        component: 'NamedPipeTransport',
        event: 'close_error',
        context: '_finalizeClose',
        error: e,
      );
    }

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  /// Closes the pipe streams.
  ///
  /// Normal close keeps the outgoing subscription alive so HTTP/2 can finish
  /// writing any queued frames. Forced close tears down immediately.
  ///
  /// Note: This does NOT close the underlying Win32 handle. The handle is
  /// owned by [NamedPipeTransportConnector] and closed by connector-level
  /// teardown (shutdown and reconnect cleanup).
  void close({bool force = false}) {
    if (_isClosed) {
      if (force) {
        _cancelDeferredCloseTimer();
        _writesClosed = true;
        _writeQueue.clear();
        // Chain controller close AFTER subscription cancel completes.
        // Closing the controller while addStream() is active throws
        // StateError ("Cannot close while a stream is being added").
        // The unawaited cancel() left the addStream() source alive,
        // keeping the VM process alive indefinitely (30-minute CI hang).
        _cancelOutgoingAndCloseController();
        if (!_incomingController.isClosed) {
          _incomingController.close();
        }
        if (!_doneCompleter.isCompleted) {
          _doneCompleter.complete();
        }
      }
      return;
    }

    _isClosed = true;
    if (force) {
      _cancelDeferredCloseTimer();
      _writesClosed = true;
      _writeQueue.clear();
      // Chain controller close AFTER subscription cancel completes.
      // See _cancelOutgoingAndCloseController doc for why this is critical.
      _cancelOutgoingAndCloseController();
      if (!_incomingController.isClosed) {
        _incomingController.close();
      }
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
      return;
    }

    if (_outgoingSubscription == null) {
      _finalizeCloseIfReady(allowWithoutOutgoingDone: true);
    } else {
      _armDeferredCloseTimer();
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
