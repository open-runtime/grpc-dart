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

    // =========================================================================
    // B12: Server survives 5 restart cycles on same UDS path
    // =========================================================================
    test(
      'B12: server survives 5 restart cycles on same UDS path',
      () async {
        final path = _uniqueSocketPath('b12-restart-cycle');
        addTearDown(() {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            // Socket file may already be gone
          }
        });

        for (var cycle = 0; cycle < 5; cycle++) {
          // Each cycle: start server on the same UDS path.
          // On cycles 1-4 the server must delete the stale socket file left by
          // the previous graceful shutdown before it can bind.
          final server = await ServerProcess.start('uds', socketPath: path);
          addTearDown(() async {
            try {
              await server.shutdownGracefully();
            } on StateError {
              // Already dead
            }
          });

          final client = await ClientProcess.start('uds', path, 'echo', ['${cycle * 10}']);
          final lines = await client.waitForExit();
          expect(lines, contains('RESULT:${cycle * 10}'), reason: 'Cycle $cycle: echo should return ${cycle * 10}');

          await server.shutdownGracefully();
        }

        // After all 5 cycles, verify the socket file is cleaned up.
        expect(
          File(path).existsSync(),
          isFalse,
          reason: 'Socket file should be cleaned up after graceful shutdown of final cycle',
        );
      },
      skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
    );

    // =========================================================================
    // B13: Server crash during active client streaming leaves stale socket
    // =========================================================================
    test(
      'B13: server crash during active client streaming leaves stale socket (UDS)',
      () async {
        final path = _uniqueSocketPath('b13-crash-stream');
        addTearDown(() {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            // Socket file may already be gone
          }
        });

        // Phase 1: Start UDS server and a client with a long-lived server stream
        final server1 = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server1.shutdownGracefully();
          } on StateError {
            // Already dead
          }
        });

        final streamClient = await ClientProcess.start('uds', path, 'server-stream-hold', ['10000']);
        addTearDown(() {
          streamClient.kill();
        });

        // Wait for the client to confirm it is actively streaming
        await streamClient.waitForMarker('STREAMING', timeout: const Duration(seconds: 60));

        // Phase 2: SIGKILL the server (hard crash — leaves stale socket file)
        server1.kill();
        await server1.exitCode;

        // Client should detect the broken connection and exit
        final streamExitCode = await streamClient.exitCode.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            streamClient.kill();
            throw TimeoutException(
              'Streaming client (pid=${streamClient.pid}) did not exit within 30s after server crash. '
              'Stdout: ${streamClient.stdout}',
            );
          },
        );
        // Client exits 0 (server-stream-hold catches GrpcError, prints ERROR: then DONE:)
        expect(streamExitCode, equals(0), reason: 'Client should exit cleanly after detecting server crash');
        // Verify the client saw an error (stream interrupted by crash)
        expect(
          streamClient.stdout.any((line) => line.startsWith('ERROR:')),
          isTrue,
          reason: 'Client should report a gRPC error when server crashes mid-stream',
        );

        // Phase 3: Verify stale socket file exists (SIGKILL prevents cleanup)
        expect(File(path).existsSync(), isTrue, reason: 'SIGKILL should leave stale socket file behind');

        // Phase 4: Start a NEW server on the SAME socket path (exercises stale socket cleanup)
        final server2 = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server2.shutdownGracefully();
          } on StateError {
            // Already dead
          }
        });

        // Phase 5: Verify the new server works on the recovered path
        final echoClient = await ClientProcess.start('uds', path, 'echo', ['42']);
        final echoLines = await echoClient.waitForExit(timeout: const Duration(seconds: 30));
        expect(
          echoLines,
          contains('RESULT:42'),
          reason: 'New server should handle RPCs on same path after crash recovery',
        );

        // Phase 6: Graceful shutdown and verify socket cleanup
        final exitCode2 = await server2.shutdownGracefully();
        expect(exitCode2, equals(0), reason: 'Server2 should shut down cleanly');

        expect(File(path).existsSync(), isFalse, reason: 'Graceful shutdown should clean up socket file');
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

    test(
      'D14: client join/leave during active bidi streams (UDS)',
      () async {
        final path = _uniqueSocketPath('d14-uds');
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

        // Start 3 clients with bidi-hold, wait for all HOLDING
        final bidiClients = <ClientProcess>[];
        for (var i = 0; i < 3; i++) {
          bidiClients.add(await ClientProcess.start('uds', path, 'bidi-hold'));
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
          echoClients.add(await ClientProcess.start('uds', path, 'echo', ['99']));
        }
        final echoResults = await Future.wait([
          for (final c in echoClients) c.waitForExit(timeout: const Duration(seconds: 60)),
        ]);
        for (var i = 0; i < 2; i++) {
          expect(
            echoResults[i],
            contains('RESULT:99'),
            reason: 'New echo client $i should get result after peer crash',
          );
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
      },
      skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
    );

    // =========================================================================
    // D17: Multi-client bidi hold then mass disconnect
    // =========================================================================
    test('D17: 4 clients hold bidi streams then all exit cleanly (TCP)', () async {
      final server = await ServerProcess.start('tcp');
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Already dead
        }
      });

      // Start 4 bidi-hold clients
      final bidiClients = <ClientProcess>[];
      for (var i = 0; i < 4; i++) {
        bidiClients.add(await ClientProcess.start('tcp', server.address, 'bidi-hold'));
      }
      addTearDown(() {
        for (final c in bidiClients) {
          c.kill();
        }
      });

      // Wait for all 4 to reach HOLDING state (bidi stream open and alive)
      await Future.wait([
        for (final c in bidiClients) c.waitForMarker('HOLDING', timeout: const Duration(seconds: 60)),
      ]);

      // Verify server has 4 active connections
      server.sendCommand('CONNECTION_COUNT');
      final countLine4 = await server.waitForPrefix('CONNECTIONS:', timeout: const Duration(seconds: 10));
      final count4 = int.parse(countLine4.substring('CONNECTIONS:'.length));
      expect(count4, equals(4), reason: 'Server should have 4 active connections from bidi-hold clients');

      // Kill all 4 clients simultaneously (simulates mass disconnect)
      for (final c in bidiClients) {
        c.kill();
      }
      await Future.wait([for (final c in bidiClients) c.exitCode]);

      // Poll server CONNECTION_COUNT until it drops to 0 (all cleaned up),
      // using deadline-bounded polling of concrete state.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      var lastCount = count4;
      while (DateTime.now().isBefore(deadline)) {
        final lineCountBefore = server.stdoutLines.length;
        server.sendCommand('CONNECTION_COUNT');
        // Wait for a new CONNECTIONS: line to appear after the command
        for (var attempts = 0; attempts < 200; attempts++) {
          await Future<void>.delayed(Duration.zero);
          if (server.stdoutLines.length > lineCountBefore) {
            final latest = server.stdoutLines.last;
            if (latest.startsWith('CONNECTIONS:')) {
              lastCount = int.parse(latest.substring('CONNECTIONS:'.length));
              break;
            }
          }
        }
        if (lastCount == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(lastCount, equals(0), reason: 'Server should have 0 connections after all bidi clients were killed');

      // Verify server is still alive by performing a fresh echo RPC
      final echoClient = await ClientProcess.start('tcp', server.address, 'echo', ['77']);
      final echoLines = await echoClient.waitForExit(timeout: const Duration(seconds: 60));
      expect(echoLines, contains('RESULT:77'), reason: 'Server should still accept new RPCs after mass disconnect');

      // Verify connection count is at most 1 (echo client may or may not have been cleaned up yet)
      final lineCountBeforeFinal = server.stdoutLines.length;
      server.sendCommand('CONNECTION_COUNT');
      final deadlineFinal = DateTime.now().add(const Duration(seconds: 10));
      var finalCount = -1;
      while (DateTime.now().isBefore(deadlineFinal)) {
        await Future<void>.delayed(Duration.zero);
        for (var i = lineCountBeforeFinal; i < server.stdoutLines.length; i++) {
          if (server.stdoutLines[i].startsWith('CONNECTIONS:')) {
            finalCount = int.parse(server.stdoutLines[i].substring('CONNECTIONS:'.length));
            break;
          }
        }
        if (finalCount >= 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // The echo client already terminated, so connections should be 0 or at most 1
      expect(finalCount, lessThanOrEqualTo(1), reason: 'Connection count should be at most 1 after echo client exited');

      await server.shutdownGracefully();
    });

    test(
      'D17: 4 clients hold bidi streams then all exit cleanly (UDS)',
      () async {
        final path = _uniqueSocketPath('d17-uds');
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

        // Start 4 bidi-hold clients
        final bidiClients = <ClientProcess>[];
        for (var i = 0; i < 4; i++) {
          bidiClients.add(await ClientProcess.start('uds', path, 'bidi-hold'));
        }
        addTearDown(() {
          for (final c in bidiClients) {
            c.kill();
          }
        });

        // Wait for all 4 to reach HOLDING state (bidi stream open and alive)
        await Future.wait([
          for (final c in bidiClients) c.waitForMarker('HOLDING', timeout: const Duration(seconds: 60)),
        ]);

        // Verify server has 4 active connections
        server.sendCommand('CONNECTION_COUNT');
        final countLine4 = await server.waitForPrefix('CONNECTIONS:', timeout: const Duration(seconds: 10));
        final count4 = int.parse(countLine4.substring('CONNECTIONS:'.length));
        expect(count4, equals(4), reason: 'Server should have 4 active connections from bidi-hold clients');

        // Kill all 4 clients simultaneously (simulates mass disconnect)
        for (final c in bidiClients) {
          c.kill();
        }
        await Future.wait([for (final c in bidiClients) c.exitCode]);

        // Poll server CONNECTION_COUNT until it drops to 0 (all cleaned up),
        // using deadline-bounded polling of concrete state.
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        var lastCount = count4;
        while (DateTime.now().isBefore(deadline)) {
          final lineCountBefore = server.stdoutLines.length;
          server.sendCommand('CONNECTION_COUNT');
          // Wait for a new CONNECTIONS: line to appear after the command
          for (var attempts = 0; attempts < 200; attempts++) {
            await Future<void>.delayed(Duration.zero);
            if (server.stdoutLines.length > lineCountBefore) {
              final latest = server.stdoutLines.last;
              if (latest.startsWith('CONNECTIONS:')) {
                lastCount = int.parse(latest.substring('CONNECTIONS:'.length));
                break;
              }
            }
          }
          if (lastCount == 0) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(lastCount, equals(0), reason: 'Server should have 0 connections after all bidi clients were killed');

        // Verify server is still alive by performing a fresh echo RPC
        final echoClient = await ClientProcess.start('uds', path, 'echo', ['77']);
        final echoLines = await echoClient.waitForExit(timeout: const Duration(seconds: 60));
        expect(echoLines, contains('RESULT:77'), reason: 'Server should still accept new RPCs after mass disconnect');

        // Verify connection count is at most 1 (echo client may or may not have been cleaned up yet)
        final lineCountBeforeFinal = server.stdoutLines.length;
        server.sendCommand('CONNECTION_COUNT');
        final deadlineFinal = DateTime.now().add(const Duration(seconds: 10));
        var finalCount = -1;
        while (DateTime.now().isBefore(deadlineFinal)) {
          await Future<void>.delayed(Duration.zero);
          for (var i = lineCountBeforeFinal; i < server.stdoutLines.length; i++) {
            if (server.stdoutLines[i].startsWith('CONNECTIONS:')) {
              finalCount = int.parse(server.stdoutLines[i].substring('CONNECTIONS:'.length));
              break;
            }
          }
          if (finalCount >= 0) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        // The echo client already terminated, so connections should be 0 or at most 1
        expect(
          finalCount,
          lessThanOrEqualTo(1),
          reason: 'Connection count should be at most 1 after echo client exited',
        );

        await server.shutdownGracefully();
      },
      skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
    );

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

    // =========================================================================
    // D16: Server restart during active client streaming
    // =========================================================================
    test('D16: server restart during active client streaming (TCP)', () async {
      // Phase 1: Start a TCP server and a client with a long-running server stream.
      final server1 = await ServerProcess.start('tcp');
      addTearDown(() async {
        try {
          await server1.shutdownGracefully();
        } on StateError {
          // Already dead
        }
      });

      final streamClient = await ClientProcess.start('tcp', server1.address, 'server-stream-hold', ['10000']);
      addTearDown(() {
        streamClient.kill();
      });

      // Wait for the client to confirm it is actively receiving stream data.
      await streamClient.waitForMarker('STREAMING', timeout: const Duration(seconds: 60));

      // Phase 2: SIGKILL the server while the client has an active stream.
      // This is a hard crash — no graceful GOAWAY, no RST_STREAM, just a dead socket.
      server1.kill();
      await server1.exitCode;

      // The client should detect the broken connection and exit.
      // server-stream-hold catches GrpcError internally and prints DONE:<count>,
      // but a hard server kill may also surface as a non-GrpcError (exit code 1).
      // Either outcome proves the client detected the crash — it must not hang.
      final streamExitCode = await streamClient.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException(
            'Streaming client (pid=${streamClient.pid}) did not exit within 30s after server SIGKILL. '
            'Stdout: ${streamClient.stdout}',
          );
        },
      );

      // The client must have exited (any exit code is acceptable — 0 means GrpcError
      // was caught cleanly, non-zero means an unexpected transport error surfaced).
      // What matters is that it did NOT hang.
      final hasDone = streamClient.stdout.any((line) => line.startsWith('DONE:'));
      final hasError = streamClient.stdout.any((line) => line.startsWith('ERROR:'));
      expect(
        hasDone || hasError || streamExitCode != 0,
        isTrue,
        reason:
            'Streaming client should detect server crash via DONE, ERROR, or non-zero exit '
            '(exitCode=$streamExitCode, stdout=${streamClient.stdout})',
      );

      // Phase 3: Start a completely new server on a fresh ephemeral port.
      // This proves the system recovers — a new server on a new port is fully functional.
      final server2 = await ServerProcess.start('tcp');
      addTearDown(() async {
        try {
          await server2.shutdownGracefully();
        } on StateError {
          // Already dead
        }
      });

      // Verify the new server is clean and functional with a simple echo RPC.
      final echoClient = await ClientProcess.start('tcp', server2.address, 'echo', ['42']);
      final echoLines = await echoClient.waitForExit(timeout: const Duration(seconds: 30));
      expect(echoLines, contains('RESULT:42'), reason: 'New server should handle echo after predecessor crash');
      expect(echoLines, contains('CONNECTED'), reason: 'New server should accept connections cleanly');

      await server2.shutdownGracefully();
    });
  });
}
