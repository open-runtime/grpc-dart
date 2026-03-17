// Copyright (c) 2024, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba., Pieces.app
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Mock-free unit tests for http2 flow control, ping handling, and connection
// message queue components. Replaces the upstream mockito-based tests with
// real objects and minimal fakes per CLAUDE.md Rule 8.

import 'dart:async';
import 'dart:typed_data';
import 'package:grpc/src/http2/flowcontrol/connection_queues.dart';
import 'package:grpc/src/http2/flowcontrol/queue_messages.dart';
import 'package:grpc/src/http2/flowcontrol/window.dart';
import 'package:grpc/src/http2/flowcontrol/window_handler.dart';
import 'package:grpc/src/http2/frames/frames.dart';
import 'package:grpc/src/http2/hpack/hpack.dart';
import 'package:grpc/src/http2/ping/ping_handler.dart';
import 'package:grpc/src/http2/settings/settings.dart';
import 'package:grpc/src/http2/sync_errors.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers: real FrameWriter backed by a StreamController sink + frame decoder
// ---------------------------------------------------------------------------

/// Creates a real [FrameWriter] that writes to an in-memory sink.
/// Returns the writer and a stream of raw bytes for inspection.
({FrameWriter writer, Stream<List<int>> rawBytes, StreamController<List<int>> controller}) _makeFrameWriter({
  ActiveSettings? settings,
}) {
  final controller = StreamController<List<int>>();
  final peerSettings = settings ?? ActiveSettings();
  final encoder = HPackEncoder();
  final writer = FrameWriter(encoder, controller, peerSettings);
  return (writer: writer, rawBytes: controller.stream, controller: controller);
}

/// Decodes a raw frame from bytes, returning the header and payload.
/// Assumes the bytes contain exactly one frame (header + payload).
({FrameHeader header, Uint8List payload}) _decodeFrameHeader(List<int> bytes) {
  assert(bytes.length >= 9, 'Frame must be at least 9 bytes (header)');
  final length = (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
  final type = bytes[3];
  final flags = bytes[4];
  final streamId = ((bytes[5] & 0x7f) << 24) | (bytes[6] << 16) | (bytes[7] << 8) | bytes[8];
  final payload = Uint8List.fromList(bytes.sublist(9, 9 + length));
  return (header: FrameHeader(length, type, flags, streamId), payload: payload);
}

/// Reads an int64 from 8 bytes at the given offset (big-endian).
int _readInt64(List<int> bytes, int offset) {
  final high = (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
  final low = (bytes[offset + 4] << 24) | (bytes[offset + 5] << 16) | (bytes[offset + 6] << 8) | bytes[offset + 7];
  return (high << 32) | (low & 0xFFFFFFFF);
}

/// Reads an int32 from 4 bytes at the given offset (big-endian).
int _readInt32(List<int> bytes, int offset) {
  return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
}

/// Creates a [PingFrame] with the given opaque data and optional ACK flag.
PingFrame _makePingFrame(int opaqueData, {bool ack = false}) {
  final flags = ack ? PingFrame.FLAG_ACK : 0;
  return PingFrame(FrameHeader(8, FrameType.PING, flags, 0), opaqueData);
}

/// Creates a [WindowUpdateFrame] for the given stream and increment.
WindowUpdateFrame _makeWindowUpdateFrame(int streamId, int increment) {
  return WindowUpdateFrame(FrameHeader(4, FrameType.WINDOW_UPDATE, 0, streamId), increment);
}

void main() {
  // =========================================================================
  // 1. PingHandler tests
  // =========================================================================
  group('PingHandler', () {
    late FrameWriter frameWriter;
    late StreamController<List<int>> sinkController;
    late StreamController<int> pingStream;
    late PingHandler handler;
    late List<List<int>> writtenBytes;

    setUp(() {
      final fw = _makeFrameWriter();
      frameWriter = fw.writer;
      sinkController = fw.controller;
      pingStream = StreamController<int>.broadcast();
      handler = PingHandler(frameWriter, pingStream);
      writtenBytes = [];
      fw.rawBytes.listen((data) => writtenBytes.add(data));
    });

    tearDown(() async {
      handler.terminate();
      await frameWriter.close();
      await sinkController.close();
      await pingStream.close();
    });

    test('ping() sends a PING frame and completes on ACK', () async {
      final pingFuture = handler.ping();

      // Allow microtasks to flush the frame write.
      await Future<void>.value();

      // Verify a PING frame was written.
      expect(writtenBytes, hasLength(1));
      final decoded = _decodeFrameHeader(writtenBytes.first);
      expect(decoded.header.type, equals(FrameType.PING));
      expect(decoded.header.flags & PingFrame.FLAG_ACK, equals(0), reason: 'Should NOT have ACK flag');
      expect(decoded.header.streamId, equals(0));

      // Extract opaque data from the written ping.
      final opaqueData = _readInt64(decoded.payload, 0);
      expect(opaqueData, equals(1), reason: 'First ping should have id 1');

      // Simulate receiving an ACK for this ping.
      handler.processPingFrame(_makePingFrame(opaqueData, ack: true));

      // The future should now complete.
      await pingFuture;
    });

    test('multiple pings get sequential IDs and complete independently', () async {
      // Send first ping and let the frame flush.
      final ping1 = handler.ping();
      await Future<void>.value();
      expect(writtenBytes, hasLength(1));
      final id1 = _readInt64(_decodeFrameHeader(writtenBytes[0]).payload, 0);
      expect(id1, equals(1));

      // Send second ping and let the frame flush.
      final ping2 = handler.ping();
      await Future<void>.value();
      expect(writtenBytes, hasLength(2));
      final id2 = _readInt64(_decodeFrameHeader(writtenBytes[1]).payload, 0);
      expect(id2, equals(2));

      // ACK ping 2 first — only ping 2 should complete.
      handler.processPingFrame(_makePingFrame(id2, ack: true));
      await ping2;

      // Ping 1 should still be pending.
      var ping1Done = false;
      unawaited(ping1.then((_) => ping1Done = true));
      await Future<void>.value();
      expect(ping1Done, isFalse);

      // Now ACK ping 1.
      handler.processPingFrame(_makePingFrame(id1, ack: true));
      await ping1;
    });

    test('processPingFrame with non-ACK triggers pingReceived callback and sends ACK reply', () async {
      final receivedPings = <int>[];
      pingStream.stream.listen((data) => receivedPings.add(data));

      // Simulate receiving a non-ACK ping from the remote peer.
      handler.processPingFrame(_makePingFrame(42));

      await Future<void>.value();

      // Should have notified listeners with the opaque data.
      expect(receivedPings, equals([42]));

      // Should have written an ACK ping reply.
      expect(writtenBytes, hasLength(1));
      final decoded = _decodeFrameHeader(writtenBytes.first);
      expect(decoded.header.type, equals(FrameType.PING));
      expect(decoded.header.flags & PingFrame.FLAG_ACK, isNonZero, reason: 'Should have ACK flag');
      final replyData = _readInt64(decoded.payload, 0);
      expect(replyData, equals(42));
    });

    test('processPingFrame with non-zero stream ID throws ProtocolException', () {
      final badFrame = PingFrame(FrameHeader(8, FrameType.PING, 0, 1 /* non-zero stream */), 99);
      expect(() => handler.processPingFrame(badFrame), throwsA(isA<ProtocolException>()));
    });

    test('processPingFrame ACK for unknown ping throws ProtocolException', () {
      // No pings were sent, so ACK for any data should fail.
      expect(() => handler.processPingFrame(_makePingFrame(999, ack: true)), throwsA(isA<ProtocolException>()));
    });

    test('terminate() errors all pending pings', () async {
      final pingFuture = handler.ping();
      await Future<void>.value();

      handler.terminate('test termination');

      await expectLater(pingFuture, throwsA(equals('test termination')));
    });

    test('ping() after terminate() throws TerminatedException', () {
      handler.terminate();
      expect(handler.ping(), throwsA(isA<TerminatedException>()));
    });

    test('processPingFrame after terminate() throws TerminatedException', () {
      handler.terminate();
      expect(() => handler.processPingFrame(_makePingFrame(1)), throwsA(isA<TerminatedException>()));
    });
  });

  // =========================================================================
  // 2. Window and WindowHandler tests
  // =========================================================================
  group('Window', () {
    test('default initial size is 65535', () {
      final w = Window();
      expect(w.size, equals(65535));
    });

    test('custom initial size', () {
      final w = Window(initialSize: 1000);
      expect(w.size, equals(1000));
    });

    test('modify increases size', () {
      final w = Window(initialSize: 100);
      w.modify(50);
      expect(w.size, equals(150));
    });

    test('modify decreases size', () {
      final w = Window(initialSize: 100);
      w.modify(-30);
      expect(w.size, equals(70));
    });

    test('modify can make size negative', () {
      final w = Window(initialSize: 10);
      w.modify(-20);
      expect(w.size, equals(-10));
    });

    test('MAX_WINDOW_SIZE is 2^31 - 1', () {
      expect(Window.MAX_WINDOW_SIZE, equals((1 << 31) - 1));
    });
  });

  group('OutgoingStreamWindowHandler', () {
    test('initial positive window marks positiveWindow as unbuffered', () {
      final handler = OutgoingStreamWindowHandler(Window(initialSize: 1000));
      expect(handler.positiveWindow.wouldBuffer, isFalse);
      expect(handler.peerWindowSize, equals(1000));
    });

    test('initial zero window marks positiveWindow as buffered', () {
      final handler = OutgoingStreamWindowHandler(Window(initialSize: 0));
      expect(handler.positiveWindow.wouldBuffer, isTrue);
    });

    test('decreaseWindow reduces peer window and marks buffered at zero', () {
      final handler = OutgoingStreamWindowHandler(Window(initialSize: 100));
      handler.decreaseWindow(60);
      expect(handler.peerWindowSize, equals(40));
      expect(handler.positiveWindow.wouldBuffer, isFalse);

      handler.decreaseWindow(40);
      expect(handler.peerWindowSize, equals(0));
      expect(handler.positiveWindow.wouldBuffer, isTrue);
    });

    test('processWindowUpdate increases peer window and fires unbuffered event', () async {
      final handler = OutgoingStreamWindowHandler(Window(initialSize: 0));
      expect(handler.positiveWindow.wouldBuffer, isTrue);

      var unbufferedFired = false;
      handler.positiveWindow.bufferEmptyEvents.listen((_) => unbufferedFired = true);

      handler.processWindowUpdate(_makeWindowUpdateFrame(1, 500));
      expect(handler.peerWindowSize, equals(500));
      expect(handler.positiveWindow.wouldBuffer, isFalse);
      expect(unbufferedFired, isTrue);
    });

    test('processWindowUpdate exceeding MAX_WINDOW_SIZE throws FlowControlException', () {
      final handler = OutgoingStreamWindowHandler(Window(initialSize: Window.MAX_WINDOW_SIZE));
      expect(() => handler.processWindowUpdate(_makeWindowUpdateFrame(1, 1)), throwsA(isA<FlowControlException>()));
    });

    test('processInitialWindowSizeSettingChange adjusts window', () {
      final handler = OutgoingStreamWindowHandler(Window(initialSize: 100));
      handler.processInitialWindowSizeSettingChange(200);
      expect(handler.peerWindowSize, equals(300));
    });

    test('processInitialWindowSizeSettingChange to negative marks buffered', () {
      final handler = OutgoingStreamWindowHandler(Window(initialSize: 100));
      handler.processInitialWindowSizeSettingChange(-200);
      expect(handler.peerWindowSize, equals(-100));
      expect(handler.positiveWindow.wouldBuffer, isTrue);
    });

    test('processInitialWindowSizeSettingChange exceeding MAX throws FlowControlException', () {
      final handler = OutgoingStreamWindowHandler(Window(initialSize: Window.MAX_WINDOW_SIZE));
      expect(() => handler.processInitialWindowSizeSettingChange(1), throwsA(isA<FlowControlException>()));
    });
  });

  group('IncomingWindowHandler', () {
    late FrameWriter frameWriter;
    late StreamController<List<int>> sinkController;
    late List<List<int>> writtenBytes;

    setUp(() {
      final fw = _makeFrameWriter();
      frameWriter = fw.writer;
      sinkController = fw.controller;
      writtenBytes = [];
      fw.rawBytes.listen((data) => writtenBytes.add(data));
    });

    tearDown(() async {
      await frameWriter.close();
      await sinkController.close();
    });

    test('gotData reduces local window', () {
      final handler = IncomingWindowHandler.connection(frameWriter, Window(initialSize: 1000));
      handler.gotData(200);
      expect(handler.localWindowSize, equals(800));
    });

    test('gotData to negative throws FlowControlException', () {
      final handler = IncomingWindowHandler.connection(frameWriter, Window(initialSize: 100));
      expect(() => handler.gotData(101), throwsA(isA<FlowControlException>()));
    });

    test('dataProcessed increases window and writes WINDOW_UPDATE frame', () async {
      final handler = IncomingWindowHandler.connection(frameWriter, Window(initialSize: 1000));
      handler.gotData(500);
      expect(handler.localWindowSize, equals(500));

      handler.dataProcessed(300);
      expect(handler.localWindowSize, equals(800));

      await Future<void>.value();

      // A WINDOW_UPDATE frame should have been written.
      expect(writtenBytes, hasLength(1));
      final decoded = _decodeFrameHeader(writtenBytes.first);
      expect(decoded.header.type, equals(FrameType.WINDOW_UPDATE));
      expect(decoded.header.streamId, equals(0));
      final increment = _readInt32(decoded.payload, 0);
      expect(increment, equals(300));
    });

    test('stream-level handler writes WINDOW_UPDATE with correct stream ID', () async {
      final handler = IncomingWindowHandler.stream(frameWriter, Window(initialSize: 1000), 5);
      handler.gotData(200);
      handler.dataProcessed(200);

      await Future<void>.value();

      expect(writtenBytes, hasLength(1));
      final decoded = _decodeFrameHeader(writtenBytes.first);
      expect(decoded.header.type, equals(FrameType.WINDOW_UPDATE));
      expect(decoded.header.streamId, equals(5));
    });
  });

  // =========================================================================
  // 3. ConnectionMessageQueueOut tests
  // =========================================================================
  group('ConnectionMessageQueueOut', () {
    late FrameWriter frameWriter;
    late StreamController<List<int>> sinkController;
    late OutgoingConnectionWindowHandler windowHandler;
    late ConnectionMessageQueueOut queue;
    late List<List<int>> writtenBytes;

    /// Creates the queue with the given initial connection window size.
    void initQueue({int windowSize = 65535}) {
      final fw = _makeFrameWriter();
      frameWriter = fw.writer;
      sinkController = fw.controller;
      writtenBytes = [];
      fw.rawBytes.listen((data) => writtenBytes.add(data));

      windowHandler = OutgoingConnectionWindowHandler(Window(initialSize: windowSize));
      queue = ConnectionMessageQueueOut(windowHandler, frameWriter);
    }

    tearDown(() async {
      queue.terminate();
      await frameWriter.close();
      await sinkController.close();
    });

    test('enqueuing HeadersMessage sends immediately (no flow control)', () async {
      initQueue(windowSize: 0); // Zero window should NOT block headers.

      final headers = [Header.ascii('content-type', 'application/grpc')];
      queue.enqueueMessage(HeadersMessage(1, headers, true));

      await Future<void>.value();

      // Headers should be sent even with zero connection window.
      expect(writtenBytes, hasLength(1));
      final decoded = _decodeFrameHeader(writtenBytes.first);
      expect(decoded.header.type, equals(FrameType.HEADERS));
      expect(decoded.header.streamId, equals(1));
    });

    test('enqueuing DataMessage with sufficient window sends immediately', () async {
      initQueue(windowSize: 65535);

      final data = List<int>.filled(100, 0x42);
      queue.enqueueMessage(DataMessage(1, data, false));

      await Future<void>.value();

      expect(writtenBytes, hasLength(1));
      final decoded = _decodeFrameHeader(writtenBytes.first);
      expect(decoded.header.type, equals(FrameType.DATA));
      expect(decoded.header.streamId, equals(1));
      expect(decoded.payload.length, equals(100));
    });

    test('enqueuing DataMessage with zero window buffers until window update', () async {
      initQueue(windowSize: 0);

      final data = List<int>.filled(50, 0xAA);
      queue.enqueueMessage(DataMessage(1, data, false));

      // Allow microtasks — data should NOT have been written.
      await Future<void>.value();
      expect(writtenBytes, isEmpty, reason: 'Data should be buffered when window is 0');
      expect(queue.pendingMessages, equals(1));

      // Now open the window — this should trigger sending.
      windowHandler.processWindowUpdate(_makeWindowUpdateFrame(0, 100));

      // The bufferEmptyEvent fires synchronously from processWindowUpdate,
      // which calls _trySendMessages. But the second batch uses Timer.run,
      // so we need to let that fire.
      await Future<void>.value();
      // Timer.run schedules on the event loop — pump it.
      await Future<void>.delayed(Duration.zero);

      expect(writtenBytes, hasLength(1));
      final decoded = _decodeFrameHeader(writtenBytes.first);
      expect(decoded.header.type, equals(FrameType.DATA));
      expect(decoded.payload.length, equals(50));
    });

    test('DataMessage larger than window is fragmented', () async {
      initQueue(windowSize: 30);

      final data = List<int>.filled(50, 0xBB);
      queue.enqueueMessage(DataMessage(1, data, true));

      await Future<void>.value();

      // First fragment: 30 bytes (window size), endStream = false.
      expect(writtenBytes, hasLength(1));
      final first = _decodeFrameHeader(writtenBytes.first);
      expect(first.header.type, equals(FrameType.DATA));
      expect(first.payload.length, equals(30));
      // endStream flag should NOT be set on the first fragment.
      expect(first.header.flags & DataFrame.FLAG_END_STREAM, equals(0));

      // Remaining 20 bytes are buffered.
      expect(queue.pendingMessages, equals(1));

      // Open window for the rest.
      writtenBytes.clear();
      windowHandler.processWindowUpdate(_makeWindowUpdateFrame(0, 50));
      await Future<void>.value();
      await Future<void>.delayed(Duration.zero);

      expect(writtenBytes, hasLength(1));
      final second = _decodeFrameHeader(writtenBytes.first);
      expect(second.header.type, equals(FrameType.DATA));
      expect(second.payload.length, equals(20));
      // endStream flag should be set on the final fragment.
      expect(second.header.flags & DataFrame.FLAG_END_STREAM, isNonZero);
    });

    test('terminate() clears pending messages', () async {
      initQueue(windowSize: 0);

      queue.enqueueMessage(DataMessage(1, [1, 2, 3], false));
      queue.enqueueMessage(DataMessage(1, [4, 5, 6], true));
      expect(queue.pendingMessages, equals(2));

      queue.terminate();
      expect(queue.pendingMessages, equals(0));
    });

    test('enqueueMessage after closing throws StateError', () {
      initQueue();
      queue.startClosing();
      expect(() => queue.enqueueMessage(DataMessage(1, [1], false)), throwsA(isA<StateError>()));
    });

    test('GoawayMessage is sent through the queue', () async {
      initQueue();

      queue.enqueueMessage(GoawayMessage(3, ErrorCode.NO_ERROR, []));
      await Future<void>.value();

      expect(writtenBytes, hasLength(1));
      final decoded = _decodeFrameHeader(writtenBytes.first);
      expect(decoded.header.type, equals(FrameType.GOAWAY));
    });

    test('ResetStreamMessage is sent through the queue', () async {
      initQueue();

      queue.enqueueMessage(ResetStreamMessage(5, ErrorCode.CANCEL));
      await Future<void>.value();

      expect(writtenBytes, hasLength(1));
      final decoded = _decodeFrameHeader(writtenBytes.first);
      expect(decoded.header.type, equals(FrameType.RST_STREAM));
      expect(decoded.header.streamId, equals(5));
    });

    test('multiple messages are sent in sequence via Timer.run batching', () async {
      initQueue(windowSize: 65535);

      queue.enqueueMessage(HeadersMessage(1, [Header.ascii('a', 'b')], false));
      queue.enqueueMessage(DataMessage(1, [1, 2, 3], false));
      queue.enqueueMessage(DataMessage(1, [4, 5, 6], true));

      // First message sent synchronously, subsequent via Timer.run.
      await Future<void>.value();
      expect(writtenBytes.length, greaterThanOrEqualTo(1));

      // Pump the event loop to let Timer.run fire for remaining messages.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      // All three messages should now be sent.
      expect(writtenBytes.length, equals(3));
      expect(_decodeFrameHeader(writtenBytes[0]).header.type, equals(FrameType.HEADERS));
      expect(_decodeFrameHeader(writtenBytes[1]).header.type, equals(FrameType.DATA));
      expect(_decodeFrameHeader(writtenBytes[2]).header.type, equals(FrameType.DATA));
    });

    test('closing with empty queue completes done future', () async {
      initQueue();
      queue.startClosing();
      // done should complete since there are no pending messages.
      await queue.done;
    });
  });
}
