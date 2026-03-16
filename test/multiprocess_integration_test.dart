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

  ServerProcess._(this._process, this.transport, this.address);

  int get pid => _process.pid;

  /// Spawn a server process and wait for it to signal readiness.
  static Future<ServerProcess> start(String transport, {String? socketPath}) async {
    final args = ['run', 'test/multiprocess/server_main.dart', transport];
    if (transport == 'uds' && socketPath != null) args.add(socketPath);

    final process = await Process.start(Platform.resolvedExecutable, args);

    // Capture stderr for diagnostics
    final stderrBuf = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(stderrBuf.write);

    // Wait for LISTENING:<address> on stdout
    final stdoutLines = process.stdout.transform(utf8.decoder).transform(const LineSplitter());
    String? address;

    await for (final line in stdoutLines) {
      if (line.startsWith('LISTENING:')) {
        address = line.substring('LISTENING:'.length);
        break;
      }
    }

    if (address == null) {
      final exitCode = await process.exitCode;
      throw StateError(
        'Server process (pid=${process.pid}) exited without signaling readiness. '
        'Exit code: $exitCode. Stderr: $stderrBuf',
      );
    }

    return ServerProcess._(process, transport, address);
  }

  /// Request graceful shutdown via stdin command.
  Future<int> shutdownGracefully({Duration timeout = const Duration(seconds: 10)}) async {
    _process.stdin.writeln('SHUTDOWN');
    return _process.exitCode.timeout(timeout, onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
      return -1;
    });
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

  ClientProcess._(this._process) {
    _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
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
    final args = [
      'run',
      'test/multiprocess/client_main.dart',
      transport,
      address,
      command,
      ...extraArgs,
    ];
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
  Future<List<String>> waitForExit({Duration timeout = const Duration(seconds: 15)}) async {
    final code = await exitCode.timeout(timeout, onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
      throw TimeoutException(
        'Client process (pid=$pid) did not exit within $timeout. '
        'Force-killed. Stdout so far: $_stdoutLines. Stderr: $stderr',
      );
    });
    // Wait for stdout stream to close (process may have exited but stdout buffer not yet flushed)
    await _exited.future.timeout(const Duration(seconds: 5), onTimeout: () {
      // stdout didn't close within 5s — return what we have with a warning
      _stderrBuf.writeln('WARNING: stdout did not close within 5s after process exit');
    });
    if (code != 0) {
      throw StateError('Client process (pid=$pid) exited with code $code. Stderr: $stderr');
    }
    return _stdoutLines;
  }

  /// Wait for a specific exact line in stdout, with timeout.
  /// Uses Completer-based approach — no polling, fires immediately when the line arrives.
  Future<void> waitForMarker(String marker, {Duration timeout = const Duration(seconds: 10)}) async {
    // Check if already received
    if (_stdoutLines.contains(marker)) return;
    // Register a waiter
    final completer = Completer<void>();
    _markerWaiters.putIfAbsent(marker, () => []).add(completer);
    await completer.future.timeout(timeout, onTimeout: () {
      throw TimeoutException(
        'Client (pid=$pid) did not produce marker "$marker" within $timeout. '
        'Stdout so far: $_stdoutLines',
      );
    });
  }

  /// Check if a specific exact line appeared in stdout.
  bool hasLine(String line) => _stdoutLines.contains(line);
}

/// Generate a unique UDS socket path for a test.
String _uniqueSocketPath(String testName) {
  final dir = Directory.systemTemp.createTempSync('grpc_multiprocess_');
  return '${dir.path}/$testName.sock';
}

// =============================================================================
// Test helpers
// =============================================================================

/// Run a test on both TCP and UDS (skip UDS on Windows).
void testMultiprocess(String name, Future<void> Function(String transport, String Function() addressAllocator) body) {
  test('$name (TCP)', () async {
    await body('tcp', () => ''); // TCP uses ephemeral port from server stdout
  });

  test(
    '$name (UDS)',
    () async {
      final path = _uniqueSocketPath(name.replaceAll(' ', '-'));
      addTearDown(() {
        try {
          File(path).deleteSync();
        } on FileSystemException { /* Socket file may already be gone */ }
      });
      await body('uds', () => path);
    },
    skip: Platform.isWindows ? 'UDS not supported on Windows' : null,
  );
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
      addTearDown(() => server.shutdownGracefully().catchError((Object e) { /* Teardown safety net — server may already be dead */ return -1; }));

      final client = await ClientProcess.start(transport, server.address, 'echo', ['42']);
      final lines = await client.waitForExit();

      expect(lines, contains('RESULT:42'), reason: 'Unary echo should return the input value');
      expect(lines, contains('CONNECTED'), reason: 'Client should report successful connection');

      final exitCode = await server.shutdownGracefully();
      expect(exitCode, equals(0), reason: 'Server should exit cleanly after graceful shutdown');
    });

    // =========================================================================
    // Scenario 2: Server process killed, client detects failure
    // =========================================================================
    testMultiprocess('client detects server crash and reports error', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);

      // First, prove the connection works
      final warmup = await ClientProcess.start(transport, server.address, 'echo', ['1']);
      final warmupLines = await warmup.waitForExit();
      expect(warmupLines, contains('CONNECTED'));

      // Kill the server process (simulates crash)
      server.kill();
      await server.exitCode;

      // Now try to make RPCs — should get errors
      final client = await ClientProcess.start(transport, server.address, 'echo-loop', ['5']);
      final lines = await client.waitForExit();

      // At least some RPCs should fail with UNAVAILABLE
      final errors = lines.where((l) => l.startsWith('ERROR:')).toList();
      expect(errors, isNotEmpty, reason: 'Client should receive errors after server crash');
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
          } on FileSystemException { /* Socket file may already be gone */ }
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
        addTearDown(() => server2.shutdownGracefully().catchError((Object e) { /* Teardown safety net — server may already be dead */ return -1; }));

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
      addTearDown(() => server.shutdownGracefully().catchError((Object e) { /* Teardown safety net — server may already be dead */ return -1; }));

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
        expect(
          allLines[i],
          contains('RESULT:${i * 10}'),
          reason: 'Client $i should receive echo result ${i * 10}',
        );
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
          } on FileSystemException { /* Socket file may already be gone */ }
        });

        final server1 = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() => server1.shutdownGracefully().catchError((Object e) { /* Teardown safety net — server may already be dead */ return -1; }));

        // Verify server1 is working
        final warmup = await ClientProcess.start('uds', path, 'echo', ['1']);
        final warmupLines = await warmup.waitForExit();
        expect(warmupLines, contains('RESULT:1'), reason: 'Server1 should be working');

        // Start server2 on the same path. Our server script deletes the
        // existing socket file before binding (stale cleanup), which
        // DESTROYS server1's socket. This is the expected behavior —
        // in production, the second server "takes over" the address.
        final server2 = await ServerProcess.start('uds', socketPath: path);
        addTearDown(() => server2.shutdownGracefully().catchError((Object e) { /* Teardown safety net — server may already be dead */ return -1; }));

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
    // Scenario 6: Client process killed, server cleans up
    // =========================================================================
    testMultiprocess('server survives client process crash during bidi stream', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() => server.shutdownGracefully().catchError((Object e) { /* Teardown safety net — server may already be dead */ return -1; }));

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

      await server.shutdownGracefully();
    });

    // =========================================================================
    // Scenario 7: Server-streaming across process boundary
    // =========================================================================
    testMultiprocess('server-streaming RPC delivers all items across process boundary', (transport, allocAddr) async {
      final server = await ServerProcess.start(transport, socketPath: transport == 'uds' ? allocAddr() : null);
      addTearDown(() => server.shutdownGracefully().catchError((Object e) { /* Teardown safety net — server may already be dead */ return -1; }));

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
        expect(
          lines,
          contains('RESULT:${cycle * 10}'),
          reason: 'Cycle $cycle: echo should return ${cycle * 10}',
        );

        lastPort = server.address;
        await server.shutdownGracefully();
      }
      expect(lastPort, isNotNull, reason: 'All 5 cycles should complete');
    });
  });
}

