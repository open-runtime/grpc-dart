// Copyright (c) 2018, the gRPC project authors. Please see the AUTHORS file
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

import 'dart:async';

import '../../http2/transport.dart';

import '../../shared/codec.dart';
import '../../shared/codec_registry.dart';
import '../../shared/logging/logging.dart' show logGrpcEvent;
import '../../shared/message.dart';
import '../../shared/streams.dart';
import 'transport.dart';

class Http2TransportStream extends GrpcTransportStream {
  final TransportStream _transportStream;
  @override
  final Stream<GrpcMessage> incomingMessages;
  final StreamController<List<int>> _outgoingMessages = StreamController();
  final ErrorHandler _onError;
  late final StreamSubscription _outgoingSubscription;
  bool _outgoingSubscriptionCancelled = false;

  @override
  StreamSink<List<int>> get outgoingMessages => _outgoingMessages.sink;

  Http2TransportStream(
    this._transportStream,
    this._onError,
    CodecRegistry? codecRegistry,
    Codec? compression, {
    int? maxInboundMessageSize,
  }) : incomingMessages = _transportStream.incomingMessages
           .transform(GrpcHttpDecoder(forResponse: true, maxInboundMessageSize: maxInboundMessageSize))
           .transform(grpcDecompressor(codecRegistry: codecRegistry)) {
    final outSink = _transportStream.outgoingMessages;
    _outgoingSubscription = _outgoingMessages.stream
        .map((payload) => frame(payload, compression))
        .map<StreamMessage>((bytes) => DataStreamMessage(bytes))
        .handleError(_onError)
        .listen(
          // Guard against "Cannot add event after closing": the
          // transport stream's outgoing sink may be closed externally
          // (e.g. RST_STREAM received, connection teardown) while we
          // still have outgoing data queued. The direct method
          // references would throw an unguarded StateError.
          (message) {
            try {
              outSink.add(message);
            } catch (e) {
              logGrpcEvent(
                '[gRPC] HTTP/2 outgoing frame dropped'
                ' (transport sink closed): $e',
                component: 'Http2TransportStream',
                event: 'outgoing_frame_dropped',
                context: 'listen.onData',
                error: e,
              );
              _cancelOutgoingSubscription('listen.onData');
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            try {
              outSink.addError(error, stackTrace);
            } catch (e) {
              logGrpcEvent(
                '[gRPC] Failed to forward error to'
                ' HTTP/2 transport sink: $e',
                component: 'Http2TransportStream',
                event: 'outgoing_error_dropped',
                context: 'listen.onError',
                error: e,
              );
              _cancelOutgoingSubscription('listen.onError');
            }
          },
          onDone: () {
            try {
              outSink.close();
            } catch (e) {
              logGrpcEvent(
                '[gRPC] Failed to close HTTP/2'
                ' outgoing transport sink: $e',
                component: 'Http2TransportStream',
                event: 'outgoing_close_failed',
                context: 'listen.onDone',
                error: e,
              );
            }
          },
          cancelOnError: true,
        );
  }

  @override
  Future<void> terminate() async {
    if (!_outgoingSubscriptionCancelled) {
      _outgoingSubscriptionCancelled = true;
      await _outgoingSubscription.cancel();
    }
    await _outgoingMessages.close();
    _transportStream.terminate();
  }

  void _cancelOutgoingSubscription(String context) {
    if (_outgoingSubscriptionCancelled) {
      return;
    }
    _outgoingSubscriptionCancelled = true;
    unawaited(
      _outgoingSubscription.cancel().catchError((Object error) {
        logGrpcEvent(
          '[gRPC] Failed to cancel HTTP/2 outgoing subscription: $error',
          component: 'Http2TransportStream',
          event: 'outgoing_subscription_cancel_failed',
          context: context,
          error: error,
        );
      }),
    );
  }
}
