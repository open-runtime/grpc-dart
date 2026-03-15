// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba.,
// Pieces.app. All rights reserved.
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

import 'dart:io';

import '../shared/codec_registry.dart';
import '../shared/local_ipc.dart';
import 'call.dart';
import 'channel.dart' show ClientChannel, ClientChannelBase;
import 'client_keepalive.dart';
import 'connection.dart';
import 'http2_channel.dart' as http2;
import 'method.dart';
import 'named_pipe_channel_stub.dart' if (dart.library.ffi) 'named_pipe_channel.dart';
import 'options.dart';
import 'transport/http2_credentials.dart';

/// Options for [LocalGrpcChannel].
///
/// Pre-configures insecure credentials and no proxy. Exposes only the
/// settings that make sense for local IPC.
class LocalChannelOptions {
  final Duration? connectTimeout;
  final Duration connectionTimeout;
  final Duration idleTimeout;
  final BackoffStrategy backoffStrategy;
  final ClientKeepAliveOptions keepAlive;
  final CodecRegistry? codecRegistry;
  final int? maxInboundMessageSize;

  const LocalChannelOptions({
    this.connectTimeout = const Duration(seconds: 5),
    this.connectionTimeout = defaultConnectionTimeOut,
    this.idleTimeout = defaultIdleTimeout,
    this.backoffStrategy = defaultBackoffStrategy,
    this.keepAlive = const ClientKeepAliveOptions(),
    this.codecRegistry,
    this.maxInboundMessageSize,
  });

  ChannelOptions toChannelOptions() => ChannelOptions(
    credentials: const ChannelCredentials.insecure(),
    connectTimeout: connectTimeout,
    connectionTimeout: connectionTimeout,
    idleTimeout: idleTimeout,
    backoffStrategy: backoffStrategy,
    keepAlive: keepAlive,
    codecRegistry: codecRegistry,
    maxInboundMessageSize: maxInboundMessageSize,
    proxy: null,
  );
}

/// A local-only gRPC client channel that uses the best IPC transport.
///
/// - macOS/Linux: Unix domain sockets
/// - Windows: Named pipes
///
/// ```dart
/// final channel = LocalGrpcChannel('my-service');
/// final stub = MyServiceClient(channel);
/// final response = await stub.myMethod(request);
/// await channel.shutdown();
/// ```
///
/// The [serviceName] must match the name used by `LocalGrpcServer`.
///
/// **Security**: Uses plaintext credentials (no TLS). This is safe for
/// same-machine IPC where the OS kernel is the trust boundary. Do not
/// use this channel for communication over a network.
class LocalGrpcChannel implements ClientChannel {
  /// The service name used for address resolution.
  final String serviceName;

  final ClientChannelBase _delegate;

  /// Creates a local gRPC channel.
  ///
  /// [serviceName] must match the server's service name.
  factory LocalGrpcChannel(
    String serviceName, {
    LocalChannelOptions options = const LocalChannelOptions(),
    void Function()? channelShutdownHandler,
  }) {
    validateServiceName(serviceName);

    final ClientChannelBase delegate;
    if (Platform.isWindows) {
      delegate = NamedPipeClientChannel(
        serviceName,
        options: NamedPipeChannelOptions(
          connectTimeout: options.connectTimeout,
          connectionTimeout: options.connectionTimeout,
          idleTimeout: options.idleTimeout,
          backoffStrategy: options.backoffStrategy,
          keepAlive: options.keepAlive,
          codecRegistry: options.codecRegistry,
          maxInboundMessageSize: options.maxInboundMessageSize,
        ),
        channelShutdownHandler: channelShutdownHandler,
      );
    } else {
      delegate = http2.ClientChannel(
        InternetAddress(udsSocketPath(serviceName), type: InternetAddressType.unix),
        port: 0,
        options: options.toChannelOptions(),
        channelShutdownHandler: channelShutdownHandler,
      );
    }

    return LocalGrpcChannel._(serviceName, delegate);
  }

  LocalGrpcChannel._(this.serviceName, this._delegate);

  /// The resolved IPC address (socket path or pipe path).
  String get address {
    final d = _delegate;
    if (d is NamedPipeClientChannel) return d.pipePath;
    return udsSocketPath(serviceName);
  }

  @override
  Future<void> shutdown() => _delegate.shutdown();

  @override
  Future<void> terminate() => _delegate.terminate();

  @override
  ClientCall<Q, R> createCall<Q, R>(ClientMethod<Q, R> method, Stream<Q> requests, CallOptions options) =>
      _delegate.createCall(method, requests, options);

  @override
  Stream<ConnectionState> get onConnectionStateChanged => _delegate.onConnectionStateChanged;
}
