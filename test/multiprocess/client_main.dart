// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba.,
// Pieces.app. All rights reserved.
//
// Standalone client process for multi-process integration tests.
// Launched via Process.start() from the test harness.
//
// Usage: dart run test/multiprocess/client_main.dart <transport> <address> <command> [args...]
//   transport: "tcp" | "uds" | "named-pipe"
//   address: port number (TCP), socket path (UDS), or pipe name (named-pipe)
//   command:
//     "echo <value>"         — single unary RPC, prints result
//     "echo-loop <count>"    — N sequential unary RPCs, prints each result
//     "server-stream <count>" — server-streaming RPC, prints item count
//     "bidi-hold"            — open bidi stream, hold until stdin "CLOSE\n"
//     "reconnect-after-restart <value>" — echo, wait for restart signal, echo again
//     "client-stream <count>" — client-streaming RPC, prints aggregated result
//     "bidi-detect-crash"    — open bidi stream, detect server crash
//     "server-stream-hold <count>" — server-streaming, prints STREAMING after first item
//     "echo-bytes <size>"    — send a byte payload of given size, prints result length
//
// Protocol:
//   stdout: "RESULT:<value>" for each RPC result
//   stdout: "ERROR:<code>:<message>" for each RPC error
//   stdout: "CONNECTED" when first RPC succeeds
//   stdout: "RECONNECTED" when post-restart RPC succeeds
//   stdout: "HOLDING" when bidi stream is open and waiting
//   stdout: "STREAMING" when server-stream-hold receives first item
//   stdout: "DONE:<count>" when server-stream-hold finishes
//   stdin:  "CLOSE\n" to close bidi stream and exit
//   stdin:  "RESTART\n" to signal server has restarted (for reconnect test)
//   exit 0: clean exit
//   exit 1: unexpected error

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart' hide ClientChannel;
import 'package:grpc/grpc.dart' as grpc show ClientChannel;
import 'package:grpc/src/client/channel.dart' as base show ClientChannel;

import '../src/echo_service.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('Usage: client_main.dart <transport> <address> <command> [args...]');
    exit(1);
  }

  final transport = args[0];
  final address = args[1];
  final command = args[2];

  final base.ClientChannel channel;
  switch (transport) {
    case 'tcp':
      channel = grpc.ClientChannel(
        InternetAddress.loopbackIPv4,
        port: int.parse(address),
        options: ChannelOptions(
          credentials: const ChannelCredentials.insecure(),
          backoffStrategy: (Duration? last) => last == null ? const Duration(milliseconds: 100) : last * 2,
          connectTimeout: const Duration(seconds: 5),
        ),
      );
    case 'uds':
      channel = grpc.ClientChannel(
        InternetAddress(address, type: InternetAddressType.unix),
        port: 0,
        options: ChannelOptions(
          credentials: const ChannelCredentials.insecure(),
          backoffStrategy: (Duration? last) => last == null ? const Duration(milliseconds: 100) : last * 2,
          connectTimeout: const Duration(seconds: 5),
        ),
      );
    case 'named-pipe':
      channel = NamedPipeClientChannel(
        address, // pipe name (the server prints the full pipe path, but the channel only needs the name)
        options: NamedPipeChannelOptions(
          backoffStrategy: (Duration? last) => last == null ? const Duration(milliseconds: 100) : last * 2,
          connectTimeout: const Duration(seconds: 5),
        ),
      );
    default:
      stderr.writeln('Unknown transport: $transport');
      exit(1);
  }

  final client = EchoClient(channel);

  try {
    switch (command) {
      case 'echo':
        final value = int.parse(args[3]);
        final result = await client.echo(value);
        stdout.writeln('RESULT:$result');
        stdout.writeln('CONNECTED');

      case 'echo-loop':
        final count = int.parse(args[3]);
        for (var i = 0; i < count; i++) {
          try {
            final result = await client.echo(i);
            stdout.writeln('RESULT:$result');
            if (i == 0) stdout.writeln('CONNECTED');
          } on GrpcError catch (e) {
            stdout.writeln('ERROR:${e.code}:${e.message}');
          }
        }

      case 'server-stream':
        final count = int.parse(args[3]);
        final items = await client.serverStream(count).toList();
        stdout.writeln('RESULT:${items.length}');
        stdout.writeln('CONNECTED');

      case 'bidi-hold':
        final controller = StreamController<int>();
        final responseStream = client.bidiStream(controller.stream);
        // Send one item to prove connection is alive
        controller.add(42);
        final first = await responseStream.first;
        stdout.writeln('RESULT:$first');
        stdout.writeln('HOLDING');
        // Wait for CLOSE command on stdin
        await for (final line in stdin.transform(const SystemEncoding().decoder).transform(const LineSplitter())) {
          if (line.trim() == 'CLOSE') {
            await controller.close();
            break;
          }
        }

      case 'reconnect-after-restart':
        final value = int.parse(args[3]);
        // First echo
        final result1 = await client.echo(value);
        stdout.writeln('RESULT:$result1');
        stdout.writeln('CONNECTED');
        // Wait for RESTART signal
        await for (final line in stdin.transform(const SystemEncoding().decoder).transform(const LineSplitter())) {
          if (line.trim() == 'RESTART') break;
        }
        // Retry echo with backoff (server just restarted)
        for (var attempt = 0; attempt < 20; attempt++) {
          try {
            final result2 = await client.echo(value + 1).timeout(const Duration(seconds: 2));
            stdout.writeln('RESULT:$result2');
            stdout.writeln('RECONNECTED');
            break;
          } on GrpcError {
            await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
          } on TimeoutException {
            await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
          }
        }

      case 'client-stream':
        final count = int.parse(args[3]);
        final controller = StreamController<int>();
        final resultFuture = client.clientStream(controller.stream);
        for (var i = 0; i < count; i++) {
          controller.add(i);
        }
        await controller.close();
        final result = await resultFuture;
        stdout.writeln('RESULT:$result');
        stdout.writeln('CONNECTED');

      case 'bidi-detect-crash':
        final controller = StreamController<int>();
        final responseStream = client.bidiStream(controller.stream);
        // Send one item to prove connection is alive
        controller.add(42);
        try {
          var gotFirst = false;
          await for (final value in responseStream) {
            if (!gotFirst) {
              stdout.writeln('RESULT:$value');
              stdout.writeln('CONNECTED');
              gotFirst = true;
              // Keep the stream open — server crash will break it
            }
          }
          // Stream ended normally (unexpected in crash scenario)
          stdout.writeln('DONE:NORMAL');
        } on GrpcError catch (e) {
          stdout.writeln('ERROR:${e.code}:${e.message}');
        }
        await controller.close();

      case 'server-stream-hold':
        final count = int.parse(args[3]);
        var itemCount = 0;
        try {
          await for (final _ in client.serverStream(count)) {
            itemCount++;
            if (itemCount == 1) {
              stdout.writeln('STREAMING');
            }
          }
        } on GrpcError catch (e) {
          stdout.writeln('ERROR:${e.code}:${e.message}');
        }
        stdout.writeln('DONE:$itemCount');

      case 'echo-bytes':
        final size = int.parse(args[3]);
        final payload = List<int>.filled(size, 0xAB);
        try {
          final result = await client.echoBytes(payload);
          stdout.writeln('RESULT:${result.length}');
          stdout.writeln('CONNECTED');
        } on GrpcError catch (e) {
          stdout.writeln('ERROR:${e.code}:${e.message}');
        }

      default:
        stderr.writeln('Unknown command: $command');
        exit(1);
    }
  } on GrpcError catch (e) {
    stdout.writeln('ERROR:${e.code}:${e.message}');
  } catch (e) {
    stderr.writeln('Unexpected error: $e');
    exit(1);
  }

  // Use terminate() instead of shutdown() — if the server is dead,
  // shutdown() waits for reconnect backoff timers to expire, which can
  // exceed the test harness timeout on Windows.
  await channel.terminate();
  exit(0);
}
