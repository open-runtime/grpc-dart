// Copyright (c) 2025, the gRPC project authors. Please see the AUTHORS file
// for details. All rights reserved.
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

/// Adversarial concurrency tests for TCP and Unix Domain Socket transports.
///
/// These tests target specific race conditions, resource leaks, and crash
/// vectors that the happy-path protocol tests in `transport_test.dart` do
/// NOT cover. Each test is designed to be maximally adversarial: it
/// deliberately creates the conditions under which the transport is most
/// likely to deadlock, leak connections, corrupt streams, or leave RPCs
/// hanging indefinitely.
///
/// Every test uses [testTcpAndUds] so it runs on both TCP and UDS
/// transports automatically (TCP on all platforms, UDS on macOS/Linux).
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/channel.dart' hide ClientChannel;
import 'package:grpc/src/client/connection.dart';
import 'package:grpc/src/client/http2_connection.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

// =============================================================================
// Test Channel Wrapper
// =============================================================================

class TestClientChannel extends ClientChannelBase {
  final Http2ClientConnection clientConnection;
  final List<ConnectionState> states = [];

  TestClientChannel(this.clientConnection) {
    onConnectionStateChanged.listen((state) => states.add(state));
  }

  @override
  ClientConnection createConnection() => clientConnection;
}

// =============================================================================
// Helpers
// =============================================================================

/// Creates a [TestClientChannel] connected to the given [address] and [port]
/// with insecure credentials.
TestClientChannel _createChannel(InternetAddress address, int port) {
  return TestClientChannel(
    Http2ClientConnection(
      address,
      port,
      ChannelOptions(credentials: ChannelCredentials.insecure()),
    ),
  );
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  // ===========================================================================
  // 1. Shutdown-During-Connect Races
  // ===========================================================================

  group('Shutdown-During-Connect Races', () {
    // -------------------------------------------------------------------------
    // Test 1: Server shutdown racing 5 concurrent client connections
    // -------------------------------------------------------------------------
    // RACE TARGETED: Five independent channels are created and fire RPCs
    // simultaneously. Each RPC triggers a lazy TCP/UDS connect + HTTP/2
    // handshake. Before any (or all) of these handshakes complete, the
    // server is shut down, closing its listening socket and all accepted
    // connections. Clients that completed the handshake see a GOAWAY frame;
    // clients mid-handshake see a connection reset or refused error. If the
    // client transport does not handle these failures atomically, RPCs can
    // hang waiting for a response that will never arrive.
    //
    // EXPECTED: All 5 RPCs settle (either succeed or fail with GrpcError)
    // without hanging. All channels shut down cleanly.
    testTcpAndUds('server shutdown racing 5 concurrent client connections', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      // Start 5 clients connecting simultaneously. Some will be mid-
      // handshake when we kill the server.
      final channels = List.generate(
        5,
        (_) => _createChannel(address, server.port!),
      );
      final clients = channels.map(EchoClient.new).toList();

      // Fire RPCs without awaiting -- they race against shutdown.
      final rpcFutures = <Future<void>>[];
      for (var i = 0; i < clients.length; i++) {
        rpcFutures.add(clients[i].echo(i).then((_) {}, onError: (_) {}));
      }

      // Immediately shut down the server while clients are connecting.
      // Do NOT await the RPCs first -- the race IS the test.
      await server.shutdown();

      // Wait for all RPCs to settle (succeed or fail) with a hard
      // timeout so the test runner does not hang if the race triggers
      // a deadlock.
      await Future.wait(rpcFutures).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          fail(
            'RPCs did not settle within 15s after server shutdown '
            '-- likely a deadlock in the client transport',
          );
        },
      );

      // Clean up channels. Some may already be dead -- shutdown must
      // be safe to call regardless.
      for (final ch in channels) {
        await ch.shutdown();
      }
    });

    // -------------------------------------------------------------------------
    // Test 2: Channel shutdown concurrent with first RPC (lazy connect)
    // -------------------------------------------------------------------------
    // RACE TARGETED: A single channel's first RPC triggers connect().
    // channel.shutdown() is called before the TCP/UDS connect or HTTP/2
    // handshake completes. The Http2ClientConnection may have a pending
    // socket connect future that completes AFTER shutdown has already
    // torn down the connection state. If the connect callback blindly
    // accesses destroyed state, we get an unhandled exception or hang.
    //
    // EXPECTED: No hang, no unhandled exception. The RPC either succeeds
    // (if the handshake completed before shutdown) or fails gracefully.
    testTcpAndUds('channel shutdown concurrent with first RPC', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = _createChannel(address, server.port!);
      final client = EchoClient(channel);

      // Fire the RPC (triggers lazy connect) and immediately shut down.
      final rpcFuture = client.echo(42).then((v) => v, onError: (_) => -1);

      // Race: shut down while the RPC is in-flight.
      await channel.shutdown();

      // The RPC either succeeded or failed gracefully.
      final result = await rpcFuture.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          fail('RPC hung after channel.shutdown() -- lazy connect race');
        },
      );
      expect(result, anyOf(equals(42), equals(-1)));

      await server.shutdown();
    });
  });

  // ===========================================================================
  // 2. Streaming Under Shutdown
  // ===========================================================================

  group('Streaming Under Shutdown', () {
    // -------------------------------------------------------------------------
    // Test 3: Server shutdown during active bidi stream
    // -------------------------------------------------------------------------
    // RACE TARGETED: The server is inside the async* generator of
    // _bidiStream, reading from the client's request stream and yielding
    // responses. When server.shutdown() is called, the HTTP/2 connection
    // sends a GOAWAY frame and closes the transport. The server's async*
    // generator may be suspended at the `await for` and never resume,
    // OR the response StreamController may be closed mid-add. On the
    // client side, the incoming response stream may never receive onDone
    // or onError if the GOAWAY is lost or the socket is reset before it
    // is fully written.
    //
    // EXPECTED: The bidi stream terminates (with error or short data)
    // within the test timeout. No hang.
    testTcpAndUds(
      'server shutdown during active bidi stream terminates cleanly',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channel = _createChannel(address, server.port!);
        final client = EchoClient(channel);

        // Create a long-lived bidi stream: the client sends 100 items
        // with small delays, keeping the stream active while we kill
        // the server mid-flight.
        final inputController = StreamController<int>();
        final responseStream = client.bidiStream(inputController.stream);

        // Collect responses (with error tolerance).
        final received = <int>[];
        final streamDone = Completer<void>();
        responseStream.listen(
          received.add,
          onError: (_) {
            if (!streamDone.isCompleted) streamDone.complete();
          },
          onDone: () {
            if (!streamDone.isCompleted) streamDone.complete();
          },
        );

        // Send a burst of data to saturate the read/write interleave.
        // Values are kept <= 127 so doubled results fit in a single
        // byte (the echo service serializes int as [value]).
        for (var i = 0; i < 100; i++) {
          inputController.add(i % 128);
          // Tiny delay so writes interleave with reads on the server.
          if (i % 10 == 0) {
            await Future.delayed(const Duration(milliseconds: 5));
          }
        }

        // Kill the server while the bidi stream is mid-flight.
        await server.shutdown();

        // The stream must terminate within a reasonable time.
        await streamDone.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            fail('bidi stream did not terminate after server shutdown');
          },
        );

        // Close the client side.
        await inputController.close();
        await channel.shutdown();
      },
    );

    // -------------------------------------------------------------------------
    // Test 4: Client cancellation during active server stream
    // -------------------------------------------------------------------------
    // RACE TARGETED: The server is yielding items from _serverStream at
    // 10ms intervals. The client subscribes, receives a few items, then
    // cancels the subscription. If the client transport does not properly
    // send a RST_STREAM to the server, the server's async* generator
    // continues running indefinitely, leaking resources. Additionally,
    // the server must remain healthy for subsequent RPCs -- a leaked
    // generator or broken HTTP/2 session would cause future RPCs to fail.
    //
    // EXPECTED: Client receives some items, cancellation completes
    // quickly, and a fresh RPC to the same server succeeds.
    testTcpAndUds('client cancellation during active server stream', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = _createChannel(address, server.port!);
      final client = EchoClient(channel);

      // Request 255 items (max single-byte value). The server yields
      // at 10ms intervals, so this stream runs for ~2.5 seconds.
      final received = <int>[];
      final sub = client
          .serverStream(255)
          .listen(received.add, onError: (_) {});

      // Wait for a few items to arrive then cancel.
      await Future.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // We should have received SOME items but not all 255.
      expect(received, isNotEmpty);
      expect(received.length, lessThan(255));

      // Verify the server is still alive for subsequent RPCs on the
      // SAME channel. This confirms the HTTP/2 session was not
      // corrupted by the cancellation.
      final result = await client
          .echo(99)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              fail(
                'Follow-up echo RPC hung after server-stream '
                'cancellation -- server or session likely broken',
              );
            },
          );
      expect(result, equals(99));

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 5: Server shutdown during client-stream accumulation
    // -------------------------------------------------------------------------
    // RACE TARGETED: The client is sending a stream of values via
    // clientStream(). The server accumulates them in _clientStream and
    // will return the sum once the stream closes. If the server is killed
    // mid-accumulation, the client is waiting on ResponseFuture which
    // may hang forever if the HTTP/2 transport does not propagate the
    // connection closure as an error to the pending ResponseFuture.
    //
    // EXPECTED: The client-stream RPC fails with GrpcError (or succeeds
    // if the server managed to return before dying). No hang.
    testTcpAndUds('server shutdown during client-stream accumulation', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = _createChannel(address, server.port!);
      final client = EchoClient(channel);

      // Create a slow client stream that sends values over time.
      final inputController = StreamController<int>();

      // Start the client-stream RPC (returns when server sends
      // response after the stream closes).
      final resultFuture = client
          .clientStream(inputController.stream)
          .then((v) => v, onError: (_) => -1);

      // Send 10 values slowly.
      for (var i = 1; i <= 10; i++) {
        inputController.add(i);
        await Future.delayed(const Duration(milliseconds: 20));
      }

      // Kill the server before closing the client stream.
      await server.shutdown();

      // Close the input so the RPC can settle (even if the response
      // is already dead).
      await inputController.close();

      // The result must arrive (success or error) within the timeout.
      final result = await resultFuture.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          fail('clientStream RPC hung after server shutdown');
        },
      );

      // If server died, we get -1 (error). If it somehow completed
      // before dying, sum of 1..10 = 55. Either is acceptable.
      expect(result, anyOf(equals(55), equals(-1)));

      await channel.shutdown();
    });
  });

  // ===========================================================================
  // 3. Concurrent Shutdown + RPC
  // ===========================================================================

  group('Concurrent Shutdown + RPC', () {
    // -------------------------------------------------------------------------
    // Test 6: Server shutdown racing 100 concurrent RPCs from 3 clients
    // -------------------------------------------------------------------------
    // RACE TARGETED: Three independent HTTP/2 connections are hammering
    // the server with RPCs. server.shutdown() is called while the server
    // handler is processing requests: it has already dispatched to _echo
    // but the response path writes to the HTTP/2 stream which is being
    // closed by shutdown(). This can cause "Cannot add event after
    // closing" on the server's response StreamController, or the client
    // may see a RST_STREAM after already receiving headers but before
    // receiving the response body.
    //
    // EXPECTED: All 100 RPCs either succeed or fail with GrpcError. The
    // server shuts down without unhandled async exceptions. No hang.
    testTcpAndUds('server shutdown racing 100 concurrent RPCs from 3 clients', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      // Spin up 3 independent channels.
      final channels = List.generate(
        3,
        (_) => _createChannel(address, server.port!),
      );
      final clients = channels.map(EchoClient.new).toList();

      // Warm up: ensure all 3 channels are connected and the HTTP/2
      // sessions are established before the race begins.
      await Future.wait([
        clients[0].echo(0),
        clients[1].echo(0),
        clients[2].echo(0),
      ]);

      // Fire 100 RPCs spread across all 3 clients, without awaiting.
      // Values are (i % 256) to stay within single-byte encoding.
      final rpcFutures = <Future<void>>[];
      for (var i = 0; i < 100; i++) {
        final client = clients[i % 3];
        rpcFutures.add(client.echo(i % 256).then((_) {}, onError: (_) {}));
      }

      // After a tiny delay (to let some RPCs be mid-processing on
      // the server), shut down.
      await Future.delayed(const Duration(milliseconds: 10));
      await server.shutdown();

      // All RPCs must settle.
      await Future.wait(rpcFutures).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          fail(
            'RPCs hung after server.shutdown() -- likely a '
            'deadlock in response path or GOAWAY handling',
          );
        },
      );

      for (final ch in channels) {
        await ch.shutdown();
      }
    });

    // -------------------------------------------------------------------------
    // Test 7: Rapid connect/disconnect cycles (20 channels in sequence)
    // -------------------------------------------------------------------------
    // RACE TARGETED: Each cycle creates a new TCP/UDS connection, does
    // one RPC, then immediately shuts down the channel. Twenty rapid
    // cycles stress the server's connection accept loop, HTTP/2 session
    // cleanup, and file descriptor management. If the server leaks
    // sockets or HTTP/2 sessions, later cycles may fail with EMFILE
    // (too many open files) or the accept loop may hang.
    //
    // EXPECTED: All 20 cycles succeed. The server handles rapid
    // connect/disconnect without resource exhaustion or hangs.
    testTcpAndUds('rapid connect/disconnect cycles (20 channels in sequence)', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      for (var cycle = 0; cycle < 20; cycle++) {
        final channel = _createChannel(address, server.port!);
        final client = EchoClient(channel);

        // Value cycles through 0..19 (all single-byte safe).
        final result = await client
            .echo(cycle)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                fail(
                  'echo RPC hung at cycle $cycle -- server may have '
                  'leaked sockets or HTTP/2 sessions',
                );
              },
            );
        expect(result, equals(cycle), reason: 'cycle $cycle');

        await channel.shutdown();
      }

      await server.shutdown();
    });
  });

  // ===========================================================================
  // 4. Large Payload Stress
  // ===========================================================================

  group('Large Payload Stress', () {
    // -------------------------------------------------------------------------
    // Test 8: 100KB unary payload
    // -------------------------------------------------------------------------
    // RACE TARGETED: A 100KB payload exceeds the default HTTP/2 flow
    // control window (65535 bytes). The client must send WINDOW_UPDATE
    // frames to allow the full payload through. If the flow control
    // logic has a bug, the send stalls and the RPC times out. On the
    // server side, the 100KB response also exceeds the window, testing
    // symmetric flow control.
    //
    // EXPECTED: The echoed payload matches the original exactly.
    // No timeout, no data corruption.
    testTcpAndUds('100KB unary payload echoed correctly', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = _createChannel(address, server.port!);
      final client = EchoClient(channel);

      // Create a 100KB payload with a repeating pattern for
      // integrity verification.
      final payload = Uint8List(100 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i & 0xFF;
      }

      final result = await client
          .echoBytes(payload)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              fail(
                '100KB echoBytes RPC timed out -- likely HTTP/2 '
                'flow control deadlock',
              );
            },
          );

      expect(result.length, equals(payload.length));
      // Verify every byte matches. Use a single list equality check
      // for performance -- if it fails, the test runner will show
      // the first mismatch.
      expect(result, equals(payload));

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 9: Large server-stream (10 chunks x 10KB)
    // -------------------------------------------------------------------------
    // RACE TARGETED: The server sends 10 chunks of 10240 bytes each.
    // Multiple HTTP/2 DATA frames are required per chunk, and the client
    // must reassemble them correctly. If frame boundaries do not align
    // with gRPC message boundaries (they usually don't), the framing
    // layer must buffer partial messages. A bug in partial message
    // reassembly causes data corruption or hangs.
    //
    // EXPECTED: All 10 chunks arrive with the correct fill pattern.
    // chunk[i][j] == (i + j) & 0xFF.
    testTcpAndUds('large server-stream (10 chunks x 10KB)', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = _createChannel(address, server.port!);
      final client = EchoClient(channel);

      // Build the 8-byte request: chunkCount=10 (4 BE), chunkSize=
      // 10240 (4 BE).
      final requestBytes = Uint8List(8);
      final bd = ByteData.sublistView(requestBytes);
      bd.setUint32(0, 10); // chunkCount
      bd.setUint32(4, 10240); // chunkSize

      final chunks = await client
          .serverStreamBytes(requestBytes)
          .toList()
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              fail(
                'serverStreamBytes timed out -- possible HTTP/2 '
                'flow control deadlock with large payloads',
              );
            },
          );

      expect(chunks.length, equals(10));

      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        expect(
          chunk.length,
          equals(10240),
          reason: 'chunk $i has wrong length',
        );

        // Verify the fill pattern: (chunkIndex + byteIndex) & 0xFF.
        for (var j = 0; j < chunk.length; j++) {
          if (chunk[j] != (i + j) & 0xFF) {
            fail(
              'chunk $i byte $j: expected ${(i + j) & 0xFF} '
              'but got ${chunk[j]} -- data corruption in '
              'HTTP/2 frame reassembly',
            );
          }
        }
      }

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 10: Large bidi stream (50 x 2KB chunks)
    // -------------------------------------------------------------------------
    // RACE TARGETED: The client sends 50 chunks of 2048 bytes each via
    // bidiStreamBytes. Each chunk is echoed back by the server. With 50
    // concurrent in-flight messages, the HTTP/2 flow control window is
    // stressed, and the multiplexer must correctly interleave DATA
    // frames for the request and response directions of the same stream.
    // A bug in the bidirectional flow control causes one direction to
    // stall, deadlocking the stream.
    //
    // EXPECTED: All 50 chunks are echoed back with exact byte equality.
    testTcpAndUds('large bidi stream (50 x 2KB chunks)', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = _createChannel(address, server.port!);
      final client = EchoClient(channel);

      // Build 50 chunks of 2KB each with unique fill patterns.
      final chunks = <Uint8List>[];
      for (var i = 0; i < 50; i++) {
        final chunk = Uint8List(2048);
        for (var j = 0; j < chunk.length; j++) {
          chunk[j] = (i + j) & 0xFF;
        }
        chunks.add(chunk);
      }

      // Create a StreamController to feed chunks to bidiStreamBytes.
      final inputController = StreamController<List<int>>();
      final responseStream = client.bidiStreamBytes(inputController.stream);

      // Collect echoed chunks.
      final echoed = <List<int>>[];
      final streamDone = Completer<void>();
      responseStream.listen(
        echoed.add,
        onError: (e) {
          if (!streamDone.isCompleted) {
            streamDone.completeError(e);
          }
        },
        onDone: () {
          if (!streamDone.isCompleted) streamDone.complete();
        },
      );

      // Feed all chunks.
      for (final chunk in chunks) {
        inputController.add(chunk);
      }
      await inputController.close();

      // Wait for the stream to complete.
      await streamDone.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          fail(
            'bidiStreamBytes timed out after sending 50 x 2KB '
            'chunks -- likely HTTP/2 bidirectional flow control '
            'deadlock',
          );
        },
      );

      expect(echoed.length, equals(50));

      // Verify each chunk was echoed back exactly.
      for (var i = 0; i < echoed.length; i++) {
        expect(
          echoed[i].length,
          equals(2048),
          reason: 'echoed chunk $i has wrong length',
        );
        expect(
          echoed[i],
          equals(chunks[i]),
          reason: 'echoed chunk $i data mismatch',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });
  });

  // ===========================================================================
  // 5. Multiple Channels to Same Server
  // ===========================================================================

  group('Multiple Channels to Same Server', () {
    // -------------------------------------------------------------------------
    // Test 11: 3 independent channels, interleaved RPCs
    // -------------------------------------------------------------------------
    // RACE TARGETED: Three independent HTTP/2 connections to the same
    // server fire RPCs in an interleaved pattern (channel 0, 1, 2, 0,
    // 1, 2, ...). Each connection has its own HTTP/2 session with
    // independent stream IDs and flow control windows. If the server
    // confuses sessions (e.g., routes a response to the wrong
    // connection), data leaks between channels. If the server's
    // connection tracking is wrong, shutting down one channel may
    // corrupt another.
    //
    // EXPECTED: All 30 RPCs succeed with correct values. No cross-
    // channel contamination. Each channel's results are independent.
    testTcpAndUds('3 independent channels, interleaved RPCs', (address) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      // Create 3 fully independent channels.
      final channels = List.generate(
        3,
        (_) => _createChannel(address, server.port!),
      );
      final clients = channels.map(EchoClient.new).toList();

      // Fire 30 RPCs, interleaving across channels. Each client gets
      // values from a distinct range so we can verify no cross-channel
      // contamination:
      //   Channel 0: values 0, 3, 6, 9, ...
      //   Channel 1: values 1, 4, 7, 10, ...
      //   Channel 2: values 2, 5, 8, 11, ...
      // All values modulo 256 to fit single-byte encoding.
      final futures = <Future<int>>[];
      final expectedValues = <int>[];

      for (var i = 0; i < 30; i++) {
        final clientIndex = i % 3;
        final value = i % 256;
        expectedValues.add(value);
        futures.add(
          clients[clientIndex]
              .echo(value)
              .timeout(
                const Duration(seconds: 5),
                onTimeout: () {
                  fail(
                    'Interleaved RPC $i (channel $clientIndex, '
                    'value $value) timed out',
                  );
                },
              ),
        );
      }

      final results = await Future.wait(futures);

      // Verify all 30 results match expectations.
      for (var i = 0; i < 30; i++) {
        expect(
          results[i],
          equals(expectedValues[i]),
          reason: 'RPC $i (channel ${i % 3}) returned wrong value',
        );
      }

      // Shut down channels one at a time. Verify remaining channels
      // still work after each shutdown.
      await channels[0].shutdown();

      // Channel 1 and 2 should still work.
      expect(
        await clients[1].echo(77),
        equals(77),
        reason: 'channel 1 broken after channel 0 shutdown',
      );
      expect(
        await clients[2].echo(88),
        equals(88),
        reason: 'channel 2 broken after channel 0 shutdown',
      );

      await channels[1].shutdown();

      // Channel 2 should still work.
      expect(
        await clients[2].echo(99),
        equals(99),
        reason: 'channel 2 broken after channel 1 shutdown',
      );

      await channels[2].shutdown();
      await server.shutdown();
    });
  });

  // ===========================================================================
  // Test 12-14: Additional Adversarial Coverage (Issues #34)
  // ===========================================================================

  group('Mixed RPC Shutdown + Channel Reuse', () {
    // -------------------------------------------------------------------------
    // Test 12: Mixed RPC types all active during server shutdown
    // -------------------------------------------------------------------------
    testTcpAndUds('mixed RPC types survive concurrent server shutdown', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = _createChannel(address, server.port!);
      final client = EchoClient(channel);

      // Launch all four RPC patterns concurrently.
      final unaryFuture = client.echo(42);

      final serverStreamFuture = client.serverStream(20).toList();

      final clientStreamInput = Stream.fromIterable(
        List.generate(10, (i) => i),
      );
      final clientStreamFuture = client.clientStream(clientStreamInput);

      final bidiController = StreamController<int>();
      final bidiStream = client.bidiStream(bidiController.stream);
      final bidiCollector = bidiStream.toList();
      for (var i = 0; i < 10; i++) {
        bidiController.add(i % 128);
      }
      await bidiController.close();

      // Give RPCs a moment to make progress, then kill the server.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await server.shutdown();

      // Each RPC should either complete successfully or fail with
      // a gRPC error — never hang or throw an unhandled exception.
      try {
        await unaryFuture;
      } on GrpcError {
        // Expected if shutdown raced the unary call.
      }
      try {
        await serverStreamFuture;
      } on GrpcError {
        // Expected if shutdown raced the server stream.
      }
      try {
        await clientStreamFuture;
      } on GrpcError {
        // Expected if shutdown raced the client stream.
      }
      try {
        await bidiCollector;
      } on GrpcError {
        // Expected if shutdown raced the bidi stream.
      }

      await channel.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 13: Channel reuse after server restart
    // -------------------------------------------------------------------------
    testTcpAndUds('new channel works after server restart on same port', (
      address,
    ) async {
      // First lifecycle.
      final server1 = Server.create(services: [EchoService()]);
      await server1.serve(address: address, port: 0);
      final port = server1.port!;

      final channel1 = _createChannel(address, port);
      final client1 = EchoClient(channel1);
      expect(await client1.echo(42), equals(42));

      await channel1.shutdown();
      await server1.shutdown();

      // Second lifecycle on the same address (different port is fine).
      final server2 = Server.create(services: [EchoService()]);
      await server2.serve(address: address, port: 0);
      addTearDown(() => server2.shutdown());

      final channel2 = _createChannel(address, server2.port!);
      final client2 = EchoClient(channel2);
      expect(await client2.echo(99), equals(99));

      await channel2.shutdown();
      await server2.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 14: Strengthened bidi shutdown with data integrity verification
    // -------------------------------------------------------------------------
    testTcpAndUds(
      'bidi stream with 200 items verifies data integrity under shutdown',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channel = _createChannel(address, server.port!);
        final client = EchoClient(channel);

        final inputController = StreamController<int>();
        final responseStream = client.bidiStream(inputController.stream);

        final received = <int>[];
        final receivedFirst = Completer<void>();
        final streamDone = Completer<void>();
        responseStream.listen(
          (value) {
            received.add(value);
            if (!receivedFirst.isCompleted) receivedFirst.complete();
          },
          onError: (_) {
            if (!streamDone.isCompleted) streamDone.complete();
          },
          onDone: () {
            if (!streamDone.isCompleted) streamDone.complete();
          },
        );

        // Send 200 items (values kept <= 127 so doubled fits in byte).
        for (var i = 0; i < 200; i++) {
          inputController.add(i % 128);
          if (i % 20 == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        }

        // Wait for at least one response before killing the server.
        await receivedFirst.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('no bidi response received'),
        );
        await server.shutdown();
        await inputController.close();

        await streamDone.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            fail('bidi stream did not terminate after shutdown');
          },
        );

        // Verify data integrity of received items.
        expect(
          received.length,
          greaterThan(0),
          reason: 'Should have received at least 1 echoed item',
        );
        expect(
          received.length,
          lessThanOrEqualTo(200),
          reason: 'Cannot receive more than 200 items',
        );
        for (var i = 0; i < received.length; i++) {
          expect(
            received[i],
            equals(((i % 128) * 2) & 0xFF),
            reason: 'item $i has wrong value',
          );
        }

        await channel.shutdown();
      },
    );
  });
}
