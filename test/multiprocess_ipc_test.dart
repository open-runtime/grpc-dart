// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba.,
// Pieces.app. All rights reserved.
//
// UDS-specific and concurrency pressure multi-process integration tests.
// Exercises real transport boundaries with actual OS processes (not isolates).
@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// =============================================================================
// Process Harness (copied from multiprocess_integration_test.dart)
// =============================================================================

/// A spawned server process with lifecycle control.
class ServerProcess {
  final Process _process;
  final String transport;
  final String address;
  final List<String> _stdoutLines = [];
  final StringBuffer _stderrBuf = StringBuffer();

  /// Completers keyed by prefix — fired when a matching line arrives.
  final _prefixWaiters = <String, List<Completer<String>>>{};

  ServerProcess._(this._process, this.transport, this.address);

  int get pid => _process.pid;
  List<String> get stdoutLines => _stdoutLines;

  void _onStdoutLine(String line) {
    _stdoutLines.add(line);
    for (final entry in _prefixWaiters.entries) {
      if (line.startsWith(entry.key)) {
        for (final c in entry.value) {
          if (!c.isCompleted) c.complete(line);
        }
      }
    }
  }

  /// Spawn a server process and wait for it to signal readiness.
  static Future<ServerProcess> start(String transport, {String? socketPath, int? maxMessageSize}) async {
    final args = ['run', 'test/multiprocess/server_main.dart', transport];
    if (transport == 'uds' && socketPath != null) args.add(socketPath);
    if (maxMessageSize != null) args.addAll(['--max-message-size', '$maxMessageSize']);

    final process = await Process.start(Platform.resolvedExecutable, args);

    final readyCompleter = Completer<String>();
    final stderrBuf = StringBuffer();
    ServerProcess? serverRef;
    final earlyLines = <String>[];

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!readyCompleter.isCompleted && line.startsWith('LISTENING:')) {
              readyCompleter.complete(line.substring('LISTENING:'.length));
              return;
            }
            if (serverRef != null) {
              serverRef._onStdoutLine(line);
            } else {
              earlyLines.add(line);
            }
          },
          onDone: () {
            if (!readyCompleter.isCompleted) {
              readyCompleter.completeError(
                StateError(
                  'Server process (pid=${process.pid}) stdout closed without LISTENING marker. Stderr: $stderrBuf',
                ),
              );
            }
          },
        );
    process.stderr.transform(utf8.decoder).listen(stderrBuf.write);

    String address;
    try {
      address = await readyCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          throw TimeoutException(
            'Server process (pid=${process.pid}) did not signal readiness within 60s. Stderr: $stderrBuf',
          );
        },
      );
    } on StateError {
      final exitCode = await process.exitCode;
      throw StateError(
        'Server process (pid=${process.pid}) exited without signaling readiness. '
        'Exit code: $exitCode. Stderr: $stderrBuf',
      );
    }

    final server = ServerProcess._(process, transport, address);
    server._stderrBuf.write(stderrBuf);
    for (final line in earlyLines) {
      server._onStdoutLine(line);
    }
    serverRef = server;
    return server;
  }

  /// Send a command to the server's stdin.
  void sendCommand(String command) {
    _process.stdin.writeln(command);
  }

  /// Wait for a stdout line starting with [prefix] and return the full line.
  Future<String> waitForPrefix(String prefix, {Duration timeout = const Duration(seconds: 10)}) async {
    for (final line in _stdoutLines) {
      if (line.startsWith(prefix)) return line;
    }
    final completer = Completer<String>();
    _prefixWaiters.putIfAbsent(prefix, () => []).add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException(
          'Server (pid=$pid) did not produce line starting with "$prefix" within $timeout. '
          'Stdout so far: $_stdoutLines',
        );
      },
    );
  }

  /// Request graceful shutdown via stdin command.
  Future<int> shutdownGracefully({Duration timeout = const Duration(seconds: 10)}) async {
    _process.stdin.writeln('SHUTDOWN');
    return _process.exitCode.timeout(
      timeout,
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }

  /// Kill the process immediately (simulates crash).
  void kill() {
    _process.kill(ProcessSignal.sigkill);
  }

  /// Wait for the process to exit.
  Future<int> get exitCode => _process.exitCode;
}

/// A spawned client process with result capture.
class ClientProcess {
  final Process _process;
  final List<String> _stdoutLines = [];
  final StringBuffer _stderrBuf = StringBuffer();
  final Completer<void> _exited = Completer<void>();

  /// Completers keyed by marker string — fired when a matching line arrives.
  final _markerWaiters = <String, List<Completer<void>>>{};

  /// Completers keyed by prefix — fired when a matching line arrives.
  final _prefixWaiters = <String, List<Completer<String>>>{};

  ClientProcess._(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            _stdoutLines.add(line);
            for (final entry in _markerWaiters.entries) {
              if (line == entry.key) {
                for (final c in entry.value) {
                  if (!c.isCompleted) c.complete();
                }
              }
            }
            for (final entry in _prefixWaiters.entries) {
              if (line.startsWith(entry.key)) {
                for (final c in entry.value) {
                  if (!c.isCompleted) c.complete(line);
                }
              }
            }
          },
          onDone: () {
            if (!_exited.isCompleted) _exited.complete();
          },
        );
    _process.stderr.transform(utf8.decoder).listen(_stderrBuf.write);
  }

  int get pid => _process.pid;
  List<String> get stdout => _stdoutLines;
  String get stderr => _stderrBuf.toString();

  static Future<ClientProcess> start(
    String transport,
    String address,
    String command, [
    List<String> extraArgs = const [],
  ]) async {
    final args = ['run', 'test/multiprocess/client_main.dart', transport, address, command, ...extraArgs];
    final process = await Process.start(Platform.resolvedExecutable, args);
    return ClientProcess._(process);
  }

  /// Send a command to the client's stdin.
  void sendCommand(String command) {
    _process.stdin.writeln(command);
  }

  void kill() {
    _process.kill(ProcessSignal.sigkill);
  }

  Future<int> get exitCode => _process.exitCode;

  /// Wait for the process to exit and return all stdout lines.
  Future<List<String>> waitForExit({Duration timeout = const Duration(seconds: 60)}) async {
    final code = await exitCode.timeout(
      timeout,
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        throw TimeoutException(
          'Client process (pid=$pid) did not exit within $timeout. '
          'Force-killed. Stdout so far: $_stdoutLines. Stderr: $stderr',
        );
      },
    );
    await _exited.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _stderrBuf.writeln('WARNING: stdout did not close within 5s after process exit');
      },
    );
    if (code != 0) {
      throw StateError('Client process (pid=$pid) exited with code $code. Stderr: $stderr');
    }
    return _stdoutLines;
  }

  /// Wait for a specific exact line in stdout, with timeout.
  Future<void> waitForMarker(String marker, {Duration timeout = const Duration(seconds: 30)}) async {
    if (_stdoutLines.contains(marker)) return;
    final completer = Completer<void>();
    _markerWaiters.putIfAbsent(marker, () => []).add(completer);
    await completer.future.timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException(
          'Client (pid=$pid) did not produce marker "$marker" within $timeout. '
          'Stdout so far: $_stdoutLines',
        );
      },
    );
  }

  /// Wait for a stdout line starting with [prefix] and return the full line.
  Future<String> waitForPrefix(String prefix, {Duration timeout = const Duration(seconds: 30)}) async {
    for (final line in _stdoutLines) {
      if (line.startsWith(prefix)) return line;
    }
    final completer = Completer<String>();
    _prefixWaiters.putIfAbsent(prefix, () => []).add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        throw TimeoutException(
          'Client (pid=$pid) did not produce line starting with "$prefix" within $timeout. '
          'Stdout so far: $_stdoutLines',
        );
      },
    );
  }

  /// Check if a specific exact line appeared in stdout.
  bool hasLine(String line) => _stdoutLines.contains(line);
}

/// Generate a unique UDS socket path for a test.
String _uniqueSocketPath(String testName) {
  final dir = Directory.systemTemp.createTempSync('grpc_ipc_');
  return '${dir.path}/$testName.sock';
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  // ===========================================================================
  // UDS-Specific Tests (skip on Windows)
  // ===========================================================================
  group('UDS-specific', () {
    // =========================================================================
    // B7: Stale socket file cleanup
    // =========================================================================
    test(
      'B7: server cleans up stale socket file from crashed predecessor',
      () async {
        final path = _uniqueSocketPath('b7-stale-socket');
        addTearDown(() {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            // Socket file may already be gone
          }
        });

        // Start server1 and verify it works
        final server1 = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server1.shutdownGracefully();
          } on StateError {
            // Already dead
          }
        });

        final warmup = await ClientProcess.start('uds', path, 'echo', ['1']);
        final warmupLines = await warmup.waitForExit();
        expect(warmupLines, contains('RESULT:1'), reason: 'Server1 should respond to warmup echo');

        // SIGKILL server1 (leaves stale socket file)
        server1.kill();
        await server1.exitCode;

        // Verify stale socket file exists
        expect(File(path).existsSync(), isTrue, reason: 'SIGKILL should leave stale socket file behind');

        // Start server2 on the SAME path — server_main.dart deletes stale files on startup
        final server2 = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server2.shutdownGracefully();
          } on StateError {
            // Already dead
          }
        });

        // Verify server2 works
        final client = await ClientProcess.start('uds', path, 'echo', ['42']);
        final lines = await client.waitForExit();
        expect(lines, contains('RESULT:42'), reason: 'Server2 should handle requests on same path after stale cleanup');

        await server2.shutdownGracefully();
      },
      skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
    );

    // =========================================================================
    // B9: Multiple UDS clients concurrent streaming
    // =========================================================================
    test(
      'B9: multiple UDS clients stream concurrently from same server',
      () async {
        final path = _uniqueSocketPath('b9-concurrent-stream');
        addTearDown(() {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            // Socket file may already be gone
          }
        });

        final server = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server.shutdownGracefully();
          } on StateError {
            // Already dead
          }
        });

        // Start 5 client processes each with server-stream-hold 200
        final clients = <ClientProcess>[];
        for (var i = 0; i < 5; i++) {
          clients.add(await ClientProcess.start('uds', path, 'server-stream-hold', ['200']));
        }
        addTearDown(() {
          for (final c in clients) {
            c.kill();
          }
        });

        // Wait for all 5 to emit STREAMING
        await Future.wait([
          for (final c in clients) c.waitForMarker('STREAMING', timeout: const Duration(seconds: 60)),
        ]);

        // Wait for all 5 to complete with DONE:200
        for (var i = 0; i < 5; i++) {
          final doneLine = await clients[i].waitForPrefix('DONE:', timeout: const Duration(seconds: 60));
          final itemCount = int.parse(doneLine.substring('DONE:'.length));
          expect(itemCount, equals(200), reason: 'UDS client $i should receive all 200 stream items');
        }

        // All clients should exit cleanly
        await Future.wait([
          for (final c in clients)
            c.exitCode.timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                c.kill();
                return -1;
              },
            ),
        ]);

        await server.shutdownGracefully();
      },
      skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
    );

    // =========================================================================
    // B10: UDS socket file removed while server running
    // =========================================================================
    test(
      'B10: deleting UDS socket file prevents new clients but does not crash server',
      () async {
        final path = _uniqueSocketPath('b10-socket-removed');
        addTearDown(() {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            // Socket file may already be gone
          }
        });

        final server = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server.shutdownGracefully();
          } on StateError {
            // Already dead
          }
        });

        // Verify server works with warmup echo
        final warmup = await ClientProcess.start('uds', path, 'echo', ['1']);
        final warmupLines = await warmup.waitForExit();
        expect(warmupLines, contains('RESULT:1'), reason: 'Server should respond to warmup echo');

        // Delete the socket file
        File(path).deleteSync();

        // Start a new client with echo 1 — expect it to FAIL (no socket file to connect to)
        final failClient = await ClientProcess.start('uds', path, 'echo', ['1']);
        // This client should fail — either exit with non-zero code or emit an ERROR line
        final failExitCode = await failClient.exitCode.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            failClient.kill();
            throw TimeoutException('Failed client did not exit within 30s');
          },
        );
        // The client should fail: either non-zero exit or it emitted an ERROR
        final failedWithError = failExitCode != 0 || failClient.stdout.any((line) => line.startsWith('ERROR:'));
        expect(failedWithError, isTrue, reason: 'Client should fail when socket file is missing');

        // Verify server is still alive by querying CONNECTION_COUNT
        server.sendCommand('CONNECTION_COUNT');
        final countLine = await server.waitForPrefix('CONNECTIONS:', timeout: const Duration(seconds: 10));
        // If we got a response, server is alive
        expect(countLine, startsWith('CONNECTIONS:'), reason: 'Server should still be alive after socket deletion');

        await server.shutdownGracefully();
      },
      skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
    );
  });

  // ===========================================================================
  // Concurrency Pressure Tests
  // ===========================================================================
  group('Concurrency pressure', () {
    // =========================================================================
    // D13: 10 clients doing simultaneous echo RPCs
    // =========================================================================
    test('D13: 4 simultaneous echo clients (TCP)', () async {
      final server = await ServerProcess.start('tcp');
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Already dead
        }
      });

      // Start 4 client processes each with echo [0..3].
      // Reduced from 10: CI runners (2-core) can't compile 10 dart run processes in parallel.
      final clients = <ClientProcess>[];
      for (var i = 0; i < 4; i++) {
        clients.add(await ClientProcess.start('tcp', server.address, 'echo', ['$i']));
      }

      // Wait for all to complete with correct results
      final allLines = await Future.wait([
        for (final c in clients) c.waitForExit(timeout: const Duration(seconds: 60)),
      ]);

      for (var i = 0; i < 4; i++) {
        expect(allLines[i], contains('RESULT:$i'), reason: 'TCP client $i should receive echo result $i');
        expect(allLines[i], contains('CONNECTED'), reason: 'TCP client $i should report connection');
      }

      await server.shutdownGracefully();
    });

    test('D13: 4 simultaneous echo clients (UDS)', () async {
      final path = _uniqueSocketPath('d13-uds');
      addTearDown(() {
        try {
          File(path).deleteSync();
        } on FileSystemException {
          // Socket file may already be gone
        }
      });

      final server = await ServerProcess.start('uds', socketPath: path);
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Already dead
        }
      });

      // Start 4 client processes each with echo [0..3]
      final clients = <ClientProcess>[];
      for (var i = 0; i < 4; i++) {
        clients.add(await ClientProcess.start('uds', path, 'echo', ['$i']));
      }

      // Wait for all to complete with correct results
      final allLines = await Future.wait([
        for (final c in clients) c.waitForExit(timeout: const Duration(seconds: 60)),
      ]);

      for (var i = 0; i < 4; i++) {
        expect(allLines[i], contains('RESULT:$i'), reason: 'UDS client $i should receive echo result $i');
        expect(allLines[i], contains('CONNECTED'), reason: 'UDS client $i should report connection');
      }

      await server.shutdownGracefully();
    }, skip: Platform.isWindows ? 'UDS not supported on Windows' : null);

    // =========================================================================
    // D14: Client join/leave during active streams
    // =========================================================================
    test('D14: client join/leave during active bidi streams (TCP)', () async {
      final server = await ServerProcess.start('tcp');
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Already dead
        }
      });

      // Start 3 clients with bidi-hold, wait for all HOLDING
      final bidiClients = <ClientProcess>[];
      for (var i = 0; i < 3; i++) {
        bidiClients.add(await ClientProcess.start('tcp', server.address, 'bidi-hold'));
      }
      addTearDown(() {
        for (final c in bidiClients) {
          c.kill();
        }
      });

      await Future.wait([
        for (final c in bidiClients) c.waitForMarker('HOLDING', timeout: const Duration(seconds: 60)),
      ]);

      // Kill client 0 (simulates crash while other streams active)
      bidiClients[0].kill();
      await bidiClients[0].exitCode;

      // Start 2 new clients with echo 99, verify both get RESULT:99
      final echoClients = <ClientProcess>[];
      for (var i = 0; i < 2; i++) {
        echoClients.add(await ClientProcess.start('tcp', server.address, 'echo', ['99']));
      }
      final echoResults = await Future.wait([
        for (final c in echoClients) c.waitForExit(timeout: const Duration(seconds: 60)),
      ]);
      for (var i = 0; i < 2; i++) {
        expect(echoResults[i], contains('RESULT:99'), reason: 'New echo client $i should get result after peer crash');
      }

      // Verify remaining 2 bidi clients still have their streams (they stay in HOLDING)
      expect(bidiClients[1].hasLine('HOLDING'), isTrue, reason: 'Bidi client 1 should still be holding');
      expect(bidiClients[2].hasLine('HOLDING'), isTrue, reason: 'Bidi client 2 should still be holding');

      // Clean up: close remaining bidi clients gracefully
      for (var i = 1; i < 3; i++) {
        bidiClients[i].sendCommand('CLOSE');
      }
      for (var i = 1; i < 3; i++) {
        await bidiClients[i].exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            bidiClients[i].kill();
            return -1;
          },
        );
      }

      await server.shutdownGracefully();
    });

    // =========================================================================
    // D15: Large payloads from multiple clients
    // =========================================================================
    test('D15: concurrent 512KB payloads from 3 clients (TCP)', () async {
      final server = await ServerProcess.start('tcp');
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Already dead
        }
      });

      // Start 3 clients each with echo-bytes 524288 (512KB)
      final clients = <ClientProcess>[];
      for (var i = 0; i < 3; i++) {
        clients.add(await ClientProcess.start('tcp', server.address, 'echo-bytes', ['524288']));
      }

      // Wait for all 3 to complete with RESULT:524288
      final allLines = await Future.wait([
        for (final c in clients) c.waitForExit(timeout: const Duration(seconds: 60)),
      ]);

      for (var i = 0; i < 3; i++) {
        expect(
          allLines[i],
          contains('RESULT:524288'),
          reason: 'TCP client $i should echo 512KB payload without corruption',
        );
      }

      await server.shutdownGracefully();
    });

    test(
      'D15: concurrent 512KB payloads from 3 clients (UDS)',
      () async {
        final path = _uniqueSocketPath('d15-uds');
        addTearDown(() {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            // Socket file may already be gone
          }
        });

        final server = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server.shutdownGracefully();
          } on StateError {
            // Already dead
          }
        });

        // Start 3 clients each with echo-bytes 524288 (512KB)
        final clients = <ClientProcess>[];
        for (var i = 0; i < 3; i++) {
          clients.add(await ClientProcess.start('uds', path, 'echo-bytes', ['524288']));
        }

        // Wait for all 3 to complete with RESULT:524288
        final allLines = await Future.wait([
          for (final c in clients) c.waitForExit(timeout: const Duration(seconds: 60)),
        ]);

        for (var i = 0; i < 3; i++) {
          expect(
            allLines[i],
            contains('RESULT:524288'),
            reason: 'UDS client $i should echo 512KB payload without corruption',
          );
        }

        await server.shutdownGracefully();
      },
      skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
    );
  });
}
