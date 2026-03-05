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

import 'dart:ffi';
import 'dart:typed_data';

/// Constructs the full Windows named pipe path from a pipe name.
///
/// Converts a simple name like `'my-service'` to the full Win32 path
/// `\\.\pipe\my-service` required by `CreateNamedPipe` and `CreateFile`.
String namedPipePath(String pipeName) => r'\\.\pipe\' + pipeName;

/// Default buffer size for named pipe read/write operations (64 KiB).
///
/// This matches the default Windows named pipe buffer size and provides
/// good throughput for HTTP/2 frames (typically 16 KiB) while keeping
/// memory allocation reasonable for concurrent connections.
const int kNamedPipeBufferSize = 65536;

/// Maximum chunk size for a single [WriteFile] call on named pipes (16 KiB).
///
/// Writes larger than the pipe buffer can block until the peer drains data.
/// By slicing outgoing payloads into bounded chunks and yielding between
/// chunks, both read loops continue progressing and avoid duplex deadlocks.
const int kNamedPipeWriteChunkSize = 16 * 1024;

/// Default maximum retries for transient ERROR_NO_DATA from PeekNamedPipe
/// or ReadFile.
///
/// ERROR_NO_DATA can occur transiently when the pipe is in a transitional
/// state (e.g., peer closing). Bounded retries combined with idle polling
/// backoff allow the connection to recover. Exhaustion is logged and
/// treated as a fatal error.
const int kNamedPipeNoDataMaxRetries = 500;

/// Initial delay for idle named-pipe polling backoff.
const int kNamedPipeIdlePollInitialDelayMs = 1;

/// Maximum delay for idle named-pipe polling backoff.
const int kNamedPipeIdlePollMaxDelayMs = 50;

/// Result of evaluating ERROR_NO_DATA retry.
enum NoDataRetryResult {
  /// Retry: apply idle backoff delay and loop again.
  retry,

  /// Exhausted: bail out and log/error.
  exhausted,
}

/// Shared state for ERROR_NO_DATA retry logic in named pipe read loops.
///
/// ERROR_NO_DATA can occur transiently when the pipe is in a transitional
/// state (e.g., peer closing). Retrying with a bounded count allows the
/// connection to recover.
///
/// **Usage**:
/// - Call [recordNoData] when PeekNamedPipe or ReadFile fails with
///   ERROR_NO_DATA.
/// - If [recordNoData] returns [NoDataRetryResult.retry], await the next
///   [IdlePollBackoff.nextDelay] and continue the loop.
/// - If [recordNoData] returns [NoDataRetryResult.exhausted], log and exit.
/// - Call [reset] on any successful read/peek.
class NoDataRetryState {
  final int maxRetries;
  int _count = 0;

  NoDataRetryState({int? maxRetries}) : maxRetries = maxRetries ?? kNamedPipeNoDataMaxRetries;

  /// Records an ERROR_NO_DATA occurrence. Returns [NoDataRetryResult.retry]
  /// if retries remain, [NoDataRetryResult.exhausted] otherwise.
  NoDataRetryResult recordNoData() {
    _count++;
    if (_count <= maxRetries) {
      return NoDataRetryResult.retry;
    }
    return NoDataRetryResult.exhausted;
  }

  /// Resets the retry count. Call after any successful read or peek.
  void reset() {
    _count = 0;
  }
}

/// Exponential backoff state for named-pipe idle polling.
///
/// Call [nextDelay] for each idle polling iteration (no bytes available or
/// transient ERROR_NO_DATA). Call [reset] once bytes are received to restore
/// low-latency polling for active traffic.
class IdlePollBackoff {
  final int initialDelayMs;
  final int maxDelayMs;
  int _currentDelayMs;

  IdlePollBackoff({int? initialDelayMs, int? maxDelayMs})
    : initialDelayMs = initialDelayMs ?? kNamedPipeIdlePollInitialDelayMs,
      maxDelayMs = maxDelayMs ?? kNamedPipeIdlePollMaxDelayMs,
      _currentDelayMs = initialDelayMs ?? kNamedPipeIdlePollInitialDelayMs {
    if (this.initialDelayMs < 1) {
      throw ArgumentError.value(this.initialDelayMs, 'initialDelayMs', 'must be >= 1');
    }
    if (this.maxDelayMs < this.initialDelayMs) {
      throw ArgumentError.value(this.maxDelayMs, 'maxDelayMs', 'must be >= initialDelayMs');
    }
  }

  Duration nextDelay() {
    final delay = Duration(milliseconds: _currentDelayMs);
    if (_currentDelayMs < maxDelayMs) {
      _currentDelayMs = (_currentDelayMs * 2).clamp(initialDelayMs, maxDelayMs).toInt();
    }
    return delay;
  }

  void reset() {
    _currentDelayMs = initialDelayMs;
  }
}

/// Copies [count] bytes from a native [buffer] into a new [Uint8List].
///
/// Uses `asTypedList` + `sublist` for efficient copying via the underlying
/// memcpy, rather than a manual byte-by-byte loop.
Uint8List copyFromNativeBuffer(Pointer<Uint8> buffer, int count) {
  return buffer.asTypedList(count).sublist(0);
}

/// Copies [data] bytes into a native [buffer].
///
/// The [buffer] must have been allocated with at least `data.length` bytes.
/// Uses `asTypedList` + `setAll` for efficient copying.
void copyToNativeBuffer(Pointer<Uint8> buffer, List<int> data) {
  buffer.asTypedList(data.length).setAll(0, data);
}
