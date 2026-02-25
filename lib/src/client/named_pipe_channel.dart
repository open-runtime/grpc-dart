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

import '../shared/named_pipe_io.dart';
import 'channel.dart';
import 'connection.dart';
import 'http2_connection.dart' show Http2ClientConnection;
import 'named_pipe_transport.dart';
import 'options.dart';
import 'transport/http2_credentials.dart';

/// A gRPC client channel that communicates over Windows named pipes.
///
/// Named pipes provide secure, local-only IPC on Windows. They are the
/// Windows equivalent of Unix domain sockets.
///
/// ## Usage
///
/// ```dart
/// // Connect to a named pipe server
/// final channel = NamedPipeClientChannel('my-service-12345');
/// final stub = MyServiceClient(channel);
///
/// // Make RPC calls
/// final response = await stub.myMethod(request);
///
/// // Clean up
/// await channel.shutdown();
/// ```
///
/// ## Platform Support
///
/// This channel only works on Windows. On macOS/Linux, use Unix domain sockets
/// with the regular [ClientChannel]:
///
/// ```dart
/// // Unix domain socket (macOS/Linux)
/// final channel = ClientChannel(
///   InternetAddress('/tmp/my-service.sock', type: InternetAddressType.unix),
///   port: 0,
///   options: ChannelOptions(credentials: ChannelCredentials.insecure()),
/// );
/// ```
///
/// ## Security
///
/// Named pipes are inherently local-only and cannot be accessed over the
/// network. The server uses PIPE_REJECT_REMOTE_CLIENTS to prevent any
/// attempt at SMB-based remote access.
class NamedPipeClientChannel extends ClientChannelBase {
  /// The name of the pipe to connect to (without `\\.\pipe\` prefix).
  final String pipeName;

  /// Channel options (credentials, timeouts, etc.).
  final ChannelOptions options;

  /// Creates a named pipe client channel.
  ///
  /// [pipeName] is the name of the pipe (e.g., 'my-service-12345').
  /// The full path will be `\\.\pipe\{pipeName}`.
  ///
  /// [options] controls connection behavior. Note that credentials are
  /// typically not used with named pipes since they are local-only.
  /// Use [ChannelOptions] with [ChannelCredentials.insecure()] for
  /// most local IPC scenarios.
  NamedPipeClientChannel(this.pipeName, {this.options = const ChannelOptions(), super.channelShutdownHandler});

  /// The full Windows path for the named pipe.
  String get pipePath => namedPipePath(pipeName);

  @override
  ClientConnection createConnection() {
    final connector = NamedPipeTransportConnector(pipeName);
    return Http2ClientConnection.fromClientTransportConnector(connector, options);
  }
}

/// Channel options preset for local named pipe communication.
///
/// This preset disables TLS (since named pipes are inherently secure for
/// local communication) and adjusts timeouts for local IPC.
class NamedPipeChannelOptions extends ChannelOptions {
  const NamedPipeChannelOptions({
    super.idleTimeout,
    super.backoffStrategy,
    super.connectTimeout,
    super.connectionTimeout,
    super.codecRegistry,
    super.keepAlive,
  }) : super(
         // Named pipes are local-only, so no TLS needed
         credentials: const ChannelCredentials.insecure(),
         // No proxy support for named pipes
         proxy: null,
       );
}
