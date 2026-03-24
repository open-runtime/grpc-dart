// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba.,
// Pieces.app All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0
//
// -----------------------------------------------------------------------------
// SPIKE / DESIGN ANCHOR — not production code
//
// Goal: replace synchronous ReadFile/WriteFile on named-pipe handles (see
// lib/src/client/named_pipe_transport.dart and lib/src/server/named_pipe_server.dart)
// with overlapped I/O so the Dart isolate never blocks indefinitely inside a
// single Win32 syscall. Completion can be driven by GetOverlappedResult,
// CancelIoEx, or I/O completion ports depending on architecture choice.
//
// References (read before implementing):
// - MSDN: Synchronous vs overlapped I/O, CancelIoEx, named pipes
// - package:win32 — kernel32 CancelIoEx, OVERLAPPED, CreateEvent, ReadFile/WriteFile
//
// Next steps (tracked in GitHub issues on open-runtime/grpc-dart):
// 1) Prototype overlapped ReadFile/WriteFile on a test pipe (this directory).
// 2) Integrate behind the existing _NamedPipeStream / _ServerPipeStream API or
//    replace chunk+yield with completion-based scheduling.
// 3) Fallback only if needed: worker isolate pumping bytes (see issue).
//
// Run on Windows only:
//   dart run tool/overlapped_named_pipe_spike.dart
// -----------------------------------------------------------------------------

import 'dart:io' show Platform, stdout;

void main() {
  if (!Platform.isWindows) {
    stdout.writeln('Skipped: overlapped named-pipe spike is Windows-only.');
    return;
  }
  stdout.writeln(
    'Overlapped named-pipe transport: spike placeholder. '
    'See comments in tool/overlapped_named_pipe_spike.dart and repo issues.',
  );
  // Future: bind OVERLAPPED + CreateEvent + ReadFile/WriteFile with
  // FILE_FLAG_OVERLAPPED on the pipe handle, then loop GetOverlappedResult /
  // WaitForSingleObject in a way that integrates with Dart async (Completer).
}
