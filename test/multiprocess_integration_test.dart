// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba.,
// Pieces.app. All rights reserved.
//
// True multi-process integration tests for gRPC local IPC.
// These tests spawn ACTUAL OS processes (not isolates) for server and client,
// exercising real transport boundaries, real process lifecycle, and real
// OS-level cleanup.
@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// =============================================================================
// Process Harness
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
  static Future<ServerProcess> start(
    String transport, {
    String? socketPath,
    String? pipeName,
    int? maxMessageSize,
  }) async {
    final args = ['run', 'test/multiprocess/server_main.dart', transport];
    if (transport == 'uds' && socketPath != null) args.add(socketPath);
    if (transport == 'named-pipe' && pipeName != null) args.add(pipeName);
    if (maxMessageSize != null) args.addAll(['--max-message-size', '$maxMessageSize']);

    final process = await Process.start(Platform.resolvedExecutable, args);

    // process.stdout is a single-subscription stream. We use one subscription
    // for the entire lifetime: a Completer bridges the initial LISTENING line
    // back to the caller, and a mutable ServerProcess reference dispatches
    // subsequent lines to the instance once it exists.
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
            // Dispatch to the server instance if available, otherwise buffer
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

    // Wait for readiness
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
    // Replay any lines that arrived between LISTENING and now
    for (final line in earlyLines) {
      server._onStdoutLine(line);
    }
    // Wire up the mutable reference so future lines go directly to the server
    serverRef = server;
    return server;
  }

  /// Send a command to the server's stdin.
  void sendCommand(String command) {
    _process.stdin.writeln(command);
  }

  /// Wait for a stdout line starting with [prefix] and return the full line.
  Future<String> waitForPrefix(String prefix, {Duration timeout = const Duration(seconds: 10)}) async {
    // Check if already received
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
            // Fire any waiters whose marker matches this exact line
            for (final entry in _markerWaiters.entries) {
              if (line == entry.key) {
                for (final c in entry.value) {
                  if (!c.isCompleted) c.complete();
                }
              }
            }
            // Fire any prefix waiters
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
    // Wait for stdout stream to close (process may have exited but stdout buffer not yet flushed)
    await _exited.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        // stdout didn't close within 5s — return what we have with a warning
        _stderrBuf.writeln('WARNING: stdout did not close within 5s after process exit');
      },
    );
    if (code != 0) {
      throw StateError('Client process (pid=$pid) exited with code $code. Stderr: $stderr');
    }
    return _stdoutLines;
  }

  /// Wait for a specific exact line in stdout, with timeout.
  /// Uses Completer-based approach — no polling, fires immediately when the line arrives.
  Future<void> waitForMarker(String marker, {Duration timeout = const Duration(seconds: 30)}) async {
    // Check if already received
    if (_stdoutLines.contains(marker)) return;
    // Register a waiter
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
    // Check if already received
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
  final dir = Directory.systemTemp.createTempSync('grpc_multiprocess_');
  return '${dir.path}/$testName.sock';
}

/// Generate a unique Windows named pipe name for a test.
String _uniquePipeName(String testId) {
  return 'grpc-mp-${DateTime.now().microsecondsSinceEpoch}-$testId-$pid';
}

// =============================================================================
// Test helpers
// =============================================================================

/// Run a test on both TCP and UDS (skip UDS on Windows).
void testMultiprocess(String name, Future<void> Function(String transport, String Function() addressAllocator) body) {
  test('$name (TCP)', () async {
    await body('tcp', () => ''); // TCP uses ephemeral port from server stdout
  });

  test('$name (UDS)', () async {
    final path = _uniqueSocketPath(name.replaceAll(' ', '-'));
    addTearDown(() {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        /* Socket file may already be gone */
      }
    });
    await body('uds', () => path);
  }, skip: Platform.isWindows ? 'UDS not supported on Windows' : null);
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  group('Multi-process integration', () {
    // =========================================================================
    // Scenario 1: Server in process A, client in process B — happy path
    // =========================================================================
    testMultiprocess('server and client in separate processes complete unary RPC', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Server already dead
        }
      });

      final client = await ClientProcess.start(transport, server.address, 'echo', ['42']);
      final lines = await client.waitForExit();

      expect(lines, contains('RESULT:42'), reason: 'Unary echo should return the input value');
      expect(lines, contains('CONNECTED'), reason: 'Client should report successful connection');

      final exitCode = await server.shutdownGracefully();
      expect(exitCode, equals(0), reason: 'Server should exit cleanly after graceful shutdown');
    });

    // =========================================================================
    // Scenario 2: Server process killed, client detects failure mid-stream
    // =========================================================================
    testMultiprocess('client detects server crash mid-stream and reports error', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);

      // Start client with bidi-detect-crash — it opens a stream and waits
      final client = await ClientProcess.start(transport, server.address, 'bidi-detect-crash');
      addTearDown(() {
        client.kill();
      });

      // Wait for client to establish the bidi stream
      await client.waitForMarker('CONNECTED');

      // Kill the server process (simulates crash)
      server.kill();
      await server.exitCode;

      // Client should detect the broken stream and report an error
      final errorLine = await client.waitForPrefix('ERROR:', timeout: const Duration(seconds: 30));

      // The error should indicate the server is gone (UNAVAILABLE or transport error)
      expect(
        errorLine,
        anyOf(contains('UNAVAILABLE'), contains('2:'), contains('14:')),
        reason: 'Client should receive UNAVAILABLE or transport error after server crash',
      );

      // Client should exit on its own after detecting the error
      await client.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          client.kill();
          throw TimeoutException('Client did not exit after detecting server crash');
        },
      );
    });

    // =========================================================================
    // Scenario 3: Server restarts on same UDS path, client reconnects
    // =========================================================================
    // This only works on UDS/named pipes where the address is fixed.
    // TCP uses ephemeral ports — a restarted server gets a different port,
    // so the client can't reconnect without service discovery.
    test(
      'client reconnects after server restart on same UDS path',
      () async {
        final path = _uniqueSocketPath('reconnect');
        addTearDown(() {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            /* Socket file may already be gone */
          }
        });

        // Start server v1
        final server1 = await ServerProcess.start('uds', socketPath: path);

        // Start client with reconnect command
        final client = await ClientProcess.start('uds', path, 'reconnect-after-restart', ['10']);

        // Wait for client to connect
        await client.waitForMarker('CONNECTED');

        // Gracefully shut down server v1
        await server1.shutdownGracefully();

        // Start server v2 on the SAME path
        final server2 = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server2.shutdownGracefully();
          } on StateError {
            // Server already dead
          }
        });

        // Signal client that server has restarted
        client.sendCommand('RESTART');

        // Wait for client to reconnect
        final lines = await client.waitForExit(timeout: const Duration(seconds: 30));

        expect(lines, contains('CONNECTED'), reason: 'Client should have connected to server v1');
        expect(lines, contains('RECONNECTED'), reason: 'Client should reconnect to server v2');
        expect(lines, contains('RESULT:11'), reason: 'Post-restart echo(11) should return 11');

        await server2.shutdownGracefully();
      },
      skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
    );

    // =========================================================================
    // Scenario 4: Four client processes connect to one server
    // =========================================================================
    testMultiprocess('four client processes connect to one server concurrently', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Server already dead
        }
      });

      // Spawn 4 client processes. On CI (2-core), simultaneous `dart run`
      // compilations cause extreme contention. Stagger launches slightly
      // and give generous timeouts for the compilation + connection phase.
      final clients = <ClientProcess>[];
      for (var i = 0; i < 4; i++) {
        clients.add(await ClientProcess.start(transport, server.address, 'echo', ['${i * 10}']));
      }

      // Wait for all to complete — generous timeout for CI
      final allLines = await Future.wait([
        for (final c in clients) c.waitForExit(timeout: const Duration(seconds: 60)),
      ]);

      for (var i = 0; i < 4; i++) {
        expect(allLines[i], contains('RESULT:${i * 10}'), reason: 'Client $i should receive echo result ${i * 10}');
        expect(allLines[i], contains('CONNECTED'), reason: 'Client $i should report connection');
      }

      await server.shutdownGracefully();
    });

    // =========================================================================
    // Scenario 5: Two servers race to bind same address
    // =========================================================================
    test(
      'second server on same UDS path disrupts first server (stale cleanup behavior)',
      () async {
        final path = _uniqueSocketPath('bind-race');
        addTearDown(() {
          try {
            File(path).deleteSync();
          } on FileSystemException {
            /* Socket file may already be gone */
          }
        });

        final server1 = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server1.shutdownGracefully();
          } on StateError {
            // Server already dead
          }
        });

        // Verify server1 is working
        final warmup = await ClientProcess.start('uds', path, 'echo', ['1']);
        final warmupLines = await warmup.waitForExit();
        expect(warmupLines, contains('RESULT:1'), reason: 'Server1 should be working');

        // Start server2 on the same path. Our server script deletes the
        // existing socket file before binding (stale cleanup), which
        // DESTROYS server1's socket. This is the expected behavior —
        // in production, the second server "takes over" the address.
        final server2 = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() async {
          try {
            await server2.shutdownGracefully();
          } on StateError {
            // Server already dead
          }
        });

        // Now server2 owns the path. Server1 is still running but
        // unreachable (its socket was deleted). New clients connect to server2.
        final client = await ClientProcess.start('uds', path, 'echo', ['42']);
        final lines = await client.waitForExit();
        expect(lines, contains('RESULT:42'), reason: 'Server2 should handle new connections');

        await server2.shutdownGracefully();
        await server1.shutdownGracefully();
      },
      skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
    );

    // =========================================================================
    // Scenario 6: Client process killed, server cleans up + connection count
    // =========================================================================
    testMultiprocess('server survives client process crash during bidi stream', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Server already dead
        }
      });

      // Start client holding a bidi stream open
      final client = await ClientProcess.start(transport, server.address, 'bidi-hold');
      await client.waitForMarker('HOLDING');

      // Kill the client process (simulates crash)
      client.kill();
      await client.exitCode;

      // Server should still be alive and accept new connections
      final client2 = await ClientProcess.start(transport, server.address, 'echo', ['77']);
      final lines = await client2.waitForExit();
      expect(lines, contains('RESULT:77'), reason: 'Server should still work after client crash');

      // Verify server cleaned up the old connection (handler cleanup verification)
      // Give the server a moment to clean up the dead connection's handlers
      // by sending CONNECTION_COUNT and checking the result.
      server.sendCommand('CONNECTION_COUNT');
      final countLine = await server.waitForPrefix('CONNECTIONS:');
      final count = int.parse(countLine.substring('CONNECTIONS:'.length));
      // The new client (client2) already exited, so connections should be 0 or 1
      // (depending on cleanup timing). The crashed client's connection should be gone.
      expect(count, lessThanOrEqualTo(1), reason: 'Crashed client connection should be cleaned up');

      await server.shutdownGracefully();
    });

    // =========================================================================
    // Scenario 7: Server-streaming across process boundary
    // =========================================================================
    testMultiprocess('server-streaming RPC delivers all items across process boundary', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Server already dead
        }
      });

      final client = await ClientProcess.start(transport, server.address, 'server-stream', ['50']);
      final lines = await client.waitForExit();

      expect(lines, contains('RESULT:50'), reason: 'Server stream should deliver all 50 items');
      expect(lines, contains('CONNECTED'));

      await server.shutdownGracefully();
    });

    // =========================================================================
    // Scenario 8: Repeated server restart cycles
    // =========================================================================
    test('server survives 5 restart cycles with client reconnecting each time (TCP)', () async {
      String? lastPort;
      for (var cycle = 0; cycle < 5; cycle++) {
        final server = await ServerProcess.start('tcp');

        final client = await ClientProcess.start('tcp', server.address, 'echo', ['${cycle * 10}']);
        final lines = await client.waitForExit();
        expect(lines, contains('RESULT:${cycle * 10}'), reason: 'Cycle $cycle: echo should return ${cycle * 10}');

        lastPort = server.address;
        await server.shutdownGracefully();
      }
      expect(lastPort, isNotNull, reason: 'All 5 cycles should complete');
    });

    // =========================================================================
    // Scenario 9: Bidi stream content verification
    // =========================================================================
    testMultiprocess('bidi stream returns correct doubled value', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Server already dead
        }
      });

      // bidi-hold sends 42, EchoService doubles it to 84
      final client = await ClientProcess.start(transport, server.address, 'bidi-hold');
      await client.waitForMarker('HOLDING');

      // The RESULT line should contain 84 (42 * 2)
      expect(client.stdout, contains('RESULT:84'), reason: 'EchoService bidi should double 42 to 84');

      client.sendCommand('CLOSE');
      await client.waitForExit();

      await server.shutdownGracefully();
    });

    // =========================================================================
    // Scenario 10: Graceful shutdown during active server-streaming
    // =========================================================================
    testMultiprocess('graceful shutdown truncates active server stream', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Server already dead
        }
      });

      // Start client with a long server stream (10000 items with 1ms delays = ~10s)
      final client = await ClientProcess.start(transport, server.address, 'server-stream-hold', ['10000']);
      addTearDown(() {
        client.kill();
      });

      // Wait for streaming to begin
      await client.waitForMarker('STREAMING');

      // Gracefully shut down server while stream is active
      final serverExit = await server.shutdownGracefully();
      expect(serverExit, equals(0), reason: 'Server should exit cleanly after graceful shutdown');

      // Client should finish with a truncated stream
      final doneLine = await client.waitForPrefix('DONE:', timeout: const Duration(seconds: 30));
      final itemCount = int.parse(doneLine.substring('DONE:'.length));

      // Should have received some items but not all 10000
      expect(itemCount, greaterThan(0), reason: 'Client should have received some items before shutdown');
      expect(itemCount, lessThan(10000), reason: 'Stream should be truncated by graceful shutdown');

      // Client should exit
      await client.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          client.kill();
          return -1;
        },
      );
    });

    // =========================================================================
    // Scenario 11: Concurrent streaming — 3 clients stream simultaneously
    // =========================================================================
    testMultiprocess('three concurrent server-streaming clients all complete', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Server already dead
        }
      });

      // Start 3 clients each streaming 100 items
      final clients = <ClientProcess>[];
      for (var i = 0; i < 3; i++) {
        clients.add(await ClientProcess.start(transport, server.address, 'server-stream-hold', ['100']));
      }
      addTearDown(() {
        for (final c in clients) {
          c.kill();
        }
      });

      // Wait for all 3 to start streaming (60s: 3 dart run compiles on 2-core CI runners)
      await Future.wait([for (final c in clients) c.waitForMarker('STREAMING', timeout: const Duration(seconds: 60))]);

      // Wait for all 3 to complete
      for (var i = 0; i < 3; i++) {
        final doneLine = await clients[i].waitForPrefix('DONE:', timeout: const Duration(seconds: 60));
        final itemCount = int.parse(doneLine.substring('DONE:'.length));
        expect(itemCount, equals(100), reason: 'Client $i should receive all 100 items');
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
    });

    // =========================================================================
    // Scenario 12: Client-streaming cross-process test
    // =========================================================================
    testMultiprocess('client-streaming RPC aggregates values across process boundary', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Server already dead
        }
      });

      // client-stream 10: sends 0+1+2+...+9 = 45
      final client = await ClientProcess.start(transport, server.address, 'client-stream', ['10']);
      final lines = await client.waitForExit();

      expect(lines, contains('RESULT:45'), reason: 'Client stream of 0..9 should sum to 45');
      expect(lines, contains('CONNECTED'));

      await server.shutdownGracefully();
    });

    // =========================================================================
    // Scenario 13: maxInboundMessageSize enforcement across processes
    // =========================================================================
    testMultiprocess('server rejects oversized message with RESOURCE_EXHAUSTED', (transport, allocAddr) async {
      final server = await ServerProcess.start(
        transport,
        socketPath: transport == 'uds' ? allocAddr() : null,
        maxMessageSize: 1024,
      );
      addTearDown(() async {
        try {
          await server.shutdownGracefully();
        } on StateError {
          // Server already dead
        }
      });

      // Send a 2048-byte payload — should exceed the 1024-byte limit
      final client = await ClientProcess.start(transport, server.address, 'echo-bytes', ['2048']);
      final lines = await client.waitForExit();

      // Should get a RESOURCE_EXHAUSTED error
      final errors = lines.where((l) => l.startsWith('ERROR:')).toList();
      expect(errors, isNotEmpty, reason: 'Client should receive an error for oversized message');
      expect(
        errors.first,
        contains('8:'), // StatusCode.resourceExhausted = 8
        reason: 'Error should be RESOURCE_EXHAUSTED (code 8)',
      );

      await server.shutdownGracefully();
    });

    // =========================================================================
    // Named pipe transport tests (Windows-only)
    // =========================================================================
    group('Named pipe transport', () {
      // =======================================================================
      // A1: Basic unary RPC over named pipe
      // =======================================================================
      test('basic unary RPC over named pipe', () async {
        final pipeName = _uniquePipeName('a1-basic');
        final server = await ServerProcess.start('named-pipe', pipeName: pipeName);
        addTearDown(() async {
          try {
            await server.shutdownGracefully();
          } on StateError {
            // Server already dead
          }
        });

        final client = await ClientProcess.start('named-pipe', server.address, 'echo', ['42']);
        final lines = await client.waitForExit();

        expect(lines, contains('RESULT:42'), reason: 'Unary echo should return the input value');
        expect(lines, contains('CONNECTED'), reason: 'Client should report successful connection');

        final exitCode = await server.shutdownGracefully();
        expect(exitCode, equals(0), reason: 'Server should exit cleanly after graceful shutdown');
      }, skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null);

      // =======================================================================
      // A2: Server crash -> client detects error over named pipe
      // =======================================================================
      test(
        'client detects server crash mid-stream over named pipe',
        () async {
          final pipeName = _uniquePipeName('a2-crash');
          final server = await ServerProcess.start('named-pipe', pipeName: pipeName);

          final client = await ClientProcess.start('named-pipe', server.address, 'bidi-detect-crash');
          addTearDown(() {
            client.kill();
          });

          // Wait for client to establish the bidi stream
          await client.waitForMarker('CONNECTED');

          // Kill the server process (simulates crash)
          server.kill();
          await server.exitCode;

          // Client should detect the broken stream and report an error or normal close
          final resultLine = await client
              .waitForPrefix('ERROR:', timeout: const Duration(seconds: 30))
              .then<String>(
                (line) => line,
                onError: (_) async {
                  // If no ERROR line, the stream may have ended normally (DONE:NORMAL)
                  // which is also acceptable for named pipes where the broken pipe
                  // can manifest as a clean stream close.
                  final doneLine = await client.waitForPrefix('DONE:', timeout: const Duration(seconds: 10));
                  return doneLine;
                },
              );

          // Either an error or a normal close is acceptable — the key is that
          // the client detected the server disappearance and did not hang.
          expect(
            resultLine,
            anyOf(contains('ERROR:'), contains('DONE:')),
            reason: 'Client should detect server crash via error or stream close',
          );

          // Client should exit on its own after detecting the error
          await client.exitCode.timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              client.kill();
              return -1;
            },
          );
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
      );

      // =======================================================================
      // A3: Multiple clients on one named pipe server
      // =======================================================================
      test(
        'four clients connect to one named pipe server concurrently',
        () async {
          final pipeName = _uniquePipeName('a3-multi');
          final server = await ServerProcess.start('named-pipe', pipeName: pipeName);
          addTearDown(() async {
            try {
              await server.shutdownGracefully();
            } on StateError {
              // Server already dead
            }
          });

          // Spawn 4 client processes
          final clients = <ClientProcess>[];
          for (var i = 0; i < 4; i++) {
            clients.add(await ClientProcess.start('named-pipe', server.address, 'echo', ['${i * 10}']));
          }

          // Wait for all to complete
          final allLines = await Future.wait([
            for (final c in clients) c.waitForExit(timeout: const Duration(seconds: 60)),
          ]);

          for (var i = 0; i < 4; i++) {
            expect(allLines[i], contains('RESULT:${i * 10}'), reason: 'Client $i should receive echo result ${i * 10}');
            expect(allLines[i], contains('CONNECTED'), reason: 'Client $i should report connection');
          }

          await server.shutdownGracefully();
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
      );

      // =======================================================================
      // A4: Two servers on same named pipe name
      // =======================================================================
      test(
        'second server on same pipe name — coexistence or failure',
        () async {
          final pipeName = _uniquePipeName('a4-dual');
          final server1 = await ServerProcess.start('named-pipe', pipeName: pipeName);
          addTearDown(() async {
            try {
              await server1.shutdownGracefully();
            } on StateError {
              // Server already dead
            }
          });

          // Verify server1 is working
          final warmup = await ClientProcess.start('named-pipe', server1.address, 'echo', ['1']);
          final warmupLines = await warmup.waitForExit();
          expect(warmupLines, contains('RESULT:1'), reason: 'Server1 should be working');

          // Start server2 on the SAME pipe name. Windows named pipes support
          // multiple instances (PIPE_UNLIMITED_INSTANCES), so both servers
          // can coexist. The OS load-balances connections across instances.
          // If the server fails to start, the process will exit with an error.
          var server2Started = true;
          late final ServerProcess server2;
          try {
            server2 = await ServerProcess.start('named-pipe', pipeName: pipeName);
            addTearDown(() async {
              try {
                await server2.shutdownGracefully();
              } on StateError {
                // Server already dead
              }
            });
          } on StateError {
            // Server2 failed to start — this is acceptable behavior
            server2Started = false;
          } on TimeoutException {
            // Server2 timed out starting — also acceptable
            server2Started = false;
          }

          if (server2Started) {
            // Both servers are running. A new client should connect to one of them.
            final client = await ClientProcess.start('named-pipe', pipeName, 'echo', ['42']);
            final lines = await client.waitForExit();
            expect(lines, contains('RESULT:42'), reason: 'One of the servers should handle the connection');

            await server2.shutdownGracefully();
          }

          // Server1 should still be functional regardless
          final verify = await ClientProcess.start('named-pipe', server1.address, 'echo', ['99']);
          final verifyLines = await verify.waitForExit();
          expect(verifyLines, contains('RESULT:99'), reason: 'Server1 should still work');

          await server1.shutdownGracefully();
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
      );

      // =======================================================================
      // A5: Server restart on same pipe name, client reconnects
      // =======================================================================
      test(
        'client reconnects after server restart on same named pipe',
        () async {
          final pipeName = _uniquePipeName('a5-restart');

          // Start server v1
          final server1 = await ServerProcess.start('named-pipe', pipeName: pipeName);

          // Start client with reconnect command
          final client = await ClientProcess.start('named-pipe', server1.address, 'reconnect-after-restart', ['10']);

          // Wait for client to connect
          await client.waitForMarker('CONNECTED');

          // Gracefully shut down server v1
          await server1.shutdownGracefully();

          // Start server v2 on the SAME pipe name
          final server2 = await ServerProcess.start('named-pipe', pipeName: pipeName);
          addTearDown(() async {
            try {
              await server2.shutdownGracefully();
            } on StateError {
              // Server already dead
            }
          });

          // Signal client that server has restarted
          client.sendCommand('RESTART');

          // Wait for client to reconnect
          final lines = await client.waitForExit(timeout: const Duration(seconds: 30));

          expect(lines, contains('CONNECTED'), reason: 'Client should have connected to server v1');
          expect(lines, contains('RECONNECTED'), reason: 'Client should reconnect to server v2');
          expect(lines, contains('RESULT:11'), reason: 'Post-restart echo(11) should return 11');

          await server2.shutdownGracefully();
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
      );

      // =======================================================================
      // A6: Client crash during bidi, server survives
      // =======================================================================
      test(
        'server survives client crash during bidi stream over named pipe',
        () async {
          final pipeName = _uniquePipeName('a6-clientcrash');
          final server = await ServerProcess.start('named-pipe', pipeName: pipeName);
          addTearDown(() async {
            try {
              await server.shutdownGracefully();
            } on StateError {
              // Server already dead
            }
          });

          // Start client holding a bidi stream open
          final client = await ClientProcess.start('named-pipe', server.address, 'bidi-hold');
          await client.waitForMarker('HOLDING');

          // Kill the client process (simulates crash)
          client.kill();
          await client.exitCode;

          // Server should still be alive and accept new connections
          final client2 = await ClientProcess.start('named-pipe', server.address, 'echo', ['77']);
          final lines = await client2.waitForExit();
          expect(lines, contains('RESULT:77'), reason: 'Server should still work after client crash');

          // Verify server cleaned up the old connection
          server.sendCommand('CONNECTION_COUNT');
          final countLine = await server.waitForPrefix('CONNECTIONS:');
          final count = int.parse(countLine.substring('CONNECTIONS:'.length));
          // The new client (client2) already exited, so connections should be 0 or 1
          expect(count, lessThanOrEqualTo(1), reason: 'Crashed client connection should be cleaned up');

          await server.shutdownGracefully();
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
      );

      // =======================================================================
      // A7: Graceful shutdown truncates active server stream over named pipe
      // =======================================================================
      test(
        'graceful shutdown truncates active server stream over named pipe',
        () async {
          final pipeName = _uniquePipeName('a7-graceful');
          final server = await ServerProcess.start('named-pipe', pipeName: pipeName);
          addTearDown(() async {
            try {
              await server.shutdownGracefully();
            } on StateError {
              // Server already dead
            }
          });

          // Start client with a long server stream (10000 items with 1ms delays = ~10s)
          final client = await ClientProcess.start('named-pipe', server.address, 'server-stream-hold', ['10000']);
          addTearDown(() {
            client.kill();
          });

          // Wait for streaming to begin
          await client.waitForMarker('STREAMING');

          // Gracefully shut down server while stream is active
          final serverExit = await server.shutdownGracefully();
          expect(serverExit, equals(0), reason: 'Server should exit cleanly after graceful shutdown');

          // Client should finish with a truncated stream
          final doneLine = await client.waitForPrefix('DONE:', timeout: const Duration(seconds: 30));
          final itemCount = int.parse(doneLine.substring('DONE:'.length));

          // Should have received some items but not all 10000
          expect(itemCount, greaterThan(0), reason: 'Client should have received some items before shutdown');
          expect(itemCount, lessThan(10000), reason: 'Stream should be truncated by graceful shutdown');

          // Client should exit
          await client.exitCode.timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              client.kill();
              return -1;
            },
          );
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
      );

      // =======================================================================
      // A8: Three concurrent server-streaming clients over named pipe
      // =======================================================================
      test(
        'three concurrent server-streaming clients over named pipe',
        () async {
          final pipeName = _uniquePipeName('a8-concurrent-stream');
          final server = await ServerProcess.start('named-pipe', pipeName: pipeName);
          addTearDown(() async {
            try {
              await server.shutdownGracefully();
            } on StateError {
              // Server already dead
            }
          });

          // Start 3 client processes, each requesting a 100-item server stream
          final clients = <ClientProcess>[];
          for (var i = 0; i < 3; i++) {
            final client = await ClientProcess.start('named-pipe', server.address, 'server-stream-hold', ['100']);
            addTearDown(() {
              client.kill();
            });
            clients.add(client);
          }

          // Wait for all 3 clients to begin streaming (STREAMING marker after first item)
          await Future.wait([
            for (final client in clients) client.waitForMarker('STREAMING', timeout: const Duration(seconds: 60)),
          ]);

          // Wait for all 3 clients to finish receiving the full stream
          final doneLines = await Future.wait([
            for (final client in clients) client.waitForPrefix('DONE:', timeout: const Duration(seconds: 60)),
          ]);

          // Each client should have received exactly 100 items
          for (var i = 0; i < 3; i++) {
            final itemCount = int.parse(doneLines[i].substring('DONE:'.length));
            expect(itemCount, equals(100), reason: 'Client $i should have received all 100 items');
          }

          // All clients should exit cleanly
          for (final client in clients) {
            await client.exitCode.timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                client.kill();
                return -1;
              },
            );
          }

          final exitCode = await server.shutdownGracefully();
          expect(exitCode, equals(0), reason: 'Server should exit cleanly after graceful shutdown');
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
      );

      // =======================================================================
      // A9: Server survives 5 restart cycles on same named pipe
      // =======================================================================
      test(
        'server survives 5 restart cycles on same named pipe',
        () async {
          final pipeName = _uniquePipeName('a9-restart-cycle');
          int? lastCycle;

          for (var cycle = 0; cycle < 5; cycle++) {
            final server = await ServerProcess.start('named-pipe', pipeName: pipeName);

            final client = await ClientProcess.start('named-pipe', server.address, 'echo', ['$cycle']);
            final lines = await client.waitForExit();
            expect(lines, contains('RESULT:$cycle'), reason: 'Cycle $cycle: echo should return $cycle');

            final exitCode = await server.shutdownGracefully();
            expect(
              exitCode,
              equals(0),
              reason: 'Cycle $cycle: server should exit cleanly with code 0 (cooperative isolate exit)',
            );

            lastCycle = cycle;
          }

          expect(lastCycle, equals(4), reason: 'All 5 restart cycles should complete without pipe handle leaks');
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
        timeout: const Timeout(Duration(minutes: 5)),
      );

      // =======================================================================
      // A10: Concurrent 512KB payloads from 3 clients over named pipe
      // =======================================================================
      test(
        'concurrent 512KB payloads from 3 clients over named pipe',
        () async {
          final pipeName = _uniquePipeName('a10-large-payload');
          final server = await ServerProcess.start('named-pipe', pipeName: pipeName);
          addTearDown(() async {
            try {
              await server.shutdownGracefully();
            } on StateError {
              // Server already dead
            }
          });

          // Start 3 client processes, each sending a 512KB (524288 byte) payload.
          // This exercises the named pipe chunked write path (_enqueueWriteChunks
          // with 16KB chunks) under concurrent load — a completely different code
          // path from TCP/UDS.
          final clients = <ClientProcess>[];
          for (var i = 0; i < 3; i++) {
            final client = await ClientProcess.start('named-pipe', server.address, 'echo-bytes', ['524288']);
            addTearDown(() {
              client.kill();
            });
            clients.add(client);
          }

          // Wait for all 3 clients to complete
          final allLines = await Future.wait([
            for (final c in clients) c.waitForExit(timeout: const Duration(seconds: 120)),
          ]);

          // Each client should have received exactly 524288 bytes back
          for (var i = 0; i < 3; i++) {
            expect(allLines[i], contains('RESULT:524288'), reason: 'Client $i should receive 524288 bytes echoed back');
            expect(allLines[i], contains('CONNECTED'), reason: 'Client $i should report successful connection');
          }

          final exitCode = await server.shutdownGracefully();
          expect(exitCode, equals(0), reason: 'Server should exit cleanly after graceful shutdown');
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
      );

      // =======================================================================
      // A11: Client join/leave during active bidi streams over named pipe
      // =======================================================================
      test(
        'client join/leave during active bidi streams over named pipe',
        () async {
          final pipeName = _uniquePipeName('a11-joinleave');
          final server = await ServerProcess.start('named-pipe', pipeName: pipeName);
          addTearDown(() async {
            try {
              await server.shutdownGracefully();
            } on StateError {
              // Server already dead
            }
          });

          // Start 3 clients holding bidi streams open
          final bidiClients = <ClientProcess>[];
          for (var i = 0; i < 3; i++) {
            bidiClients.add(await ClientProcess.start('named-pipe', server.address, 'bidi-hold'));
          }
          addTearDown(() {
            for (final c in bidiClients) {
              c.kill();
            }
          });

          // Wait for all 3 to be actively holding their bidi streams
          await Future.wait([
            for (final c in bidiClients) c.waitForMarker('HOLDING', timeout: const Duration(seconds: 60)),
          ]);

          // Kill client 0 (simulates crash mid-bidi-stream)
          bidiClients[0].kill();
          await bidiClients[0].exitCode;

          // Start 2 new clients with echo command while other bidi streams are active
          final newClients = <ClientProcess>[];
          for (var i = 0; i < 2; i++) {
            newClients.add(await ClientProcess.start('named-pipe', server.address, 'echo', ['99']));
          }

          // Both new clients should complete successfully despite connection churn
          for (var i = 0; i < 2; i++) {
            final lines = await newClients[i].waitForExit(timeout: const Duration(seconds: 60));
            expect(lines, contains('RESULT:99'), reason: 'New client $i should receive echo result 99');
            expect(lines, contains('CONNECTED'), reason: 'New client $i should report connection');
          }

          // Clean up remaining bidi clients (indices 1 and 2)
          for (var i = 1; i < 3; i++) {
            bidiClients[i].sendCommand('CLOSE');
          }
          await Future.wait([
            for (var i = 1; i < 3; i++)
              bidiClients[i].exitCode.timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  bidiClients[i].kill();
                  return -1;
                },
              ),
          ]);

          final exitCode = await server.shutdownGracefully();
          expect(exitCode, equals(0), reason: 'Server should exit cleanly after graceful shutdown');
        },
        skip: !Platform.isWindows ? 'Named pipes are Windows-only' : null,
      );
    });
  });
}
