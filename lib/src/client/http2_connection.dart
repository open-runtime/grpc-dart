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
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/transport.dart';

import '../shared/codec.dart';
import '../shared/logging/logging.dart' show logGrpcEvent;
import '../shared/status.dart';
import '../shared/timeout.dart';
import 'call.dart';
import 'client_keepalive.dart';
import 'client_transport_connector.dart';
import 'connection.dart' hide ClientConnection;
import 'connection.dart' as connection;
import 'options.dart';
import 'proxy.dart';
import 'transport/http2_credentials.dart';
import 'transport/http2_transport.dart';
import 'transport/transport.dart';

class Http2ClientConnection implements connection.ClientConnection {
  static final _methodPost = Header.ascii(':method', 'POST');
  static final _schemeHttp = Header.ascii(':scheme', 'http');
  static final _schemeHttps = Header.ascii(':scheme', 'https');
  static final _contentTypeGrpc = Header.ascii('content-type', 'application/grpc');
  static final _teTrailers = Header.ascii('te', 'trailers');

  final ChannelOptions options;

  connection.ConnectionState _state = ConnectionState.idle;

  void Function(connection.ConnectionState)? onStateChanged;

  final _pendingCalls = <ClientCall>[];

  final ClientTransportConnector _transportConnector;
  ClientTransportConnection? _transportConnection;

  /// Used for idle and reconnect timeout, depending on [_state].
  Timer? _timer;

  /// Used for making sure a single connection is not kept alive too long.
  final Stopwatch _connectionLifeTimer = Stopwatch();

  Duration? _currentReconnectDelay;

  ClientKeepAlive? keepAliveManager;

  /// Generation counter to prevent stale socket.done callbacks from
  /// abandoning a newer connection.
  int _connectionGeneration = 0;

  /// Subscription to [ClientTransportConnection.onFrameReceived], cancelled
  /// in [_disconnect] to avoid leaks.
  StreamSubscription? _frameReceivedSubscription;

  Http2ClientConnection(Object host, int port, this.options)
    : _transportConnector = SocketTransportConnector(host, port, options);

  Http2ClientConnection.fromClientTransportConnector(this._transportConnector, this.options);

  ChannelCredentials get credentials => options.credentials;

  @override
  String get authority => _transportConnector.authority;

  @override
  String get scheme => options.credentials.isSecure ? 'https' : 'http';

  ConnectionState get state => _state;

  /// Safety timeout for the initial SETTINGS frame from the peer.
  /// If the peer's SETTINGS frame does not arrive within this window
  /// (e.g., broken connection or non-HTTP/2 endpoint), fall through
  /// and proceed. This prevents blocking indefinitely.
  static const _settingsFrameTimeout = Duration(milliseconds: 100);

  Future<ClientTransportConnection> connectTransport() async {
    // Increment generation BEFORE the await so that any stale .done
    // callback from a previous connection that fires during the await
    // sees (oldGeneration != _connectionGeneration) and is a no-op.
    // If we incremented after, a stale callback could match and
    // incorrectly abandon a perfectly good new connection.
    final generation = ++_connectionGeneration;
    final connection = await _transportConnector.connect();
    _transportConnector.done.then(
      (_) {
        if (generation == _connectionGeneration) {
          _abandonConnection();
        }
      },
      onError: (_) {
        // socket.done can complete with an error (e.g. broken pipe,
        // connection reset). Without this handler the error is unhandled
        // and the connection becomes a zombie — never abandoned, never
        // reconnected. Treat error-completion the same as normal closure.
        if (generation == _connectionGeneration) {
          _abandonConnection();
        }
      },
    );

    // Wait for the peer's initial SETTINGS frame rather than guessing
    // with a fixed delay. The http2 package (v2.3.1+) exposes
    // onInitialPeerSettingsReceived for this purpose.
    try {
      await connection.onInitialPeerSettingsReceived.timeout(_settingsFrameTimeout);
    } on TimeoutException {
      // Settings frame did not arrive within the safety window.
      // Proceed anyway — the connection may still work if settings
      // arrive later, or it will fail on the first RPC.
    }

    if (_state == ConnectionState.shutdown) {
      _transportConnector.shutdown();
      throw _ShutdownException();
    }
    return connection;
  }

  void _connect() {
    if (_state != ConnectionState.idle && _state != ConnectionState.transientFailure) {
      return;
    }
    _setState(ConnectionState.connecting);
    connectTransport()
        .then<void>((transport) async {
          _currentReconnectDelay = null;
          _transportConnection = transport;
          if (options.keepAlive.shouldSendPings) {
            keepAliveManager = ClientKeepAlive(
              options: options.keepAlive,
              ping: () {
                if (transport.isOpen) {
                  transport.ping();
                }
              },
              onPingTimeout: () {
                transport.finish().catchError((e) {
                  logGrpcEvent(
                    '[gRPC] Failed to finish transport'
                    ' on ping timeout: $e',
                    component: 'Http2ClientConnection',
                    event: 'finish_transport',
                    context: 'onPingTimeout',
                    error: e,
                  );
                });
              },
            );
            _frameReceivedSubscription = transport.onFrameReceived.listen((_) => keepAliveManager?.onFrameReceived());
          }
          _connectionLifeTimer
            ..reset()
            ..start();
          transport.onActiveStateChanged = _handleActiveStateChanged;
          _setState(ConnectionState.ready);

          if (_hasPendingCalls()) {
            final pendingCalls = _pendingCalls.toList();
            _pendingCalls.clear();
            for (final call in pendingCalls) {
              // If the connection state changed during a yield (e.g.,
              // shutdown or abandonment), handle remaining calls.
              // We cannot just `break` here because _pendingCalls was
              // already cleared — remaining calls in this local
              // snapshot would become orphaned futures that never
              // complete.
              if (_state != ConnectionState.ready) {
                if (_state == ConnectionState.shutdown) {
                  _shutdownCall(call);
                } else {
                  // Re-queue for the next connection attempt. We
                  // batch all remaining calls here rather than
                  // calling dispatchCall() per-call, because
                  // dispatchCall() in idle state triggers an
                  // immediate _connect() with zero backoff. The
                  // post-loop reconnection below applies proper
                  // exponential backoff.
                  _pendingCalls.add(call);
                }
                continue;
              }
              dispatchCall(call);
              // Yield to the event loop so the HTTP/2 transport can
              // process incoming frames (WINDOW_UPDATE, SETTINGS ACK)
              // between call dispatches. Without this yield, a burst
              // of pending calls exhausts the flow-control window on
              // transports without TCP_NODELAY (UDS, named pipes).
              await Future.delayed(Duration.zero);
            }
            // If calls were re-queued because the connection changed
            // state mid-iteration (e.g., GOAWAY during dispatch),
            // trigger reconnection with exponential backoff. This
            // prevents tight-loop reconnection when a server
            // repeatedly accepts and immediately GOAWAY's.
            if (_hasPendingCalls() && _state != ConnectionState.shutdown && _state != ConnectionState.connecting) {
              _setState(ConnectionState.transientFailure);
              _currentReconnectDelay = options.backoffStrategy(_currentReconnectDelay);
              _timer = Timer(_currentReconnectDelay!, _handleReconnect);
            }
          }
        })
        .catchError(_handleConnectionFailure);
  }

  /// Abandons the current connection if it is unhealthy or has been open for
  /// too long.
  ///
  /// Assumes [_transportConnection] is not `null`.
  void _refreshConnectionIfUnhealthy() {
    final isHealthy = _transportConnection!.isOpen;
    final shouldRefresh = _connectionLifeTimer.elapsed > options.connectionTimeout;
    if (shouldRefresh) {
      try {
        _transportConnection!.finish().catchError((e) {
          logGrpcEvent(
            '[gRPC] Failed to finish transport during refresh: $e',
            component: 'Http2ClientConnection',
            event: 'finish_transport',
            context: '_refreshConnectionIfUnhealthy',
            error: e,
          );
        });
      } catch (e) {
        // finish() may throw synchronously if the transport is
        // already terminated. Safe to ignore — we are about to
        // abandon this connection anyway.
        logGrpcEvent(
          '[gRPC] finish() threw synchronously during refresh: $e',
          component: 'Http2ClientConnection',
          event: 'finish_transport_sync',
          context: '_refreshConnectionIfUnhealthy',
          error: e,
        );
      }
      // Note: onTransportTermination is called by _disconnect() inside
      // _abandonConnection(), so we don't call it here to avoid double-call.
    }
    if (!isHealthy || shouldRefresh) {
      _abandonConnection();
    }
  }

  @override
  void dispatchCall(ClientCall call) {
    if (_transportConnection != null) {
      _refreshConnectionIfUnhealthy();
    }
    switch (_state) {
      case ConnectionState.ready:
        _startCall(call);
        break;
      case ConnectionState.shutdown:
        _shutdownCall(call);
        break;
      default:
        _pendingCalls.add(call);
        if (_state == ConnectionState.idle) {
          _connect();
        }
    }
  }

  @override
  GrpcTransportStream makeRequest(
    String path,
    Duration? timeout,
    Map<String, String> metadata,
    ErrorHandler onRequestFailure, {
    CallOptions? callOptions,
  }) {
    final compressionCodec = callOptions?.compression;
    final headers = createCallHeaders(
      credentials.isSecure,
      _transportConnector.authority,
      path,
      timeout,
      metadata,
      compressionCodec,
      userAgent: options.userAgent,
      grpcAcceptEncodings:
          (callOptions?.metadata ?? const {})['grpc-accept-encoding'] ?? options.codecRegistry?.supportedEncodings,
    );
    if (_transportConnection == null) {
      _connect();
      throw GrpcError.unavailable('Connection not ready');
    }
    final stream = _transportConnection!.makeRequest(headers);
    return Http2TransportStream(stream, onRequestFailure, options.codecRegistry, compressionCodec);
  }

  void _startCall(ClientCall call) {
    if (call.isCancelled) return;
    call.onConnectionReady(this);
  }

  void _failCall(ClientCall call, dynamic error) {
    if (call.isCancelled) return;
    call.onConnectionError(error);
  }

  void _shutdownCall(ClientCall call) {
    _failCall(call, 'Connection shutting down.');
  }

  @override
  Future<void> shutdown() async {
    if (_state == ConnectionState.shutdown) return;
    _setShutdownState();
    await _transportConnection?.finish();
    _disconnect();
    // Release the underlying OS resource (e.g. Win32 pipe handle, socket).
    // Only called in terminal paths (shutdown/terminate) — NOT in _disconnect()
    // which is also used by non-terminal paths (idle timeout, connection
    // failure, abandon) that may need to reconnect.
    _transportConnector.shutdown();
  }

  @override
  Future<void> terminate() async {
    _setShutdownState();
    await _transportConnection?.terminate();
    _disconnect();
    // Release the underlying OS resource (e.g. Win32 pipe handle, socket).
    // Without this, terminate() closes the HTTP/2 logical connection but
    // leaves the transport connector open, causing _readLoop() to busy-wait
    // forever on named pipes and preventing process exit.
    _transportConnector.shutdown();
  }

  void _setShutdownState() {
    _setState(ConnectionState.shutdown);
    _cancelTimer();
    _pendingCalls.forEach(_shutdownCall);
    _pendingCalls.clear();
  }

  void _setState(ConnectionState state) {
    _state = state;
    onStateChanged?.call(state);
  }

  void _handleIdleTimeout() {
    if (_timer == null || _state != ConnectionState.ready) return;
    _cancelTimer();
    _transportConnection?.finish().catchError((e) {
      logGrpcEvent(
        '[gRPC] Failed to finish transport during idle timeout: $e',
        component: 'Http2ClientConnection',
        event: 'finish_transport',
        context: '_handleIdleTimeout',
        error: e,
      );
    });
    // Note: onTransportTermination is called by _disconnect() below,
    // so we don't call it here to avoid double-call.
    _disconnect();
    _setState(ConnectionState.idle);
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _handleActiveStateChanged(bool isActive) {
    if (isActive) {
      _cancelTimer();
      keepAliveManager?.onTransportActive();
    } else {
      if (options.idleTimeout != null) {
        _timer ??= Timer(options.idleTimeout!, _handleIdleTimeout);
      }
      keepAliveManager?.onTransportIdle();
    }
  }

  bool _hasPendingCalls() {
    // Get rid of pending calls that have timed out.
    _pendingCalls.removeWhere((call) => call.isCancelled);
    return _pendingCalls.isNotEmpty;
  }

  void _handleConnectionFailure(Object error) {
    _disconnect();
    if (_state == ConnectionState.shutdown || _state == ConnectionState.idle) {
      return;
    }
    // TODO(jakobr): Log error.
    _cancelTimer();
    for (var call in _pendingCalls) {
      _failCall(call, error);
    }
    _pendingCalls.clear();
    _setState(ConnectionState.idle);
  }

  void _handleReconnect() {
    if (_timer == null || _state != ConnectionState.transientFailure) return;
    _cancelTimer();
    _connect();
  }

  void _disconnect() {
    _transportConnection = null;
    _frameReceivedSubscription?.cancel();
    _frameReceivedSubscription = null;
    _connectionLifeTimer.stop();
    keepAliveManager?.onTransportTermination();
    keepAliveManager = null;
  }

  void _abandonConnection() {
    _cancelTimer();
    _disconnect();

    if (_state == ConnectionState.idle || _state == ConnectionState.shutdown) {
      // All good.
      return;
    }

    // We were not planning to close the socket.
    if (!_hasPendingCalls()) {
      // No pending calls. Just hop to idle, and wait for a new RPC.
      _setState(ConnectionState.idle);
      return;
    }

    // We have pending RPCs. Reconnect after backoff delay.
    _setState(ConnectionState.transientFailure);
    _currentReconnectDelay = options.backoffStrategy(_currentReconnectDelay);
    _timer = Timer(_currentReconnectDelay!, _handleReconnect);
  }

  static List<Header> createCallHeaders(
    bool useTls,
    String authority,
    String path,
    Duration? timeout,
    Map<String, String>? metadata,
    Codec? compressionCodec, {
    String? userAgent,
    String? grpcAcceptEncodings,
  }) {
    final headers = [
      _methodPost,
      useTls ? _schemeHttps : _schemeHttp,
      Header(ascii.encode(':path'), utf8.encode(path)),
      Header(ascii.encode(':authority'), utf8.encode(authority)),
      if (timeout != null) Header.ascii('grpc-timeout', toTimeoutString(timeout)),
      _contentTypeGrpc,
      _teTrailers,
      Header.ascii('user-agent', userAgent ?? defaultUserAgent),
      if (grpcAcceptEncodings != null) Header.ascii('grpc-accept-encoding', grpcAcceptEncodings),
      if (compressionCodec != null) Header.ascii('grpc-encoding', compressionCodec.encodingName),
    ];
    metadata?.forEach((key, value) {
      headers.add(Header(ascii.encode(key), utf8.encode(value)));
    });
    return headers;
  }
}

class SocketTransportConnector implements ClientTransportConnector {
  /// Either [InternetAddress] or [String].
  final Object _host;
  final int _port;
  final ChannelOptions _options;
  late Socket socket;
  bool _socketInitialized = false;

  Proxy? get proxy => _options.proxy;
  Object get host => proxy == null ? _host : proxy!.host;
  int get port => proxy == null ? _port : proxy!.port;

  SocketTransportConnector(this._host, this._port, this._options) : assert(_host is InternetAddress || _host is String);

  @override
  Future<ClientTransportConnection> connect() async {
    final securityContext = _options.credentials.securityContext;
    var incoming = await connectImpl(proxy);

    // Don't wait for io buffers to fill up before sending requests.
    if (socket.address.type != InternetAddressType.unix) {
      socket.setOption(SocketOption.tcpNoDelay, true);
    }
    if (securityContext != null) {
      // Todo(sigurdm): We want to pass supportedProtocols: ['h2'].
      // http://dartbug.com/37950
      socket = await SecureSocket.secure(
        socket,
        // This is not really the host, but the authority to verify the TLC
        // connection against.
        //
        // We don't use `this.authority` here, as that includes the port.
        host: _options.credentials.authority ?? host,
        context: securityContext,
        onBadCertificate: _validateBadCertificate,
      );
      incoming = socket;
    }
    return ClientTransportConnection.viaStreams(incoming, socket);
  }

  Future<Stream<List<int>>> connectImpl(Proxy? proxy) async {
    socket = await initSocket(host, port);
    _socketInitialized = true;
    if (proxy == null) {
      return socket;
    }
    return await connectToProxy(proxy);
  }

  Future<Socket> initSocket(Object host, int port) async {
    return await Socket.connect(host, port, timeout: _options.connectTimeout);
  }

  void _sendConnect(Map<String, String> headers) {
    const linebreak = '\r\n';
    socket.write('CONNECT $_host:$_port HTTP/1.1');
    socket.write(linebreak);
    headers.forEach((key, value) {
      socket.write('$key: $value');
      socket.write(linebreak);
    });
    socket.write(linebreak);
  }

  @override
  String get authority {
    return _options.credentials.authority ?? _makeAuthority();
  }

  String _makeAuthority() {
    final host = _host;
    final portSuffix = _port == 443 ? '' : ':$_port';
    final String hostName;
    if (host is String) {
      hostName = host;
    } else {
      host as InternetAddress;
      if (host.type == InternetAddressType.unix) {
        return 'localhost'; // UDS don't have a meaningful authority.
      }
      hostName = host.host;
    }
    return '$hostName$portSuffix';
  }

  @override
  Future get done {
    if (!_socketInitialized) {
      throw StateError('SocketTransportConnector.done accessed before connect()');
    }
    return socket.done;
  }

  @override
  void shutdown() {
    if (!_socketInitialized) return;
    socket.destroy();
  }

  bool _validateBadCertificate(X509Certificate certificate) {
    final credentials = _options.credentials;
    final validator = credentials.onBadCertificate;

    if (validator == null) return false;
    return validator(certificate, authority);
  }

  Future<Stream<List<int>>> connectToProxy(Proxy proxy) async {
    final headers = {'Host': '$_host:$_port'};
    if (proxy.isAuthenticated) {
      // If the proxy configuration contains user information use that
      // for proxy basic authorization.
      final authStr = '${proxy.username}:${proxy.password}';
      final auth = base64Encode(utf8.encode(authStr));
      headers[HttpHeaders.proxyAuthorizationHeader] = 'Basic $auth';
    }
    final completer = Completer<void>();

    /// Routes the events through after connection to the proxy has been
    /// established.
    final intermediate = StreamController<List<int>>();

    /// Route events after the successfull connect to the `intermediate`.
    socket.listen(
      (event) {
        if (completer.isCompleted) {
          intermediate.sink.add(event);
        } else {
          _waitForResponse(event, completer);
        }
      },
      onDone: intermediate.close,
      onError: intermediate.addError,
    );

    _sendConnect(headers);
    await completer.future;
    return intermediate.stream;
  }

  /// Wait for the response to the `CONNECT` request, which should be an
  /// acknowledgement with a 200 status code.
  void _waitForResponse(Uint8List chunk, Completer<void> completer) {
    final response = ascii.decode(chunk);
    if (response.startsWith('HTTP/1.1 200')) {
      completer.complete();
    } else {
      completer.completeError(TransportException('Error establishing proxy connection: $response'));
    }
  }
}

class _ShutdownException implements Exception {}
