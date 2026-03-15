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

import 'dart:io';

/// Default base directory for Unix domain socket files.
///
/// Uses the platform's conventional per-user runtime directory:
/// - Linux: `$XDG_RUNTIME_DIR` (typically `/run/user/<uid>/`) — tmpfs-backed,
///   cleaned automatically on logout. No stale files after reboot.
/// - macOS: `$TMPDIR` (typically `/var/folders/.../.../T/`) — per-user,
///   cleaned periodically by the OS.
/// - Fallback: `/tmp` (POSIX guaranteed).
///
/// Socket files are placed inside a `grpc-local/` subdirectory to avoid
/// polluting the parent directory.
String defaultUdsDirectory() {
  if (Platform.isLinux) {
    final xdgRuntime = Platform.environment['XDG_RUNTIME_DIR'];
    if (xdgRuntime != null && xdgRuntime.isNotEmpty) {
      return '$xdgRuntime/grpc-local';
    }
  }
  if (Platform.isMacOS) {
    final tmpDir = Platform.environment['TMPDIR'];
    if (tmpDir != null && tmpDir.isNotEmpty) {
      final base = tmpDir.endsWith('/') ? tmpDir.substring(0, tmpDir.length - 1) : tmpDir;
      return '$base/grpc-local';
    }
  }
  return '/tmp/grpc-local';
}

/// Returns the UDS socket path for a given service name.
///
/// Example: `udsSocketPath('my-service')` → `/run/user/1000/grpc-local/my-service.sock`
String udsSocketPath(String serviceName) => '${defaultUdsDirectory()}/$serviceName.sock';

/// Validates a service name for use as a local IPC address.
///
/// Service names must:
/// - Be non-empty
/// - Contain only alphanumeric characters, hyphens, underscores, and dots
/// - Be 32 characters or fewer (ensures the full UDS socket path fits
///   within the 104-byte `sun_path` limit on macOS, where `$TMPDIR` can
///   be ~49 characters long)
void validateServiceName(String serviceName) {
  if (serviceName.isEmpty) {
    throw ArgumentError.value(serviceName, 'serviceName', 'must not be empty');
  }
  if (serviceName.length > 32) {
    throw ArgumentError.value(serviceName, 'serviceName', 'must be 32 characters or fewer');
  }
  if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(serviceName)) {
    throw ArgumentError.value(
      serviceName,
      'serviceName',
      'must contain only alphanumeric characters, hyphens, underscores, and dots',
    );
  }
}
