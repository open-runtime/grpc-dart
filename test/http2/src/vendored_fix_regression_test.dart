// Copyright (c) 2024, Mesh Intelligent Technologies, Inc. dba Pieces.
// All rights reserved.

import 'dart:async';

import 'package:grpc/src/http2/async_utils/async_utils.dart';
import 'package:grpc/src/http2/flowcontrol/connection_queues.dart';
import 'package:grpc/src/http2/flowcontrol/stream_queues.dart';
import 'package:grpc/src/http2/flowcontrol/window.dart';
import 'package:grpc/src/http2/flowcontrol/window_handler.dart';
import 'package:grpc/src/http2/frames/frames.dart';
import 'package:grpc/src/http2/hpack/hpack.dart';
import 'package:grpc/src/http2/settings/settings.dart';
import 'package:grpc/src/http2/transport.dart';
import 'package:test/test.dart';

void main() {
  group('Vendored http2 bug fix regressions', () {
    test('Bug #1: ConnectionMessageQueueIn.onTerminated does not crash with non-empty queue', () async {
      // Build a minimal FrameWriter so we can construct an IncomingWindowHandler.
      // The FrameWriter needs an HPackEncoder, a StreamSink<List<int>>, and ActiveSettings.
      // We must drain the outgoing stream to prevent the BufferedSink pipe from blocking.
      final outgoing = StreamController<List<int>>();
      final outSub = outgoing.stream.listen((_) {});

      final frameWriter = FrameWriter(HPackEncoder(), outgoing, ActiveSettings());

      final connectionWindow = Window();
      final windowHandler = IncomingWindowHandler.connection(frameWriter, connectionWindow);

      // Create the ConnectionMessageQueueIn.
      final queue = ConnectionMessageQueueIn(windowHandler, (void Function() fn) => fn());

      // Build a StreamMessageQueueIn for a fake stream.
      final streamWindow = Window();
      final streamWindowHandler = IncomingWindowHandler.stream(frameWriter, streamWindow, 1);
      final streamQueue = StreamMessageQueueIn(streamWindowHandler);

      // Register the stream queue — this populates _stream2messageQueue.
      queue.insertNewStreamMessageQueue(1, streamQueue);

      // Call onTerminated WITHOUT removing the stream queue first.
      // Before the fix, this would throw an AssertionError due to
      // `assert(_stream2messageQueue.isEmpty)`. After the fix, it clears
      // the map defensively.
      queue.terminate(Exception('test termination'));

      // If we reach here, the fix is working — the assertion did not fire.
      expect(queue.wasTerminated, isTrue);

      // Clean up: close the frame writer first, then cancel the drain subscription.
      await frameWriter.close();
      await outSub.cancel();
      await outgoing.close();
    });

    test('Bug #2: _pingReceived and _frameReceived are closed on terminate()', () async {
      // Create a client+server pair connected via StreamControllers.
      final clientToServer = StreamController<List<int>>();
      final serverToClient = StreamController<List<int>>();

      final client = ClientTransportConnection.viaStreams(serverToClient.stream, clientToServer.sink);

      final server = ServerTransportConnection.viaStreams(clientToServer.stream, serverToClient.sink);

      // Wait for the initial settings exchange so the connection is operational.
      await server.onInitialPeerSettingsReceived;
      await client.onInitialPeerSettingsReceived;

      // Subscribe to onPingReceived and onFrameReceived on the server side,
      // tracking whether onDone fires (which requires the controllers to be closed).
      final pingDone = Completer<void>();
      final frameDone = Completer<void>();

      server.onPingReceived.listen((_) {}, onDone: () => pingDone.complete());
      server.onFrameReceived.listen((_) {}, onDone: () => frameDone.complete());

      // Terminate the server connection. This should close both controllers.
      await server.terminate();

      // Both onDone callbacks should fire within a reasonable time.
      // Before the fix, these completers would never complete because
      // _pingReceived and _frameReceived were never closed in _terminate().
      await pingDone.future.timeout(const Duration(seconds: 5));
      await frameDone.future.timeout(const Duration(seconds: 5));

      // Clean up the client side.
      await client.terminate();
      await clientToServer.close();
      await serverToClient.close();
    });

    test('Bug #3: BufferedBytesWriter.add() after close() is silently ignored', () async {
      final sink = StreamController<List<int>>();
      final collectedData = <List<int>>[];

      sink.stream.listen((data) => collectedData.add(data));

      final writer = BufferedBytesWriter(sink);

      // Write some data before close — this should work normally.
      writer.add([10, 20, 30]);

      // Close the writer.
      await writer.close();

      // Now add data AFTER close. Before the fix, this would throw
      // StateError ("Cannot add event after closing"). After the fix,
      // the add() is silently ignored.
      writer.add([1, 2, 3]);

      // Give microtasks a chance to propagate.
      await Future<void>.delayed(Duration.zero);

      // Verify the post-close data did NOT appear on the sink.
      // Only the pre-close data [10, 20, 30] should be present.
      final allBytes = collectedData.expand((chunk) => chunk).toList();
      expect(allBytes, equals([10, 20, 30]));

      await sink.close();
    });
  });
}
