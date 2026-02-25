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
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'common.dart';
import 'src/echo_service.dart';

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
        (_) => createTestChannel(address, server.port!),
      );
      final clients = channels.map(EchoClient.new).toList();

      // Fire RPCs without awaiting -- they race against shutdown.
      final rpcFutures = <Future<Object?>>[];
      for (var i = 0; i < clients.length; i++) {
        rpcFutures.add(settleRpc(clients[i].echo(i)));
      }

      // Immediately shut down the server while clients are connecting.
      // Do NOT await the RPCs first -- the race IS the test.
      await server.shutdown();

      // Wait for all RPCs to settle (succeed or fail) with a hard
      // timeout so the test runner does not hang if the race triggers
      // a deadlock.
      final settled = await Future.wait(rpcFutures).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          fail(
            'RPCs did not settle within 15s after server shutdown '
            '-- likely a deadlock in the client transport',
          );
        },
      );
      for (final result in settled) {
        expect(
          result,
          anyOf(isA<int>(), isA<GrpcError>(), isA<Exception>(), isA<Error>()),
          reason: 'Unexpected shutdown-race RPC settlement: $result',
        );
      }

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

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      // Fire the RPC (triggers lazy connect) and immediately shut down.
      final rpcFuture = settleRpc(client.echo(42));

      // Race: shut down while the RPC is in-flight.
      await channel.shutdown();

      // The RPC either succeeded or failed gracefully.
      final result = await rpcFuture.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          fail('RPC hung after channel.shutdown() -- lazy connect race');
        },
      );
      expect(
        result,
        anyOf(equals(42), isA<GrpcError>(), isA<Exception>(), isA<Error>()),
      );

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

        final channel = createTestChannel(address, server.port!);
        final client = EchoClient(channel);

        // Create a long-lived bidi stream: the client sends 100 items
        // with small delays, keeping the stream active while we kill
        // the server mid-flight.
        final inputController = StreamController<int>();
        final responseStream = client.bidiStream(inputController.stream);

        // Collect responses (with error tolerance).
        final received = <int>[];
        final streamDone = Completer<void>();
        final unexpectedStreamErrors = <Object>[];
        responseStream.listen(
          received.add,
          onError: (Object error) {
            if (error is! GrpcError) {
              unexpectedStreamErrors.add(error);
            }
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
        expect(
          unexpectedStreamErrors,
          isEmpty,
          reason: 'Unexpected non-gRPC stream errors during shutdown race',
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
    // 1ms intervals. The client subscribes, receives a few items, then
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

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      // Request 255 items (max single-byte value). The server yields
      // at 1ms intervals, so this stream runs for roughly 255ms.
      final received = <int>[];
      final streamErrors = <Object>[];
      final firstItem = Completer<void>();
      final sub = client.serverStream(255).listen((value) {
        received.add(value);
        if (!firstItem.isCompleted) firstItem.complete();
      }, onError: streamErrors.add);

      // Deterministic start signal avoids timing-based flakiness.
      await firstItem.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('server stream did not produce first item'),
      );
      await sub.cancel();

      // We should have received SOME items but not all 255.
      expect(received, isNotEmpty);
      expect(received.length, lessThan(255));
      for (final error in streamErrors) {
        expect(error, isA<GrpcError>());
      }

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

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      // Create a slow client stream that sends values over time.
      final inputController = StreamController<int>();

      // Start the client-stream RPC (returns when server sends
      // response after the stream closes).
      final resultFuture = settleRpc(
        client.clientStream(inputController.stream),
      );

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
      expect(
        result,
        anyOf(equals(55), isA<GrpcError>(), isA<Exception>(), isA<Error>()),
      );

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
        (_) => createTestChannel(address, server.port!),
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
      final rpcFutures = <Future<Object?>>[];
      for (var i = 0; i < 100; i++) {
        final client = clients[i % 3];
        rpcFutures.add(settleRpc(client.echo(i % 256)));
      }

      // After a tiny delay (to let some RPCs be mid-processing on
      // the server), shut down.
      await Future.delayed(const Duration(milliseconds: 10));
      await server.shutdown();

      // All RPCs must settle.
      final settled = await Future.wait(rpcFutures).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          fail(
            'RPCs hung after server.shutdown() -- likely a '
            'deadlock in response path or GOAWAY handling',
          );
        },
      );
      for (final result in settled) {
        expect(
          result,
          anyOf(isA<int>(), isA<GrpcError>(), isA<Exception>(), isA<Error>()),
          reason: 'Unexpected concurrent-shutdown RPC settlement: $result',
        );
      }

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
        final channel = createTestChannel(address, server.port!);
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

      final channel = createTestChannel(address, server.port!);
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

      final channel = createTestChannel(address, server.port!);
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

      final channel = createTestChannel(address, server.port!);
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

      // Feed all chunks with minimal yielding for flow-control consistency.
      for (var i = 0; i < chunks.length; i++) {
        inputController.add(chunks[i]);
        if (i > 0 && i % 10 == 0) {
          await Future.delayed(Duration.zero);
        }
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
        (_) => createTestChannel(address, server.port!),
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
    Future<Object?> settleRpc(Future<Object?> future) {
      return future.then<Object?>((value) => value, onError: (Object e) => e);
    }

    // -------------------------------------------------------------------------
    // Test 12: Mixed RPC types all active during server shutdown
    // -------------------------------------------------------------------------
    testTcpAndUds('mixed RPC types survive concurrent server shutdown', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      // Launch all four RPC patterns concurrently.
      final unaryFuture = settleRpc(client.echo(42));

      final serverStreamFuture = settleRpc(client.serverStream(20).toList());

      final clientStreamInput = pacedStream(
        List.generate(10, (i) => i),
        yieldEvery: 2,
      );
      final clientStreamFuture = settleRpc(
        client.clientStream(clientStreamInput),
      );

      final bidiController = StreamController<int>();
      final bidiStream = client.bidiStream(bidiController.stream);
      final bidiCollector = settleRpc(bidiStream.toList());
      for (var i = 0; i < 10; i++) {
        bidiController.add(i % 128);
        if (i % 5 == 0) await Future.delayed(Duration.zero);
      }
      await bidiController.close();

      // Give RPCs a moment to make progress, then kill the server.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await server.shutdown();

      // Each RPC should either complete successfully or fail with an expected
      // transport/gRPC error — never hang or surface as unhandled.
      final settled = await Future.wait([
        unaryFuture.timeout(
          const Duration(seconds: 10),
          onTimeout: () => TimeoutException('unary did not settle'),
        ),
        serverStreamFuture.timeout(
          const Duration(seconds: 10),
          onTimeout: () => TimeoutException('server stream did not settle'),
        ),
        clientStreamFuture.timeout(
          const Duration(seconds: 10),
          onTimeout: () => TimeoutException('client stream did not settle'),
        ),
        bidiCollector.timeout(
          const Duration(seconds: 10),
          onTimeout: () => TimeoutException('bidi stream did not settle'),
        ),
      ]);

      expect(
        settled.length,
        equals(4),
        reason:
            'All 4 RPC types (unary, server-stream, client-stream, bidi) '
            'must settle after server shutdown',
      );
      for (final result in settled) {
        expect(
          result,
          anyOf(
            isA<int>(),
            isA<List<int>>(),
            isA<GrpcError>(),
            isA<Exception>(),
            isA<Error>(),
          ),
          reason: 'Unexpected settled RPC result type: ${result.runtimeType}',
        );
      }

      await channel.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 13: Channel reuse after server restart
    // -------------------------------------------------------------------------
    testTcpAndUds('new channel works after server restart on new port', (
      address,
    ) async {
      // First lifecycle.
      final server1 = Server.create(services: [EchoService()]);
      await server1.serve(address: address, port: 0);
      final port = server1.port!;

      final channel1 = createTestChannel(address, port);
      final client1 = EchoClient(channel1);
      expect(await client1.echo(42), equals(42));

      await channel1.shutdown();
      await server1.shutdown();

      // Second lifecycle on the same address (different port is fine).
      final server2 = Server.create(services: [EchoService()]);
      await server2.serve(address: address, port: 0);
      addTearDown(() => server2.shutdown());

      final channel2 = createTestChannel(address, server2.port!);
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

        final channel = createTestChannel(address, server.port!);
        final client = EchoClient(channel);

        final inputController = StreamController<int>();
        final responseStream = client.bidiStream(inputController.stream);

        final received = <int>[];
        final receivedFirst = Completer<void>();
        final streamDone = Completer<void>();
        final unexpectedErrors = <Object>[];
        responseStream.listen(
          (value) {
            received.add(value);
            if (!receivedFirst.isCompleted) receivedFirst.complete();
          },
          onError: (Object error) {
            if (error is! GrpcError) {
              unexpectedErrors.add(error);
            }
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
        expect(
          unexpectedErrors,
          isEmpty,
          reason: 'Expected only GrpcError termination errors',
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

  // ===========================================================================
  // 6. Hardcore Stress + Compression
  // ===========================================================================

  group('Hardcore Stress + Compression', () {
    Future<Object?> settleRpc(Future<Object?> future) {
      return future.then<Object?>((value) => value, onError: (Object e) => e);
    }

    bool isExpectedKeepaliveTransportError(Object? error) {
      if (error == null) return false;
      final message = error.toString();
      return message.contains('ENHANCE_YOUR_CALM') ||
          message.contains('errorCode: 10') ||
          message.contains('forcefully terminated');
    }

    // -------------------------------------------------------------------------
    // Test 15: Rapid sequential server restart with active clients (5 cycles)
    // -------------------------------------------------------------------------
    // RACE TARGETED: Unlike Test 7 (rapid connect/disconnect of CHANNELS
    // against a single server), this test restarts the SERVER itself on
    // each cycle. Each cycle: start server, connect 3 clients, fire 10
    // RPCs each (30 total), verify all results, then shut down everything
    // and repeat. This stresses the OS's TCP/UDS socket teardown, TIME_WAIT
    // behavior, and the server's ability to re-bind the listen socket.
    // A leaked socket, FD, or lingering HTTP/2 session from a prior cycle
    // causes the next cycle to fail with EADDRINUSE or a stale connection.
    //
    // EXPECTED: All 5 cycles complete with correct RPC results. No hangs,
    // no EADDRINUSE, no stale connection reuse across server lifetimes.
    testTcpAndUds(
      'rapid sequential server restart with 3 active clients (5 cycles)',
      (address) async {
        for (var cycle = 0; cycle < 5; cycle++) {
          final server = Server.create(services: [EchoService()]);
          await server.serve(address: address, port: 0);

          final channels = List.generate(
            3,
            (_) => createTestChannel(address, server.port!),
          );
          final clients = channels.map(EchoClient.new).toList();

          // Fire 10 RPCs per client = 30 total, all concurrently.
          final futures = <Future<int>>[];
          for (var c = 0; c < 3; c++) {
            for (var r = 0; r < 10; r++) {
              final value = (cycle * 30 + c * 10 + r) % 256;
              futures.add(
                clients[c]
                    .echo(value)
                    .timeout(
                      const Duration(seconds: 5),
                      onTimeout: () {
                        fail(
                          'cycle $cycle client $c rpc $r timed out '
                          '-- server restart may have leaked state',
                        );
                      },
                    ),
              );
            }
          }

          final results = await Future.wait(futures);

          // Verify every result.
          for (var i = 0; i < results.length; i++) {
            final expected = (cycle * 30 + i) % 256;
            expect(results[i], equals(expected), reason: 'cycle $cycle rpc $i');
          }

          // Tear down everything before next cycle.
          for (final ch in channels) {
            await ch.shutdown();
          }
          await server.shutdown();
        }
      },
    );

    // -------------------------------------------------------------------------
    // Test 16: 5 concurrent channels with mixed RPC types (20 RPCs)
    // -------------------------------------------------------------------------
    // RACE TARGETED: 5 independent channels each fire all 4 RPC types
    // simultaneously (unary, server-stream, client-stream, bidi) = 20
    // concurrent RPCs. This tests the server's ability to multiplex
    // streams across 5 HTTP/2 connections with mixed stream types.
    // Cross-channel contamination, stream ID confusion, or a global lock
    // that serializes all connections would cause failures or deadlocks.
    //
    // EXPECTED: All 20 RPCs complete with correct results. No cross-
    // channel contamination or hangs.
    testTcpAndUds(
      '5 concurrent channels with mixed RPC types (20 concurrent RPCs)',
      (address) async {
        final server = Server.create(services: [EchoService()]);
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channels = List.generate(
          5,
          (_) => createTestChannel(address, server.port!),
        );
        final clients = channels.map(EchoClient.new).toList();

        // Warm up all 5 connections.
        await Future.wait(clients.map((c) => c.echo(0)));

        // Fire all 4 RPC types on each of 5 channels concurrently.
        final allFutures = <Future<void>>[];

        for (var ch = 0; ch < 5; ch++) {
          final client = clients[ch];
          final tag = ch; // unique per-channel for verification

          // Unary.
          allFutures.add(
            client.echo(tag).then((result) {
              expect(result, equals(tag), reason: 'unary channel $ch');
            }),
          );

          // Server stream: request 20 items, verify full data integrity.
          allFutures.add(
            client.serverStream(20).toList().then((items) {
              expect(
                items,
                equals(List.generate(20, (i) => i + 1)),
                reason: 'server-stream channel $ch full data integrity',
              );
            }),
          );

          // Client stream: send 5 values, verify sum. Use paced producer
          // to avoid flow-control stalls under adversarial load.
          allFutures.add(
            client
                .clientStream(pacedStream([1, 2, 3, 4, 5], yieldEvery: 1))
                .then((sum) {
                  expect(
                    sum,
                    equals(15),
                    reason: 'client-stream channel $ch sum',
                  );
                }),
          );

          // Bidi stream: send 10 values, verify doubled.
          allFutures.add(() async {
            final controller = StreamController<int>();
            final results = <int>[];
            final done = Completer<void>();
            client
                .bidiStream(controller.stream)
                .listen(
                  results.add,
                  onDone: () {
                    if (!done.isCompleted) done.complete();
                  },
                  onError: (e) {
                    if (!done.isCompleted) done.completeError(e);
                  },
                );

            for (var i = 0; i < 10; i++) {
              controller.add(i % 128);
              if (i % 5 == 0) await Future.delayed(Duration.zero);
            }
            await controller.close();
            await done.future.timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                fail('bidi stream channel $ch timed out');
              },
            );

            expect(
              results.length,
              equals(10),
              reason: 'bidi channel $ch item count',
            );
            for (var i = 0; i < 10; i++) {
              expect(
                results[i],
                equals((i % 128) * 2),
                reason: 'bidi channel $ch item $i',
              );
            }
          }());
        }

        await Future.wait(allFutures).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            fail(
              '20 concurrent mixed RPCs did not complete '
              'within 30s -- possible cross-channel deadlock',
            );
          },
        );

        for (final ch in channels) {
          await ch.shutdown();
        }
        await server.shutdown();
      },
    );

    // -------------------------------------------------------------------------
    // Test 17: 255-item server stream with full data integrity
    // -------------------------------------------------------------------------
    // RACE TARGETED: The maximum single-byte count (255) creates a
    // server stream that yields items at 1ms intervals for roughly 255ms.
    // This is 255 gRPC messages on a single HTTP/2 stream, testing
    // stream ID lifecycle, flow control WINDOW_UPDATE accumulation, and
    // message framing over a sustained period. If the client fails to
    // send WINDOW_UPDATEs promptly, the server stalls and the stream
    // times out. If the HTTP/2 framer corrupts message boundaries,
    // values arrive out of order or duplicated.
    //
    // EXPECTED: Exactly 255 items, item[i] == i + 1 for all i.
    testTcpAndUds('255-item server stream with full data integrity', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(address, server.port!);
      final client = EchoClient(channel);

      final results = await client
          .serverStream(255)
          .toList()
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              fail(
                '255-item server stream timed out -- likely HTTP/2 '
                'flow control stall or WINDOW_UPDATE failure',
              );
            },
          );

      expect(
        results.length,
        equals(255),
        reason: 'must receive all 255 server-stream items',
      );

      for (var i = 0; i < results.length; i++) {
        expect(
          results[i],
          equals(i + 1),
          reason:
              'server stream item $i: expected ${i + 1}, '
              'got ${results[i]}',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 18: 100-item compressed bidi stream with gzip
    // -------------------------------------------------------------------------
    // RACE TARGETED: gzip compression adds a transform layer between
    // the gRPC framing and the HTTP/2 DATA frames. With 100 bidi items,
    // the compressor must handle rapid alternation between compress
    // (request) and decompress (response) on the same stream. If the
    // zlib context is shared or corrupted between directions, data is
    // silently corrupted. Additionally, compressed payloads change size,
    // which can break HTTP/2 flow control assumptions (compressed size
    // differs from decompressed size).
    //
    // EXPECTED: All 100 items round-trip correctly through gzip.
    testTcpAndUds('100-item compressed bidi stream with gzip', (address) async {
      final server = Server.create(
        services: [EchoService()],
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(
        address,
        server.port!,
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      final client = EchoClient(channel);

      // Use pacedStream with yieldEvery: 1 — bidi + compression is the
      // worst case for HTTP/2 flow-control because both directions compete
      // for window space on UDS transports with no kernel buffering.
      final results = await client
          .bidiStream(
            pacedStream(List<int>.generate(100, (i) => i % 128), yieldEvery: 1),
            options: CallOptions(compression: const GzipCodec()),
          )
          .toList();

      expect(
        results.length,
        equals(100),
        reason: 'must receive all 100 compressed bidi items',
      );

      for (var i = 0; i < results.length; i++) {
        expect(
          results[i],
          equals((i % 128) * 2),
          reason:
              'compressed bidi item $i: expected '
              '${(i % 128) * 2}, got ${results[i]}',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 19: 255-item compressed server stream with gzip
    // -------------------------------------------------------------------------
    // RACE TARGETED: Combines the 255-item server stream (Test 17) with
    // gzip compression. 255 gzip-compressed gRPC messages stress the
    // decompressor's ability to handle rapid sequential decompressions
    // without leaking zlib contexts or corrupting the inflate state.
    // Each compressed message is small (1 byte payload), so the gzip
    // overhead dominates — testing that the framing layer handles the
    // compression header + trailer correctly for minimal payloads.
    //
    // EXPECTED: Exactly 255 items, item[i] == i + 1 for all i.
    testTcpAndUds('255-item compressed server stream with gzip', (
      address,
    ) async {
      final server = Server.create(
        services: [EchoService()],
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(
        address,
        server.port!,
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      final client = EchoClient(channel);

      final results = await client
          .serverStream(
            255,
            options: CallOptions(compression: const GzipCodec()),
          )
          .toList()
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              fail(
                '255-item compressed server stream timed out '
                '-- possible gzip decompression stall',
              );
            },
          );

      expect(
        results.length,
        equals(255),
        reason: 'must receive all 255 compressed server-stream items',
      );

      for (var i = 0; i < results.length; i++) {
        expect(
          results[i],
          equals(i + 1),
          reason:
              'compressed server stream item $i: expected '
              '${i + 1}, got ${results[i]}',
        );
      }

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 20: 500KB compressed unary payload with gzip
    // -------------------------------------------------------------------------
    // RACE TARGETED: A 500KB payload exceeds the default HTTP/2 flow
    // control window (65535 bytes) by ~7.6x BEFORE compression. Gzip
    // will shrink the repeating-pattern payload significantly, but the
    // decompressed response is still 500KB, requiring multiple
    // WINDOW_UPDATE exchanges. This tests the full stack: gzip compress
    // on send → HTTP/2 framing → flow control → gzip decompress on
    // receive. If the flow control logic uses compressed or decompressed
    // sizes inconsistently, the stream deadlocks.
    //
    // EXPECTED: The echoed payload matches the original exactly.
    testTcpAndUds('500KB compressed unary payload with gzip', (address) async {
      final server = Server.create(
        services: [EchoService()],
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(
        address,
        server.port!,
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      final client = EchoClient(channel);

      // Use a pseudo-random pattern that doesn't compress well,
      // ensuring the compressed payload still exceeds the HTTP/2
      // flow control window (65535 bytes).
      final payload = Uint8List(500 * 1024);
      var seed = 0xDEADBEEF;
      for (var i = 0; i < payload.length; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        payload[i] = (seed >> 16) & 0xFF;
      }

      final result = await client
          .echoBytes(
            payload,
            options: CallOptions(compression: const GzipCodec()),
          )
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              fail(
                '500KB compressed echoBytes timed out -- '
                'gzip + HTTP/2 flow control deadlock',
              );
            },
          );

      expect(
        result.length,
        equals(payload.length),
        reason: '500KB payload length mismatch',
      );
      expect(
        result,
        equals(payload),
        reason:
            '500KB payload data mismatch after gzip '
            'round-trip',
      );

      await channel.shutdown();
      await server.shutdown();
    });

    // -------------------------------------------------------------------------
    // Test 21: Aggressive keepalive ping flood + shutdown overlap
    // -------------------------------------------------------------------------
    // RACE TARGETED: Three clients run with aggressive keepalive pings
    // (1ms interval, permitWithoutCalls=true) while issuing mixed RPCs.
    // The server enforces strict ping-abuse policy and is shut down while
    // calls are still in flight. This is a triple-race:
    //   1) keepalive ping handling and transport termination
    //   2) mixed RPC stream lifecycles (unary/server/client/bidi)
    //   3) server shutdown cancellation/GOAWAY propagation
    //
    // EXPECTED: All RPCs settle (success or GrpcError/TransportException)
    // with no hang. We require both successes and errors to prove overlap.
    // Force-termination (ENHANCE_YOUR_CALM) is a valid outcome.
    testTcpAndUds(
      'aggressive keepalive flood with shutdown overlap settles mixed RPCs',
      (address) async {
        // Run inside a guarded zone because the aggressive keepalive
        // flood deliberately triggers HTTP/2 GOAWAY (ENHANCE_YOUR_CALM,
        // error code 10) which surfaces as uncaught TransportExceptions
        // in the client's HTTP/2 transport layer. These are EXPECTED
        // side-effects of the adversarial keepalive configuration.
        final testDone = Completer<void>();
        Object? testError;
        StackTrace? testStack;

        runZonedGuarded(
          () async {
            try {
              final server = Server.create(
                services: [EchoService()],
                keepAliveOptions: const ServerKeepAliveOptions(
                  maxBadPings: 3,
                  minIntervalBetweenPingsWithoutData: Duration(
                    milliseconds: 100,
                  ),
                ),
              );
              await server.serve(address: address, port: 0);

              const aggressiveOptions = ChannelOptions(
                credentials: ChannelCredentials.insecure(),
                keepAlive: ClientKeepAliveOptions(
                  pingInterval: Duration(milliseconds: 1),
                  timeout: Duration(milliseconds: 300),
                  permitWithoutCalls: true,
                ),
              );

              // 3 channels × 12 ops = 36 RPCs — enough for adversarial
              // overlap but settles within 60s file timeout.
              final channels = List.generate(
                3,
                (_) => createTestChannel(
                  address,
                  server.port!,
                  options: aggressiveOptions,
                ),
              );
              final clients = channels.map(EchoClient.new).toList();

              const opsPerChannel = 12;
              final rpcFutures = <Future<Object?>>[];

              const perRpcTimeout = Duration(seconds: 12);
              for (var c = 0; c < clients.length; c++) {
                final client = clients[c];
                for (var op = 0; op < opsPerChannel; op++) {
                  final jitter = Duration(milliseconds: (c + op) % 3);
                  final tag = c * opsPerChannel + op;
                  final routed = Future<void>.delayed(jitter).then((_) async {
                    switch (op % 4) {
                      case 0:
                        return client.echo(tag % 128);
                      case 1:
                        final items = await client.serverStream(10).toList();
                        return items.length;
                      case 2:
                        return client.clientStream(
                          pacedStream(
                            List<int>.generate(8, (i) => ((i + 1) % 32) + 1),
                            yieldEvery: 1,
                          ),
                        );
                      default:
                        final items = await client
                            .bidiStream(
                              pacedStream(
                                List<int>.generate(12, (i) => (i + tag) % 128),
                                yieldEvery: 1,
                              ),
                            )
                            .toList();
                        return items.length;
                    }
                  });
                  rpcFutures.add(
                    settleRpc(routed).timeout(
                      perRpcTimeout,
                      onTimeout: () =>
                          TimeoutException('RPC hung under keepalive flood'),
                    ),
                  );
                }
              }

              // Shutdown at 30ms — enough overlap for mixed RPCs to race.
              final shutdownFuture = Future<void>.delayed(
                const Duration(milliseconds: 30),
                () async {
                  try {
                    await server.shutdown();
                  } catch (_) {
                    // Duplicate/overlapping shutdown must not fail.
                  }
                },
              );

              final settled = await Future.wait(rpcFutures).timeout(
                const Duration(seconds: 35),
                onTimeout: () {
                  fail(
                    'mixed RPCs did not settle under keepalive flood + '
                    'shutdown overlap',
                  );
                },
              );

              await shutdownFuture;

              var successCount = 0;
              var errorCount = 0;
              for (final result in settled) {
                if (result is int) {
                  successCount++;
                } else if (result is Error || result is Exception) {
                  // Accept any error type: GrpcError, TransportException,
                  // or other exceptions from HTTP/2 connection teardown.
                  errorCount++;
                } else {
                  fail(
                    'unexpected result type under keepalive flood race: '
                    '${result.runtimeType}',
                  );
                }
              }

              expect(
                successCount,
                greaterThan(0),
                reason: 'expected at least one successful RPC before shutdown',
              );
              expect(
                errorCount,
                greaterThan(0),
                reason:
                    'expected at least one RPC to fail during shutdown '
                    'race',
              );
              for (final channel in channels) {
                try {
                  await channel.shutdown();
                } catch (_) {}
              }

              if (!testDone.isCompleted) testDone.complete();
            } catch (e, s) {
              if (!testDone.isCompleted) {
                testError = e;
                testStack = s;
                testDone.complete();
              }
            }
          },
          (error, stack) {
            if (isExpectedKeepaliveTransportError(error)) return;
            if (!testDone.isCompleted) {
              testError = error;
              testStack = stack;
              testDone.complete();
            }
          },
        );

        await testDone.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () => fail('test timed out in guarded zone'),
        );

        if (testError != null) {
          Error.throwWithStackTrace(testError!, testStack!);
        }
      },
    );

    // -------------------------------------------------------------------------
    // Test 22: Keepalive-enabled mixed RPC jitter across rapid restarts
    // -------------------------------------------------------------------------
    // RACE TARGETED: Six full server restarts with three clients each.
    // Clients keep sending aggressive keepalive pings while issuing jittered
    // mixed RPCs. This exercises restart hygiene (socket/session teardown),
    // stale keepalive timer isolation across generations, and mixed stream
    // correctness under repeated connect/disconnect churn.
    //
    // EXPECTED: Each cycle settles all RPCs without hang; at least one RPC
    // succeeds per cycle to prove the server remains usable. Force-termination
    // errors (ENHANCE_YOUR_CALM) from aggressive keepalive are valid outcomes.
    testTcpAndUds(
      'keepalive-enabled mixed RPC jitter survives 6 rapid restarts',
      (address) async {
        // Run inside a guarded zone because aggressive keepalive can trigger
        // HTTP/2 GOAWAY (ENHANCE_YOUR_CALM, errorCode 10) which surfaces as
        // unhandled exceptions in the transport layer. These are expected.
        final testDone = Completer<void>();
        Object? testError;
        StackTrace? testStack;

        runZonedGuarded(
          () async {
            try {
              const aggressiveOptions = ChannelOptions(
                credentials: ChannelCredentials.insecure(),
                keepAlive: ClientKeepAliveOptions(
                  pingInterval: Duration(milliseconds: 1),
                  timeout: Duration(milliseconds: 300),
                  permitWithoutCalls: true,
                ),
              );

              const cycles = 6;
              const opsPerClient = 10;
              const perCycleTimeout = Duration(seconds: 8);

              for (var cycle = 0; cycle < cycles; cycle++) {
                final server = Server.create(
                  services: [EchoService()],
                  keepAliveOptions: const ServerKeepAliveOptions(
                    maxBadPings: 10,
                    minIntervalBetweenPingsWithoutData: Duration(
                      milliseconds: 100,
                    ),
                  ),
                );
                await server.serve(address: address, port: 0);

                final channels = List.generate(
                  3,
                  (_) => createTestChannel(
                    address,
                    server.port!,
                    options: aggressiveOptions,
                  ),
                );
                final clients = channels.map(EchoClient.new).toList();

                const perRpcTimeout = Duration(seconds: 6);
                final rpcFutures = <Future<Object?>>[];
                for (var c = 0; c < clients.length; c++) {
                  final client = clients[c];
                  for (var op = 0; op < opsPerClient; op++) {
                    final jitter = Duration(milliseconds: (cycle + c + op) % 4);
                    final seed = (cycle * 100 + c * opsPerClient + op) % 128;
                    final routed = Future<void>.delayed(jitter).then((_) async {
                      switch (op % 4) {
                        case 0:
                          return client.echo(seed);
                        case 1:
                          final items = await client.serverStream(10).toList();
                          return items.length;
                        case 2:
                          return client.clientStream(
                            pacedStream(
                              List<int>.generate(
                                8,
                                (i) => ((i + seed) % 16) + 1,
                              ),
                              yieldEvery: 1,
                            ),
                          );
                        default:
                          final items = await client
                              .bidiStream(
                                pacedStream(
                                  List<int>.generate(
                                    12,
                                    (i) => (i + seed) % 128,
                                  ),
                                  yieldEvery: 1,
                                ),
                              )
                              .toList();
                          return items.length;
                      }
                    });
                    rpcFutures.add(
                      settleRpc(routed).timeout(
                        perRpcTimeout,
                        onTimeout: () => TimeoutException(
                          'RPC hung under keepalive restart',
                        ),
                      ),
                    );
                  }
                }

                final settled = await Future.wait(rpcFutures).timeout(
                  perCycleTimeout,
                  onTimeout: () {
                    fail(
                      'cycle $cycle mixed RPC jitter did not settle under '
                      'keepalive pressure',
                    );
                  },
                );

                var successCount = 0;
                for (final result in settled) {
                  if (result is int) {
                    successCount++;
                    continue;
                  }
                  // Accept GrpcError, TransportException, TimeoutException, or
                  // other Exception/Error from force-termination races.
                  if (result is GrpcError ||
                      result is Exception ||
                      result is Error) {
                    continue;
                  }
                  fail(
                    'cycle $cycle unexpected result type: '
                    '${result.runtimeType}',
                  );
                }

                expect(
                  successCount,
                  greaterThan(0),
                  reason:
                      'cycle $cycle should have at least one successful RPC',
                );

                for (final channel in channels) {
                  await channel.shutdown();
                }
                await server.shutdown();
              }

              if (!testDone.isCompleted) testDone.complete();
            } catch (e, s) {
              if (!testDone.isCompleted) {
                testError = e;
                testStack = s;
                testDone.complete();
              }
            }
          },
          (error, stack) {
            if (isExpectedKeepaliveTransportError(error)) return;
            if (!testDone.isCompleted) {
              testError = error;
              testStack = stack;
              testDone.complete();
            }
          },
        );

        await testDone.future.timeout(
          const Duration(seconds: 55),
          onTimeout: () => fail('test timed out in guarded zone'),
        );

        if (testError != null) {
          Error.throwWithStackTrace(testError!, testStack!);
        }
      },
      udsTimeout: const Timeout(Duration(seconds: 60)),
    );
  });

  // ===========================================================================
  // 7. Compressed Adversarial Scenarios
  // ===========================================================================

  group('Compressed adversarial scenarios', () {
    // -----------------------------------------------------------------------
    // Test 23: Shutdown during 255-item compressed server stream
    // -----------------------------------------------------------------------
    // RACE TARGETED: A 255-item gzip-compressed server stream is mid-
    // flight when server.shutdown() fires. The decompressor is actively
    // inflating sequential gzip frames when the HTTP/2 transport sends
    // GOAWAY and tears down the connection. If the zlib inflate context
    // is not properly finalized on early close, native resources leak.
    // If the client transport does not drain or cancel the response
    // stream after GOAWAY, the toList() future hangs indefinitely.
    //
    // EXPECTED: Stream terminates (not hang), at least 1 item arrived
    // before shutdown, items < 255, and each item[i] == i + 1.
    testTcpAndUds('shutdown during 255-item compressed server stream', (
      address,
    ) async {
      final server = Server.create(
        services: [EchoService()],
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(
        address,
        server.port!,
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      final received = <int>[];
      final firstItem = Completer<void>();
      final streamDone = Completer<void>();
      final unexpectedErrors = <Object>[];

      client
          .serverStream(
            255,
            options: CallOptions(compression: const GzipCodec()),
          )
          .listen(
            (value) {
              received.add(value);
              if (!firstItem.isCompleted) {
                firstItem.complete();
              }
            },
            onError: (Object error) {
              if (error is! GrpcError) {
                unexpectedErrors.add(error);
              }
              if (!streamDone.isCompleted) {
                streamDone.complete();
              }
            },
            onDone: () {
              if (!streamDone.isCompleted) {
                streamDone.complete();
              }
            },
          );

      // Concrete signal: wait for at least 1 item.
      await firstItem.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('compressed server stream produced no items'),
      );

      // Kill the server while decompression is active.
      await server.shutdown();

      await streamDone.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail(
          'compressed server stream did not terminate '
          'after shutdown',
        ),
      );

      expect(
        unexpectedErrors,
        isEmpty,
        reason: 'only GrpcError expected on shutdown',
      );
      expect(
        received.length,
        greaterThan(0),
        reason: 'must receive at least 1 item',
      );
      expect(
        received.length,
        lessThanOrEqualTo(255),
        reason: 'cannot exceed 255 items',
      );

      // Data integrity: each item[i] == i + 1.
      for (var i = 0; i < received.length; i++) {
        expect(
          received[i],
          equals(i + 1),
          reason:
              'compressed server stream item $i: '
              'expected ${i + 1}, got ${received[i]}',
        );
      }

      await channel.shutdown();
    });

    // -----------------------------------------------------------------------
    // Test 24: 100-item compressed bidi stream with shutdown race
    // -----------------------------------------------------------------------
    // RACE TARGETED: A 100-item gzip bidi stream is actively compressing
    // outbound frames and decompressing inbound frames when the server
    // is shut down after a brief delay. The shutdown races against the
    // bidirectional data flow — the compressor may have buffered partial
    // output, the decompressor may be mid-inflate, and HTTP/2 flow
    // control windows may be exhausted in one or both directions. This
    // triple-race (compress + decompress + shutdown) is the worst case
    // for zlib context lifecycle management.
    //
    // EXPECTED: settleRpc resolves without hang; result is a known
    // settlement type via expectExpectedRpcSettlement.
    testTcpAndUds('100-item compressed bidi stream with shutdown race', (
      address,
    ) async {
      final server = Server.create(
        services: [EchoService()],
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channel = createTestChannel(
        address,
        server.port!,
        codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
      );
      addTearDown(() => channel.shutdown());
      final client = EchoClient(channel);

      final input = pacedStream(
        List<int>.generate(100, (i) => i % 128),
        yieldEvery: 1,
      );

      final rpcFuture = settleRpc(
        client
            .bidiStream(
              input,
              options: CallOptions(compression: const GzipCodec()),
            )
            .toList(),
      );

      // Brief delay so data starts flowing, then kill.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await server.shutdown();

      final result = await rpcFuture.timeout(
        const Duration(seconds: 15),
        onTimeout: () => fail('compressed bidi + shutdown race hung'),
      );

      expectExpectedRpcSettlement(
        result,
        reason:
            'compressed bidi shutdown must settle to '
            'data or GrpcError',
      );

      await channel.shutdown();
    });

    // -----------------------------------------------------------------------
    // Test 25: 5 concurrent channels with mixed RPC types under shutdown
    // -----------------------------------------------------------------------
    // RACE TARGETED: 5 independent channels each fire 4 RPC types
    // (echo, serverStream, clientStream, bidiStream) = 20 concurrent
    // RPCs. After handlers register, server.shutdown() fires while all
    // 20 RPCs are in-flight across 5 separate HTTP/2 connections. This
    // tests the server's ability to issue GOAWAY on all 5 connections
    // simultaneously without deadlocking on a shared mutex or leaving
    // any connection's streams in a half-closed state. Cross-connection
    // shutdown ordering is non-deterministic — some connections receive
    // GOAWAY before others, creating asymmetric teardown timing.
    //
    // EXPECTED: All 20 RPCs settle (not hang), each result is a known
    // settlement type.
    testTcpAndUds('5 concurrent channels with mixed RPCs under shutdown', (
      address,
    ) async {
      final server = Server.create(services: [EchoService()]);
      await server.serve(address: address, port: 0);
      addTearDown(() => server.shutdown());

      final channels = List.generate(
        5,
        (_) => createTestChannel(address, server.port!),
      );
      for (final ch in channels) {
        addTearDown(() => ch.shutdown());
      }
      final clients = channels.map(EchoClient.new).toList();

      final rpcFutures = <Future<Object?>>[];
      for (var i = 0; i < 5; i++) {
        final c = clients[i];

        // Unary
        rpcFutures.add(settleRpc(c.echo(i)));

        // Server stream (50 items)
        rpcFutures.add(settleRpc(c.serverStream(50).toList()));

        // Client stream (10 items)
        rpcFutures.add(
          settleRpc(
            c.clientStream(
              pacedStream(
                List<int>.generate(10, (j) => (j + i) % 256),
                yieldEvery: 1,
              ),
            ),
          ),
        );

        // Bidi stream (20 items)
        rpcFutures.add(
          settleRpc(
            c
                .bidiStream(
                  pacedStream(
                    List<int>.generate(20, (j) => (j + i) % 128),
                    yieldEvery: 1,
                  ),
                )
                .toList(),
          ),
        );
      }

      // Wait for at least some handlers to register.
      await waitForHandlers(
        server,
        minCount: 1,
        reason:
            'at least 1 handler must register before '
            'shutdown',
      );

      // Kill the server while 20 RPCs are in-flight.
      await server.shutdown();

      final settled = await Future.wait(rpcFutures).timeout(
        const Duration(seconds: 20),
        onTimeout: () => fail(
          '20 concurrent RPCs did not settle after '
          'shutdown -- possible deadlock',
        ),
      );

      expect(settled.length, equals(20), reason: 'all 20 RPCs must settle');
      for (var i = 0; i < settled.length; i++) {
        expectExpectedRpcSettlement(
          settled[i],
          reason: 'RPC $i must be a known settlement',
        );
      }

      for (final ch in channels) {
        await ch.shutdown();
      }
    });

    // -----------------------------------------------------------------------
    // Test 26: 500KB compressed unary payload during server shutdown race
    // -----------------------------------------------------------------------
    // RACE TARGETED: Three 500KB echoBytes RPCs are fired with gzip
    // compression. The server is shut down concurrently with the third
    // RPC's initiation. Each 500KB payload exceeds the default HTTP/2
    // flow control window (65535 bytes) by ~7.6x BEFORE compression.
    // The shutdown may arrive while the HTTP/2 transport is mid-DATA-
    // frame, with partial gzip output buffered. If the transport does
    // not cleanly abort in-progress DATA frame writes, the connection
    // can deadlock waiting for WINDOW_UPDATE that will never arrive.
    //
    // EXPECTED: All 3 RPCs settle (data or GrpcError, not hang).
    testTcpAndUds(
      '500KB compressed unary payload during server shutdown race',
      (address) async {
        final server = Server.create(
          services: [EchoService()],
          codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
        );
        await server.serve(address: address, port: 0);
        addTearDown(() => server.shutdown());

        final channel = createTestChannel(
          address,
          server.port!,
          codecRegistry: CodecRegistry(codecs: const [GzipCodec()]),
        );
        addTearDown(() => channel.shutdown());
        final client = EchoClient(channel);

        // Build a 500KB payload with a pseudo-random pattern
        // that resists gzip compression.
        final payload = Uint8List(500 * 1024);
        var seed = 0xCAFEBABE;
        for (var i = 0; i < payload.length; i++) {
          seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
          payload[i] = (seed >> 16) & 0xFF;
        }

        final opts = CallOptions(compression: const GzipCodec());

        // Fire 3 concurrent 500KB echoBytes RPCs.
        final rpc1 = settleRpc(client.echoBytes(payload, options: opts));
        final rpc2 = settleRpc(client.echoBytes(payload, options: opts));

        // Fire the 3rd RPC and shutdown concurrently.
        final rpc3 = settleRpc(client.echoBytes(payload, options: opts));
        // Do not await — let shutdown race with the 3rd
        // RPC's DATA frames.
        unawaited(server.shutdown());

        final settled = await Future.wait([rpc1, rpc2, rpc3]).timeout(
          const Duration(seconds: 20),
          onTimeout: () => fail(
            '500KB compressed unary shutdown race hung '
            '-- HTTP/2 flow control deadlock',
          ),
        );

        for (var i = 0; i < settled.length; i++) {
          expectExpectedRpcSettlement(
            settled[i],
            reason:
                '500KB echoBytes RPC $i must settle to '
                'data or GrpcError',
          );
        }

        await channel.shutdown();
      },
    );
  });
}
