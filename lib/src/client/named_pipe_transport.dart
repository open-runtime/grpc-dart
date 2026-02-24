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

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http2/transport.dart';
import 'package:win32/win32.dart';

import 'client_transport_connector.dart';

/// Buffer size for pipe I/O operations.
const int _kBufferSize = 65536;

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
  String get pipePath => r'\\.\pipe\' + pipeName;

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

    final pipePathPtr = pipePath.toNativeUtf16();

    try {
      // Open the named pipe for reading and writing.
      // The server's serve() method guarantees the pipe exists in the Windows
      // namespace before returning, so CreateFile should succeed immediately.
      final hPipe = CreateFile(
        pipePathPtr,
        GENERIC_READ | GENERIC_WRITE,
        0, // No sharing
        nullptr, // Default security
        OPEN_EXISTING,
        0, // Normal attributes
        NULL, // No template
      );

      if (hPipe == INVALID_HANDLE_VALUE) {
        final error = GetLastError();
        throw NamedPipeException('Failed to connect to named pipe "$pipePath": Win32 error $error', error);
      }

      _pipeHandle = hPipe;

      // Set pipe to byte-read mode for stream-oriented HTTP/2 framing
      final mode = calloc<DWORD>();
      mode.value = PIPE_READMODE_BYTE;
      final success = SetNamedPipeHandleState(hPipe, mode, nullptr, nullptr);
      calloc.free(mode);

      if (success == 0) {
        final error = GetLastError();
        CloseHandle(hPipe);
        throw NamedPipeException('Failed to set pipe mode: Win32 error $error', error);
      }

      // Create bidirectional stream wrapper
      _pipeStream = _NamedPipeStream(hPipe, _doneCompleter);

      // Create HTTP/2 connection over the pipe streams
      return ClientTransportConnection.viaStreams(_pipeStream!.incoming, _pipeStream!.outgoingSink);
    } finally {
      calloc.free(pipePathPtr);
    }
  }

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  void shutdown() {
    _pipeStream?.close();
    final handle = _pipeHandle;
    if (handle != null && handle != INVALID_HANDLE_VALUE) {
      FlushFileBuffers(handle);
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

  bool _isClosed = false;

  _NamedPipeStream(this._handle, this._doneCompleter) {
    // Start reading in a microtask to avoid blocking the constructor
    Future.microtask(_readLoop);

    // Forward outgoing data to the pipe
    _outgoingController.stream.listen(
      _writeData,
      onDone: close,
      onError: (error) {
        _incomingController.addError(error);
        close();
      },
    );
  }

  /// Stream of incoming bytes from the pipe.
  Stream<List<int>> get incoming => _incomingController.stream;

  /// Sink for outgoing bytes to the pipe.
  StreamSink<List<int>> get outgoingSink => _outgoingController.sink;

  /// Continuously reads from the pipe and adds to incoming stream.
  Future<void> _readLoop() async {
    final buffer = calloc<Uint8>(_kBufferSize);
    final bytesRead = calloc<DWORD>();

    try {
      while (!_isClosed) {
        bytesRead.value = 0;

        // Read from pipe (blocking call)
        final success = ReadFile(_handle, buffer, _kBufferSize, bytesRead, nullptr);

        if (success == 0) {
          final error = GetLastError();
          if (error == ERROR_BROKEN_PIPE || error == ERROR_NO_DATA) {
            // Pipe closed gracefully
            break;
          }
          _incomingController.addError(NamedPipeException('Read failed: Win32 error $error', error));
          break;
        }

        final count = bytesRead.value;
        if (count == 0) {
          // No data, yield to event loop
          await Future.delayed(Duration.zero);
          continue;
        }

        // Copy bytes and add to stream
        final data = Uint8List(count);
        for (var i = 0; i < count; i++) {
          data[i] = buffer[i];
        }
        _incomingController.add(data);
      }
    } finally {
      calloc.free(buffer);
      calloc.free(bytesRead);
      close();
    }
  }

  /// Writes data to the pipe.
  void _writeData(List<int> data) {
    if (_isClosed) return;

    final buffer = calloc<Uint8>(data.length);
    final bytesWritten = calloc<DWORD>();

    try {
      // Copy data to native buffer
      for (var i = 0; i < data.length; i++) {
        buffer[i] = data[i];
      }

      final success = WriteFile(_handle, buffer, data.length, bytesWritten, nullptr);

      if (success == 0) {
        final error = GetLastError();
        _incomingController.addError(NamedPipeException('Write failed: Win32 error $error', error));
        close();
      }
    } finally {
      calloc.free(buffer);
      calloc.free(bytesWritten);
    }
  }

  /// Closes the pipe streams.
  void close() {
    if (_isClosed) return;
    _isClosed = true;

    _incomingController.close();
    _outgoingController.close();

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
