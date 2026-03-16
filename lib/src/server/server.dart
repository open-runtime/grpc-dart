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
import 'dart:io';

import 'package:http2/transport.dart';
import 'package:meta/meta.dart';

import '../shared/codec_registry.dart';
import '../shared/io_bits/io_bits.dart' as io_bits;
import '../shared/logging/logging.dart' show logGrpcEvent;
import '../shared/security.dart';
import 'handler.dart';
import 'interceptor.dart';
import 'server_keepalive.dart';
import 'service.dart';

/// Wrapper around grpc_server_credentials, a way to authenticate a server.
abstract class ServerCredentials {
  /// Validates incoming connection. Returns [true] if connection is
  /// allowed to proceed.
  bool validateClient(Socket socket) => true;

  /// Creates [SecurityContext] from these credentials if possible.
  /// Otherwise returns [null].
  SecurityContext? get securityContext;
}

/// Set of credentials that only allows local TCP connections.
class ServerLocalCredentials extends ServerCredentials {
  @override
  bool validateClient(Socket socket) => socket.remoteAddress.isLoopback;

  @override
  SecurityContext? get securityContext => null;
}

class ServerTlsCredentials extends ServerCredentials {
  final List<int>? certificate;
  final String? certificatePassword;
  final List<int>? privateKey;
  final String? privateKeyPassword;

  /// TLS credentials for a [Server].
  ///
  /// If the [certificate] or [privateKey] is encrypted, the password must also
  /// be provided.
  ServerTlsCredentials({this.certificate, this.certificatePassword, this.privateKey, this.privateKeyPassword});

  @override
  SecurityContext get securityContext {
    final context = createSecurityContext(true);
    if (privateKey != null) {
      context.usePrivateKeyBytes(privateKey!, password: privateKeyPassword);
    }
    if (certificate != null) {
      context.useCertificateChainBytes(certificate!, password: certificatePassword);
    }
    return context;
  }

  @override
  bool validateClient(Socket socket) => true;
}

/// A gRPC server that serves via provided [ServerTransportConnection]s.
///
/// Unlike [Server], the caller has the responsibility of configuring and
/// managing the connection from a client.
class ConnectionServer {
  static const Duration _incomingSubscriptionCancelTimeout = Duration(seconds: 5);
  static const Duration _responseCancelTimeout = Duration(seconds: 5);
  static const Duration _finishConnectionDeadline = Duration(seconds: 5);
  static const Duration _terminateConnectionTimeout = Duration(seconds: 2);

  final Map<String, Service> _services = {};
  final List<Interceptor> _interceptors;
  final List<ServerInterceptor> _serverInterceptors;
  final CodecRegistry? _codecRegistry;
  final int? _maxInboundMessageSize;
  final GrpcErrorHandler? _errorHandler;
  final ServerKeepAliveOptions _keepAliveOptions;

  @visibleForTesting
  final Map<ServerTransportConnection, List<ServerHandler>> handlers = {};

  final _connections = <ServerTransportConnection>[];

  /// Tracks the `incomingStreams` subscription for each connection so
  /// [shutdownActiveConnections] can cancel it immediately. Cancelling
  /// this subscription stops the server from processing any further
  /// HTTP/2 streams (and thus new data frames) from clients, which
  /// prevents `connection.finish()` from blocking when a client is
  /// still actively sending data.
  final _incomingSubscriptions = <ServerTransportConnection, StreamSubscription<ServerTransportStream>>{};

  /// Maps connections to their underlying raw sockets, enabling forceful
  /// shutdown when the event loop is saturated by incoming data.
  ///
  /// Only populated by [Server] (TCP/TLS); [NamedPipeServer] connections
  /// do not have a raw [Socket] and are simply absent from this map.
  /// [_finishConnection]'s `socket?.destroy()` is a safe no-op when
  /// the connection has no entry.
  final _connectionSockets = <ServerTransportConnection, Socket>{};

  /// Maps connections to their keepalive data-received controllers.
  ///
  /// These controllers are closed during [shutdownActiveConnections] to
  /// prevent the Dart VM from staying alive due to unclosed streams.
  /// Without explicit closure, cancelling the incoming subscription
  /// (Step 1 of shutdown) does NOT fire onDone/onError, leaving the
  /// controller's stream listener permanently pending.
  final _keepAliveControllers = <ServerTransportConnection, StreamController<void>>{};

  /// Maps connections to their [ServerKeepAlive] instances.
  ///
  /// [ServerKeepAlive.handle] creates subscriptions on the http2
  /// connection's `onPingReceived` stream, which is backed by a
  /// `StreamController<int>` that the http2 package never closes
  /// during `connection.terminate()`. For TCP, `socket.destroy()`
  /// kills all lingering IO. For named pipes there is no equivalent,
  /// so the orphaned subscription keeps the Dart VM alive indefinitely
  /// (root cause of 44-minute Windows CI hangs). Disposing the
  /// instance cancels both subscriptions explicitly.
  final _keepAliveInstances = <ServerTransportConnection, ServerKeepAlive>{};

  /// Create a server for the given [services].
  ConnectionServer(
    List<Service> services, [
    List<Interceptor> interceptors = const <Interceptor>[],
    List<ServerInterceptor> serverInterceptors = const <ServerInterceptor>[],
    CodecRegistry? codecRegistry,
    GrpcErrorHandler? errorHandler,
    this._keepAliveOptions = const ServerKeepAliveOptions(),
    int? maxInboundMessageSize,
  ]) : _codecRegistry = codecRegistry,
       _maxInboundMessageSize = maxInboundMessageSize,
       _interceptors = interceptors,
       _serverInterceptors = serverInterceptors,
       _errorHandler = errorHandler {
    for (final service in services) {
      _services[service.$name] = service;
    }
  }

  Service? lookupService(String service) => _services[service];

  Future<void> _cleanupConnection(
    ServerTransportConnection connection,
    StreamController<void> onDataReceivedController,
  ) async {
    // Snapshot via List.of() avoids ConcurrentModificationError:
    // handler.cancel() / normal completion triggers onTerminated.then()
    // which removes
    // from the live list while we iterate.
    final connectionHandlers = List.of(handlers[connection] ?? <ServerHandler>[]);
    for (final handler in connectionHandlers) {
      handler.cancel();
    }
    _connections.remove(connection);
    handlers.remove(connection);
    _incomingSubscriptions.remove(connection);
    _connectionSockets.remove(connection);
    _keepAliveInstances.remove(connection)?.dispose();
    _keepAliveControllers.remove(connection);
    if (!onDataReceivedController.isClosed) {
      await onDataReceivedController.close();
    }
  }

  Future<void> serveConnection({
    required ServerTransportConnection connection,
    X509Certificate? clientCertificate,
    InternetAddress? remoteAddress,
  }) async {
    _connections.add(connection);
    handlers[connection] = [];
    // TODO(jakobr): Set active state handlers, close connection after idle
    // timeout.
    final onDataReceivedController = StreamController<void>();
    _keepAliveControllers[connection] = onDataReceivedController;
    final keepAlive = ServerKeepAlive(
      options: _keepAliveOptions,
      tooManyBadPings: () async => await connection.terminate(ErrorCode.ENHANCE_YOUR_CALM),
      pingNotifier: connection.onPingReceived,
      dataNotifier: onDataReceivedController.stream,
    );
    _keepAliveInstances[connection] = keepAlive;
    keepAlive.handle();
    final incomingSub = connection.incomingStreams.listen(
      (stream) {
        // Guard: onError may have already cleaned up this connection.
        // Without this check, handlers[connection]! throws a null check
        // error after onError removed the entry, and the handler leaks
        // untracked (never cancelled on shutdown).
        final connectionHandlers = handlers[connection];
        if (connectionHandlers == null) return;
        final handler = serveStream_(
          stream: stream,
          clientCertificate: clientCertificate,
          remoteAddress: remoteAddress,
          onDataReceived: onDataReceivedController.sink,
        );
        handler.onTerminated.then((_) => handlers[connection]?.remove(handler));
        connectionHandlers.add(handler);
      },
      onError: (error, stackTrace) {
        if (error is Error) {
          Zone.current.handleUncaughtError(error, stackTrace);
        }
        logGrpcEvent(
          '[gRPC] Connection stream error: $error',
          component: 'ConnectionServer',
          event: 'connection_stream_error',
          context: 'serveConnection',
          error: error,
        );
        // Keep onError non-blocking; cleanup mirrors onDone via shared helper.
        // Observe failures explicitly so async cleanup errors are never silent.
        unawaited(
          _cleanupConnection(connection, onDataReceivedController).catchError((cleanupError, _) {
            logGrpcEvent(
              '[gRPC] Connection cleanup failed after stream error: '
              '$cleanupError',
              component: 'ConnectionServer',
              event: 'connection_cleanup_error',
              context: 'serveConnection.onError',
              error: cleanupError,
            );
          }),
        );
      },
      onDone: () async {
        // TODO(sigurdm): This is not correct behavior in the presence of
        // half-closed tcp streams.
        // Half-closed  streams seems to not be fully supported by package:http2.
        // https://github.com/dart-lang/http2/issues/42
        await _cleanupConnection(connection, onDataReceivedController);
      },
    );
    _incomingSubscriptions[connection] = incomingSub;
  }

  /// Cancels all active gRPC handlers and finishes all HTTP/2 connections.
  ///
  /// This is the core cleanup logic shared by [Server.shutdown] and
  /// [NamedPipeServer.shutdown]. The shutdown sequence is:
  ///
  /// 1. **Cancel incoming stream subscriptions** — stops the server
  ///    from accepting new HTTP/2 streams and, critically, stops
  ///    processing new DATA frames from clients. Without this, a
  ///    client that is continuously sending data can prevent
  ///    `connection.finish()` from ever completing.
  ///
  /// 2. **Cancel all handlers** — terminates in-flight RPCs and
  ///    enqueues RST_STREAM frames. Handlers must be cancelled
  ///    BEFORE connections are finished to avoid deadlock:
  ///    `connection.finish()` waits for all HTTP/2 streams to
  ///    close, but active response streams (e.g. server-side
  ///    streaming RPCs) won't close on their own.
  ///
  /// 3. **Yield** — gives the http2 `ConnectionMessageQueueOut`
  ///    at least one event-loop turn to flush RST_STREAM frames
  ///    before GOAWAY closes the socket. GOAWAY alone does NOT
  ///    terminate already-acknowledged streams on the client side
  ///    (only streams with IDs > `lastStreamId`).
  ///
  /// 4. **Finish each connection independently** — each connection
  ///    gets its own bounded shutdown via a [Completer] + [Timer]
  ///    pattern (NOT `.timeout()` which can fail to fire if the
  ///    event loop is saturated with incoming data). If `finish()`
  ///    doesn't complete within the grace period, `terminate()` is
  ///    called. If `terminate()` itself fails, we log and move on.
  ///    One hung connection must never block shutdown of others.
  ///
  /// Snapshots [_connections] before iterating because finishing a
  /// connection triggers the `onDone` callback in [serveConnection],
  /// which removes the connection from the list.
  @protected
  Future<void> shutdownActiveConnections() async {
    final activeConnections = List.of(_connections);

    // Step 1: Cancel incoming stream subscriptions in parallel
    // with a bounded timeout to stop processing new data from
    // clients immediately.
    final cancelSubFutures = <Future<void>>[];
    for (final connection in activeConnections) {
      final sub = _incomingSubscriptions.remove(connection);
      if (sub != null) {
        cancelSubFutures.add(
          sub.cancel().catchError((e) {
            logGrpcEvent(
              '[gRPC] incoming subscription cancel error: $e',
              component: 'ConnectionServer',
              event: 'subscription_cancel_error',
              context: 'shutdownActiveConnections',
              error: e,
            );
          }),
        );
      }
    }
    if (cancelSubFutures.isNotEmpty) {
      await Future.wait(cancelSubFutures).timeout(
        _incomingSubscriptionCancelTimeout,
        onTimeout: () {
          // Rule 4 exception (Rule 10): Shutdown MUST proceed even on
          // timeout — hanging here would block the entire server shutdown
          // sequence. The timeout is logged loudly to stderr so operators
          // can investigate the underlying cause (e.g. event loop
          // saturation, blocked subscription cancel callback).
          logGrpcEvent(
            '[gRPC] WARNING: incoming subscription cancel timeout after '
            '${_incomingSubscriptionCancelTimeout.inSeconds}s — '
            'proceeding with shutdown despite incomplete cancellation',
            component: 'ConnectionServer',
            event: 'subscription_cancel_timeout',
            context: 'shutdownActiveConnections',
          );
          return <void>[];
        },
      );
    }

    // Step 1.5: Dispose keepalive instances and close data-received
    // controllers. The http2 package never closes `_pingReceived`
    // during connection.terminate(), so ServerKeepAlive's ping
    // subscription persists indefinitely. For TCP, socket.destroy()
    // kills all IO. For named pipes there is no equivalent — the
    // orphaned subscription keeps the VM alive (44-min Windows hang).
    // Disposing the instance cancels both subscriptions explicitly.
    // Closing the data-received controller is still needed as a belt-
    // and-suspenders cleanup for the controller itself.
    for (final connection in activeConnections) {
      _keepAliveInstances.remove(connection)?.dispose();
      _keepAliveControllers.remove(connection)?.close();
    }

    // Step 2: Cancel all handlers to terminate in-flight RPCs.
    final cancelFutures = <Future<void>>[];
    for (final connection in activeConnections) {
      final connectionHandlers = List.of(handlers[connection] ?? <ServerHandler>[]);
      for (final handler in connectionHandlers) {
        handler.cancel();
        cancelFutures.add(handler.onResponseCancelDone);
      }
    }

    // Wait for all response subscription cancellations to complete.
    // async* generators (e.g. server-streaming RPCs) need event loop
    // turns to process the cancel signal and stop yielding values.
    // Without this, connection.finish() can block indefinitely
    // because HTTP/2 streams remain open while generators are
    // still producing.
    await Future.wait(cancelFutures).timeout(
      _responseCancelTimeout,
      onTimeout: () {
        // Rule 4 exception (Rule 10): Shutdown MUST proceed even on
        // timeout — hanging here would prevent connection.finish() from
        // ever running, leaving sockets open indefinitely. The timeout
        // is logged loudly to stderr so operators can investigate the
        // underlying cause (e.g. async* generator stuck yielding,
        // event loop saturation preventing cancel propagation).
        logGrpcEvent(
          '[gRPC] WARNING: handler.onResponseCancelDone timeout after '
          '${_responseCancelTimeout.inSeconds}s '
          '(event loop saturated?) — '
          'proceeding with shutdown despite incomplete cancellation',
          component: 'ConnectionServer',
          event: 'response_cancel_timeout',
          context: 'shutdownActiveConnections',
        );
        return <void>[];
      },
    );

    // Step 3: Yield to let the http2 outgoing queue flush
    // RST_STREAM frames before connection.finish() enqueues
    // GOAWAY and closes the socket.
    await Future.delayed(Duration.zero);

    // Step 4: Finish each connection with an independent,
    // timer-guaranteed deadline. Using Completer + Timer instead
    // of Future.timeout() because .timeout() relies on the same
    // event loop that may be saturated by incoming data frames,
    // causing the timeout to never fire.
    await Future.wait([for (final connection in activeConnections) _finishConnection(connection)], eagerError: false);
  }

  /// Finishes a single connection with a hard timer-based deadline.
  ///
  /// Tries `connection.finish()` (graceful GOAWAY + wait for streams
  /// to close). If that doesn't complete within 5 seconds, forcefully
  /// calls `connection.terminate()`. If terminate itself fails or times
  /// out, logs and completes anyway — a broken connection must never
  /// block the entire server shutdown.
  ///
  /// After terminate completes, the raw socket (if tracked in
  /// [_connectionSockets]) is destroyed to stop any lingering IO
  /// from the http2 package's `FrameReader` (which has a missing
  /// `onCancel` handler that lets the raw socket subscription
  /// continue processing data after the transport is closed).
  Future<void> _finishConnection(ServerTransportConnection connection) async {
    final done = Completer<void>();
    Timer? deadline;
    var terminateCalled = false;

    void complete() {
      deadline?.cancel();
      if (!done.isCompleted) done.complete();
    }

    void forceTerminate() {
      if (terminateCalled) return;
      terminateCalled = true;

      final terminateDone = Completer<void>();
      Timer? terminateDeadline;

      void completeTerminate() {
        terminateDeadline?.cancel();
        if (!terminateDone.isCompleted) terminateDone.complete();
      }

      terminateDeadline = Timer(_terminateConnectionTimeout, () {
        logGrpcEvent(
          '[gRPC] connection.terminate() timed out after '
          '${_terminateConnectionTimeout.inSeconds}s',
          component: 'ConnectionServer',
          event: 'terminate_timeout',
          context: 'shutdownActiveConnections',
        );
        completeTerminate();
      });

      try {
        connection
            .terminate()
            .then((_) {
              completeTerminate();
            })
            .catchError((e) {
              logGrpcEvent(
                '[gRPC] connection.terminate() async error: $e',
                component: 'ConnectionServer',
                event: 'terminate_async_error',
                context: 'shutdownActiveConnections',
                error: e,
              );
              completeTerminate();
            });
      } catch (e) {
        logGrpcEvent(
          '[gRPC] connection.terminate() failed: $e',
          component: 'ConnectionServer',
          event: 'terminate_error',
          context: 'shutdownActiveConnections',
          error: e,
        );
        completeTerminate();
      }

      terminateDone.future.whenComplete(() {
        // Destroy the raw socket to break event loop saturation
        // from the http2 FrameReader's orphaned socket
        // subscription (missing onCancel handler in
        // package:http2). On TCP with a client still pumping
        // data, the FrameReader continues processing frames
        // after terminate(), flooding IO callbacks. Destroying
        // the socket stops the flood.
        // No-op for NamedPipeServer (not in map).
        _connectionSockets.remove(connection)?.destroy();
        complete();
      });
    }

    // Start the hard deadline timer BEFORE calling finish().
    deadline = Timer(_finishConnectionDeadline, forceTerminate);

    // Fire finish() without awaiting — otherwise we block until it
    // resolves, defeating the timeout. Return done.future so the
    // caller completes when either finish() or the timer wins.
    try {
      connection
          .finish()
          .then((_) {
            complete();
          })
          .catchError((e) {
            logGrpcEvent(
              '[gRPC] connection.finish() failed: $e',
              component: 'ConnectionServer',
              event: 'finish_error',
              context: 'shutdownActiveConnections',
              error: e,
            );
            forceTerminate();
          });
    } catch (e) {
      logGrpcEvent(
        '[gRPC] connection.finish() sync error: $e',
        component: 'ConnectionServer',
        event: 'finish_sync_error',
        context: 'shutdownActiveConnections',
        error: e,
      );
      forceTerminate();
    }

    return done.future;
  }

  @visibleForTesting
  ServerHandler serveStream_({
    required ServerTransportStream stream,
    X509Certificate? clientCertificate,
    InternetAddress? remoteAddress,
    Sink<void>? onDataReceived,
  }) {
    return ServerHandler(
      stream: stream,
      serviceLookup: lookupService,
      interceptors: _interceptors,
      serverInterceptors: _serverInterceptors,
      codecRegistry: _codecRegistry,
      maxInboundMessageSize: _maxInboundMessageSize,
      // ignore: unnecessary_cast
      clientCertificate: clientCertificate as io_bits.X509Certificate?,
      // ignore: unnecessary_cast
      remoteAddress: remoteAddress as io_bits.InternetAddress?,
      errorHandler: _errorHandler,
      onDataReceived: onDataReceived,
    )..handle();
  }
}

/// A gRPC server.
///
/// Listens for incoming RPCs, dispatching them to the right [Service] handler.
class Server extends ConnectionServer {
  ServerSocket? _insecureServer;
  SecureServerSocket? _secureServer;

  /// Create a server for the given [services].
  @Deprecated('use Server.create() instead')
  Server(
    List<Service> services, [
    List<Interceptor> interceptors = const <Interceptor>[],
    CodecRegistry? codecRegistry,
    GrpcErrorHandler? errorHandler,
    ServerKeepAliveOptions keepAlive = const ServerKeepAliveOptions(),
    int? maxInboundMessageSize,
  ]) : super(
         services,
         interceptors,
         const <ServerInterceptor>[], // Empty list for new serverInterceptors parameter
         codecRegistry,
         errorHandler,
         keepAlive,
         maxInboundMessageSize,
       );

  /// Create a server for the given [services].
  Server.create({
    required List<Service> services,
    ServerKeepAliveOptions keepAliveOptions = const ServerKeepAliveOptions(),
    List<Interceptor> interceptors = const <Interceptor>[],
    List<ServerInterceptor> serverInterceptors = const <ServerInterceptor>[],
    CodecRegistry? codecRegistry,
    GrpcErrorHandler? errorHandler,
    int? maxInboundMessageSize,
  }) : super(
         services,
         interceptors,
         serverInterceptors,
         codecRegistry,
         errorHandler,
         keepAliveOptions,
         maxInboundMessageSize,
       );

  /// The port that the server is listening on, or `null` if the server is not
  /// active.
  int? get port {
    if (_secureServer != null) return _secureServer!.port;
    if (_insecureServer != null) return _insecureServer!.port;
    return null;
  }

  @override
  Service? lookupService(String service) => _services[service];

  /// Starts the [Server] with the given options.
  /// [address] can be either a [String] or an [InternetAddress], in the latter
  /// case it can be a Unix Domain Socket address.
  ///
  /// If [port] is [null] then it defaults to `80` for non-secure and `443` for
  /// secure variants.  Pass `0` for [port] to let OS select a port for the
  /// server.
  Future<void> serve({
    dynamic address,
    int? port,
    ServerCredentials? security,
    ServerSettings? http2ServerSettings,
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) async {
    // TODO(dart-lang/grpc-dart#9): Handle HTTP/1.1 upgrade to h2c, if allowed.
    Stream<Socket> server;
    final securityContext = security?.securityContext;
    if (securityContext != null) {
      final _server = await SecureServerSocket.bind(
        address ?? InternetAddress.anyIPv4,
        port ?? 443,
        securityContext,
        backlog: backlog,
        shared: shared,
        v6Only: v6Only,
        requestClientCertificate: requestClientCertificate,
        requireClientCertificate: requireClientCertificate,
      );
      _secureServer = _server;
      server = _server;
    } else {
      final _server = await ServerSocket.bind(
        address ?? InternetAddress.anyIPv4,
        port ?? 80,
        backlog: backlog,
        shared: shared,
        v6Only: v6Only,
      );
      _insecureServer = _server;
      server = _server;
    }
    server.listen(
      (socket) {
        if (security != null) {
          bool isAllowed;
          try {
            isAllowed = security.validateClient(socket);
          } catch (e) {
            logGrpcEvent(
              '[gRPC] validateClient threw: $e',
              component: 'Server',
              event: 'validate_client_error',
              context: 'serve',
              error: e,
            );
            socket.destroy();
            return;
          }
          if (!isAllowed) {
            socket.destroy();
            return;
          }
        }

        // Don't wait for io buffers to fill up before sending requests.
        if (socket.address.type != InternetAddressType.unix) {
          socket.setOption(SocketOption.tcpNoDelay, true);
        }

        X509Certificate? clientCertificate;

        if (socket is SecureSocket) {
          clientCertificate = socket.peerCertificate;
        }

        final connection = ServerTransportConnection.viaSocket(socket, settings: http2ServerSettings);
        _connectionSockets[connection] = socket;

        serveConnection(
          connection: connection,
          clientCertificate: clientCertificate,
          remoteAddress: socket.remoteAddressOrNull,
        );
      },
      onError: (error, stackTrace) {
        if (error is Error) {
          Zone.current.handleUncaughtError(error, stackTrace);
        }
        logGrpcEvent(
          '[gRPC] Server socket error: $error',
          component: 'Server',
          event: 'server_socket_error',
          context: 'serve',
          error: error,
        );
      },
    );
  }

  @override
  @visibleForTesting
  ServerHandler serveStream_({
    required ServerTransportStream stream,
    X509Certificate? clientCertificate,
    InternetAddress? remoteAddress,
    Sink<void>? onDataReceived,
  }) {
    return ServerHandler(
      stream: stream,
      serviceLookup: lookupService,
      interceptors: _interceptors,
      serverInterceptors: _serverInterceptors,
      codecRegistry: _codecRegistry,
      maxInboundMessageSize: _maxInboundMessageSize,
      // ignore: unnecessary_cast
      clientCertificate: clientCertificate as io_bits.X509Certificate?,
      // ignore: unnecessary_cast
      remoteAddress: remoteAddress as io_bits.InternetAddress?,
      errorHandler: _errorHandler,
      onDataReceived: onDataReceived,
    )..handle();
  }

  @Deprecated('This is internal functionality, and will be removed in next major version.')
  void serveStream(ServerTransportStream stream) {
    serveStream_(stream: stream);
  }

  Future<void> shutdown() async {
    // Close server sockets first to stop accepting new connections,
    // then drain active connections.
    final insecure = _insecureServer;
    final secure = _secureServer;
    _insecureServer = null;
    _secureServer = null;
    await Future.wait([if (insecure != null) insecure.close(), if (secure != null) secure.close()]);
    await shutdownActiveConnections();
  }
}

extension on Socket {
  InternetAddress? get remoteAddressOrNull {
    try {
      // Using a try-catch control flow as dart:io Sockets don't expose their
      // connectivity state.
      return remoteAddress;
    } on Exception catch (_) {
      return null;
    }
  }
}
