// Copyright (c) 2017, the gRPC project authors. Please see the AUTHORS file
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
import 'dart:convert';

import 'package:http2/transport.dart';

import '../shared/codec.dart';
import '../shared/codec_registry.dart';
import '../shared/io_bits/io_bits.dart' show InternetAddress, X509Certificate;
import '../shared/logging/logging.dart' show logGrpcEvent;
import '../shared/message.dart';
import '../shared/status.dart';
import '../shared/streams.dart';
import '../shared/timeout.dart';
import 'call.dart';
import 'interceptor.dart';
import 'service.dart';

typedef ServiceLookup = Service? Function(String service);
typedef GrpcErrorHandler = void Function(GrpcError error, StackTrace? trace);

/// Handles an incoming gRPC call.
class ServerHandler extends ServiceCall {
  final ServerTransportStream _stream;
  final ServiceLookup _serviceLookup;
  final List<Interceptor> _interceptors;
  final List<ServerInterceptor> _serverInterceptors;
  final CodecRegistry? _codecRegistry;
  final GrpcErrorHandler? _errorHandler;

  // ignore: cancel_subscriptions
  StreamSubscription<GrpcMessage>? _incomingSubscription;

  late Service _service;
  late ServiceMethod _descriptor;

  Map<String, String>? _clientMetadata;
  Codec? _callEncodingCodec;

  StreamController? _requests;
  bool _hasReceivedRequest = false;

  late Stream _responses;
  StreamSubscription? _responseSubscription;
  bool _headersSent = false;
  bool _trailersSent = false;

  Map<String, String>? _customHeaders = {};
  Map<String, String>? _customTrailers = {};

  DateTime? _deadline;
  bool _isTimedOut = false;
  bool _streamTerminated = false;
  Timer? _timeoutTimer;

  final X509Certificate? _clientCertificate;
  final InternetAddress? _remoteAddress;

  /// Emits a ping everytime data is received
  final Sink<void>? onDataReceived;

  final Completer<void> _isCanceledCompleter = Completer<void>();

  Future<void> get onCanceled => _isCanceledCompleter.future;

  set isCanceled(bool value) {
    if (!isCanceled) {
      _isCanceledCompleter.complete();
    }
  }

  ServerHandler({
    required ServerTransportStream stream,
    required ServiceLookup serviceLookup,
    required List<Interceptor> interceptors,
    required List<ServerInterceptor> serverInterceptors,
    required CodecRegistry? codecRegistry,
    X509Certificate? clientCertificate,
    InternetAddress? remoteAddress,
    GrpcErrorHandler? errorHandler,
    this.onDataReceived,
  }) : _stream = stream,
       _serviceLookup = serviceLookup,
       _interceptors = interceptors,
       _codecRegistry = codecRegistry,
       _clientCertificate = clientCertificate,
       _remoteAddress = remoteAddress,
       _errorHandler = errorHandler,
       _serverInterceptors = serverInterceptors;

  @override
  DateTime? get deadline => _deadline;

  @override
  bool get isCanceled => _isCanceledCompleter.isCompleted;

  @override
  bool get isTimedOut => _isTimedOut;

  @override
  Map<String, String>? get clientMetadata => _clientMetadata;

  @override
  Map<String, String>? get headers => _customHeaders;

  @override
  Map<String, String>? get trailers => _customTrailers;

  @override
  X509Certificate? get clientCertificate => _clientCertificate;

  @override
  InternetAddress? get remoteAddress => _remoteAddress;

  void handle() {
    _stream.onTerminated = (_) => cancel();

    _incomingSubscription = _stream.incomingMessages
        .transform(GrpcHttpDecoder())
        .transform(grpcDecompressor(codecRegistry: _codecRegistry))
        .listen(_onDataIdle, onError: _onError, onDone: _onDoneError, cancelOnError: true);
    _stream.outgoingMessages.done.then((_) {
      cancel();
    });
  }

  /// Cancel response subscription, if active. If the stream exits with an
  /// error, just ignore it. The client is long gone, so it doesn't care.
  /// We need the catchError() handler here, since otherwise the error would
  /// be an unhandled exception.
  void _cancelResponseSubscription() {
    _responseSubscription?.cancel().catchError((_) {});
  }

  /// Attempts to add [error] to [requests] and then close it. Each operation
  /// is in its own try block so that if addError throws, close is still
  /// attempted. This ensures handlers blocked on await-for are unblocked
  /// even when addError fails.
  void _addErrorAndClose(
    StreamController<dynamic>? requests,
    GrpcError error, [
    StackTrace? trace,
    String context = '',
    String event = 'deliver_error',
  ]) {
    if (requests == null || requests.isClosed) return;
    try {
      requests.addError(error, trace);
    } catch (e) {
      logGrpcEvent(
        '[gRPC] Failed to deliver error to request stream in $context: $e',
        component: 'ServerHandler',
        event: event,
        context: context,
        error: e,
      );
    }
    try {
      requests.close();
    } catch (e) {
      logGrpcEvent(
        '[gRPC] Failed to close request stream in $context: $e',
        component: 'ServerHandler',
        event: 'close_stream',
        context: context,
        error: e,
      );
    }
  }

  // -- Idle state, incoming data --

  void _onDataIdle(GrpcMessage headerMessage) async {
    onDataReceived?.add(null);
    if (headerMessage is! GrpcMetadata) {
      _sendError(GrpcError.unimplemented('Expected header frame'));
      _sinkIncoming();
      return;
    }
    _incomingSubscription!.pause();

    _clientMetadata = headerMessage.metadata;
    final path = _clientMetadata![':path']!;
    final pathSegments = path.split('/');
    if (pathSegments.length < 3) {
      _sendError(GrpcError.unimplemented('Invalid path'));
      _sinkIncoming();
      return;
    }
    final serviceName = pathSegments[1];
    final methodName = pathSegments[2];
    if (_codecRegistry != null) {
      final acceptedEncodings = clientMetadata!['grpc-accept-encoding']?.split(',') ?? [];
      _callEncodingCodec = acceptedEncodings
          .map(_codecRegistry.lookup)
          .firstWhere((c) => c != null, orElse: () => null);
    }

    final service = _serviceLookup(serviceName);
    final descriptor = service?.$lookupMethod(methodName);
    if (descriptor == null) {
      _sendError(GrpcError.unimplemented('Path $path not found'));
      _sinkIncoming();
      return;
    }
    _service = service!;
    _descriptor = descriptor;

    final error = await _applyInterceptors();
    if (error != null) {
      _sendError(error);
      _sinkIncoming();
      return;
    }

    // Guard: cancel() may have run during the async interceptor await.
    // Without this check, the handler continues processing indefinitely,
    // potentially blocking Server.shutdown().
    if (isCanceled) return;

    _startStreamingRequest();
  }

  GrpcError? _onMetadata() {
    try {
      _service.$onMetadata(this);
    } on GrpcError catch (error) {
      return error;
    } catch (error) {
      final grpcError = GrpcError.internal(error.toString());
      return grpcError;
    }
    return null;
  }

  Future<GrpcError?> _applyInterceptors() async {
    try {
      for (final interceptor in _interceptors) {
        final error = await interceptor(this, _descriptor);
        if (error != null) {
          return error;
        }
      }
    } catch (error) {
      // Preserve the original GrpcError (and its status code) if the
      // interceptor deliberately threw one. Only wrap non-GrpcError
      // exceptions as INTERNAL.
      if (error is GrpcError) return error;
      final grpcError = GrpcError.internal(error.toString());
      return grpcError;
    }
    return null;
  }

  void _startStreamingRequest() {
    final requests = _descriptor.createRequestStream(_incomingSubscription!);
    _requests = requests;
    _incomingSubscription!.onData(_onDataActive);

    final error = _onMetadata();
    if (error != null) {
      _addErrorAndClose(requests, error, null, '_startStreamingRequest');
      _sendError(error);
      _onDone();
      _terminateStream();
      return;
    }

    _responses = _descriptor.handle(this, requests.stream, _serverInterceptors);

    _responseSubscription = _responses.listen(
      _onResponse,
      onError: _onResponseError,
      onDone: _onResponseDone,
      cancelOnError: true,
    );
    _incomingSubscription!.onData(_onDataActive);
    _incomingSubscription!.onDone(_onDoneExpected);

    final timeout = fromTimeoutString(_clientMetadata!['grpc-timeout']);
    if (timeout != null) {
      _deadline = DateTime.now().add(timeout);
      _timeoutTimer = Timer(timeout, _onTimedOut);
    }
  }

  void _onTimedOut() {
    if (isCanceled) return;
    _isTimedOut = true;
    isCanceled = true;
    // Stop the response handler from yielding more items after timeout.
    _cancelResponseSubscription();
    final error = GrpcError.deadlineExceeded('Deadline exceeded');
    _sendError(error);
    _addErrorAndClose(_requests, error, null, '_onTimedOut', 'deliver_timeout_error');
    // Clean up the incoming subscription and terminate the HTTP/2 stream
    // to avoid leaking server-side resources after deadline expiry.
    _incomingSubscription?.cancel();
    _terminateStream();
  }

  // -- Active state, incoming data --

  void _onDataActive(GrpcMessage message) {
    if (_requests == null) return;

    if (message is! GrpcData) {
      final error = GrpcError.unimplemented('Expected request');
      _sendError(error);
      _addErrorAndClose(_requests, error, null, '_onDataActive.badMessage');
      return;
    }

    if (_hasReceivedRequest && !_descriptor.streamingRequest) {
      final error = GrpcError.unimplemented('Too many requests');
      _sendError(error);
      _addErrorAndClose(_requests, error, null, '_onDataActive.tooManyRequests');
      return;
    }

    onDataReceived?.add(null);
    final data = message;
    Object? request;
    try {
      request = _descriptor.deserialize(data.data);
    } catch (error, trace) {
      final grpcError = GrpcError.internal('Error deserializing request: $error');
      _sendError(grpcError, trace);
      _addErrorAndClose(_requests, grpcError, trace, '_onDataActive.deserialize');
      return;
    }
    if (!_requests!.isClosed) {
      try {
        _requests!.add(request);
      } catch (e) {
        logGrpcEvent(
          '[gRPC] Failed to add request to stream'
          ' in _onDataActive: $e',
          component: 'ServerHandler',
          event: 'add_request',
          context: '_onDataActive',
          error: e,
        );
        return;
      }
    }
    _hasReceivedRequest = true;
  }

  // -- Active state, outgoing response data --

  void _onResponse(dynamic response) {
    try {
      final bytes = _descriptor.serialize(response);
      if (!_headersSent) {
        sendHeaders();
      }
      _stream.sendData(frame(bytes, _callEncodingCodec));
    } catch (error, trace) {
      final grpcError = GrpcError.internal('Error sending response: $error');
      // Safely attempt to notify the handler about the error.
      // _addErrorAndClose uses separate try blocks so addError failure
      // cannot skip close — handler must exit even when addError throws.
      _addErrorAndClose(_requests, grpcError, trace, '_onResponse');
      _sendError(grpcError, trace);
      _cancelResponseSubscription();
    }
  }

  void _onResponseDone() {
    sendTrailers();
  }

  void _onResponseError(Object error, StackTrace trace) {
    final grpcError = error is GrpcError ? error : GrpcError.unknown(error.toString());
    // Close _requests so handlers blocked in await-for are unblocked.
    // Without this, bidi handlers hang indefinitely on response errors
    // because nothing signals the request stream to close.
    _addErrorAndClose(_requests, grpcError, trace, '_onResponseError');
    _sendError(grpcError, trace);
  }

  @override
  void sendHeaders() {
    if (_headersSent) throw GrpcError.internal('Headers already sent');

    // Capture into non-nullable local before nulling the field.
    // Prevents NPE if _customHeaders is ever null due to a code
    // path change or concurrent teardown.
    final customHeaders = _customHeaders ?? {};
    _customHeaders = null;
    customHeaders
      ..remove(':status')
      ..remove('content-type');

    // TODO(jakobr): Should come from package:http2?
    final outgoingHeadersMap = <String, String>{
      ':status': '200',
      'content-type': 'application/grpc',
      if (_callEncodingCodec != null) 'grpc-encoding': _callEncodingCodec!.encodingName,
    };

    outgoingHeadersMap.addAll(customHeaders);

    final outgoingHeaders = <Header>[];
    outgoingHeadersMap.forEach((key, value) => outgoingHeaders.add(Header(ascii.encode(key), utf8.encode(value))));
    _stream.sendHeaders(outgoingHeaders);
    _headersSent = true;
  }

  @override
  void sendTrailers({int? status = 0, String? message, Map<String, String>? errorTrailers}) {
    if (_trailersSent) return;
    _trailersSent = true;
    _timeoutTimer?.cancel();

    final outgoingTrailersMap = <String, String>{};
    if (!_headersSent) {
      // TODO(jakobr): Should come from package:http2?
      outgoingTrailersMap[':status'] = '200';
      outgoingTrailersMap['content-type'] = 'application/grpc';

      // Capture into non-nullable local before nulling the field.
      final customHeaders = _customHeaders ?? {};
      _customHeaders = null;
      customHeaders
        ..remove(':status')
        ..remove('content-type');
      outgoingTrailersMap.addAll(customHeaders);
      _headersSent = true;
    }
    // Capture into non-nullable local before nulling the field.
    final customTrailers = _customTrailers ?? {};
    _customTrailers = null;
    customTrailers
      ..remove(':status')
      ..remove('content-type');
    outgoingTrailersMap.addAll(customTrailers);
    outgoingTrailersMap['grpc-status'] = status.toString();
    if (message != null) {
      outgoingTrailersMap['grpc-message'] = Uri.encodeFull(message).replaceAll('%20', ' ');
    }
    if (errorTrailers != null) {
      outgoingTrailersMap.addAll(errorTrailers);
    }

    final outgoingTrailers = <Header>[];
    outgoingTrailersMap.forEach((key, value) => outgoingTrailers.add(Header(ascii.encode(key), utf8.encode(value))));

    // Safely send headers - the stream might already be closed
    try {
      _stream.sendHeaders(outgoingTrailers, endStream: true);
    } catch (e) {
      // Stream is already closed - this can happen during concurrent termination
      // The client is gone, so we can't send the trailers anyway
      logGrpcEvent(
        '[gRPC] Failed to send trailers'
        ' (stream may already be closed): $e',
        component: 'ServerHandler',
        event: 'send_trailers',
        context: 'sendTrailers',
        error: e,
      );
    }

    // Mark stream as terminated: endStream: true already closes the
    // HTTP/2 stream from our side. A subsequent cancel() (e.g. from
    // Server.shutdown()) must not send a redundant RST_STREAM.
    _streamTerminated = true;

    // Signal completion so Server.handlers cleanup fires.
    // The server tracks handlers via onCanceled.then(remove). On normal
    // completion (_onResponseDone → sendTrailers), isCanceled was never
    // set, so the handler leaked in the map until the connection closed.
    // The setter is idempotent — no-op if already completed by cancel().
    isCanceled = true;

    // We're done!
    _cancelResponseSubscription();
    _sinkIncoming();
  }

  // -- All states, incoming error / stream closed --

  void _onError(Object error) {
    // Exception from the incoming stream. Most likely a cancel request from the
    // client, so we treat it as such.
    _timeoutTimer?.cancel();
    isCanceled = true;
    _addErrorAndClose(_requests, GrpcError.cancelled('Cancelled'), null, '_onError', 'deliver_cancellation');
    _cancelResponseSubscription();
    _incomingSubscription!.cancel();
    _terminateStream();
  }

  void _onDoneError() {
    _sendError(GrpcError.unavailable('Request stream closed unexpectedly'));
    _onDone();
    // Terminate the HTTP/2 stream to avoid resource leaks when the
    // request stream closes unexpectedly (e.g. client disconnect).
    _terminateStream();
  }

  void _onDoneExpected() {
    if (!(_hasReceivedRequest || _descriptor.streamingRequest)) {
      final error = GrpcError.unimplemented('No request received');
      _sendError(error);
      _addErrorAndClose(_requests, error, null, '_onDoneExpected', 'deliver_error');
    }
    _onDone();
  }

  void _onDone() {
    try {
      _requests?.close();
    } catch (e) {
      logGrpcEvent(
        '[gRPC] Failed to close request stream in _onDone: $e',
        component: 'ServerHandler',
        event: 'close_stream',
        context: '_onDone',
        error: e,
      );
    }
    _incomingSubscription!.cancel();
  }

  /// Sink incoming requests. This is used when an error has already been
  /// reported, but we still need to consume the request stream from the client.
  void _sinkIncoming() {
    _incomingSubscription!
      ..onData((_) {})
      ..onDone(_onDone);
  }

  void _sendError(GrpcError error, [StackTrace? trace]) {
    try {
      _errorHandler?.call(error, trace);
    } catch (e) {
      // Error handler threw — must not prevent sendTrailers().
      logGrpcEvent(
        '[gRPC] Error handler threw: $e',
        component: 'ServerHandler',
        event: 'error_handler_threw',
        context: '_sendError',
        error: e,
      );
    }

    sendTrailers(status: error.code, message: error.message, errorTrailers: error.trailers);
  }

  void cancel() {
    if (_streamTerminated) return;
    isCanceled = true;
    _timeoutTimer?.cancel();
    // Close the request stream so that handler methods blocked on
    // `await for (final request in requests)` are unblocked with a
    // cancellation error. Every other termination path (_onError,
    // _onTimedOut, _onDone) closes _requests — cancel() must too,
    // otherwise Server.shutdown() can hang indefinitely.
    _addErrorAndClose(_requests, GrpcError.cancelled('Cancelled'), null, 'cancel', 'deliver_cancellation');
    _cancelResponseSubscription();
    _incomingSubscription?.cancel();
    _terminateStream();
  }

  /// Terminates the underlying HTTP/2 stream by sending RST_STREAM.
  ///
  /// Guards against double-terminate: once a stream has been terminated
  /// (or its sink is already closed), subsequent calls are no-ops. This is
  /// necessary because [cancel] may be invoked by [Server.shutdown] on
  /// handlers whose streams have already completed normally.
  void _terminateStream() {
    if (_streamTerminated) return;
    _streamTerminated = true;
    try {
      _stream.terminate();
    } catch (e) {
      // Stream sink may already be closed (e.g. response completed with
      // endStream: true before shutdown). Safe to ignore.
      logGrpcEvent(
        '[gRPC] Failed to terminate stream'
        ' (may already be closed): $e',
        component: 'ServerHandler',
        event: 'terminate_stream',
        context: '_terminateStream',
        error: e,
      );
    }
  }
}
