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

/// Default maximum retries for transient ERROR_NO_DATA from PeekNamedPipe
/// or ReadFile.
///
/// ERROR_NO_DATA can occur transiently when the pipe is in a transitional
/// state (e.g., peer closing). Bounded retries with 1ms delay between
/// attempts allow the connection to recover. Exhaustion is logged and
/// treated as a fatal error.
const int kNamedPipeNoDataMaxRetries = 500;

/// Result of evaluating ERROR_NO_DATA retry.
enum NoDataRetryResult {
  /// Retry: sleep 1ms and loop again.
  retry,

  /// Exhausted: bail out and log/error.
  exhausted,
}

/// Shared state for ERROR_NO_DATA retry logic in named pipe read loops.
///
/// ERROR_NO_DATA can occur transiently when the pipe is in a transitional
/// state (e.g., peer closing). Retrying with a bounded count and 1ms delay
/// between attempts allows the connection to recover.
///
/// **Usage**:
/// - Call [recordNoData] when PeekNamedPipe or ReadFile fails with
///   ERROR_NO_DATA.
/// - If [recordNoData] returns [NoDataRetryResult.retry], await a 1ms delay
///   and continue the loop.
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
