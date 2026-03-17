// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba.,
// Pieces.app. All rights reserved.
//
// Standalone server process for multi-process integration tests.
// Launched via Process.start() from the test harness.
//
// Usage: dart run test/multiprocess/server_main.dart <transport> [args...]
//   transport: "tcp" | "uds"
//   For tcp: no additional args (binds to localhost:0, prints port)
//   For uds: <socket_path> (binds to the given path)
//   --max-message-size <bytes>: optional max inbound message size
//
// Protocol:
//   stdout: "LISTENING:<address>" when ready (address = port for TCP, path for UDS)
//   stdout: "SHUTDOWN" after graceful shutdown completes
//   stdout: "CONNECTIONS:<count>" in response to CONNECTION_COUNT command
//   stdin:  "SHUTDOWN\n" to trigger graceful shutdown
//   stdin:  "CONNECTION_COUNT\n" to query active connection count
//   exit 0: clean exit after shutdown
//   exit 1: error

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart';

import '../src/echo_service.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: server_main.dart <transport> [args...]');
    exit(1);
  }

  final transport = args[0];

  // Parse optional --max-message-size flag
  int? maxMessageSize;
  final maxMsgIdx = args.indexOf('--max-message-size');
  if (maxMsgIdx != -1 && maxMsgIdx + 1 < args.length) {
    maxMessageSize = int.parse(args[maxMsgIdx + 1]);
  }

  late final Server server;
  late final String address;

  server = Server.create(services: [EchoService()], maxInboundMessageSize: maxMessageSize);

  switch (transport) {
    case 'tcp':
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      address = '${server.port}';

    case 'uds':
      // Find the socket path argument (skip --max-message-size and its value)
      String? socketPath;
      for (var i = 1; i < args.length; i++) {
        if (args[i] == '--max-message-size') {
          i++; // skip value
          continue;
        }
        socketPath = args[i];
        break;
      }
      if (socketPath == null) {
        stderr.writeln('UDS transport requires socket path argument');
        exit(1);
      }
      // Clean up stale socket
      final stale = File(socketPath);
      if (stale.existsSync()) stale.deleteSync();
      await server.serve(address: InternetAddress(socketPath, type: InternetAddressType.unix), port: 0);
      address = socketPath;

    default:
      stderr.writeln('Unknown transport: $transport');
      exit(1);
  }

  // Signal readiness to the test harness
  stdout.writeln('LISTENING:$address');

  // Wait for commands on stdin (with LineSplitter for robust framing)
  final sub = stdin.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) async {
    final trimmed = line.trim();
    if (trimmed == 'SHUTDOWN') {
      await server.shutdown();
      stdout.writeln('SHUTDOWN');
      exit(0);
    } else if (trimmed == 'CONNECTION_COUNT') {
      // handlers is @visibleForTesting on ConnectionServer — available here
      stdout.writeln('CONNECTIONS:${server.handlers.length}');
    }
  });

  // Handle SIGTERM for graceful shutdown (Unix only — crashes on Windows)
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      sub.cancel();
      await server.shutdown();
      stdout.writeln('SHUTDOWN');
      exit(0);
    });
  }
}
