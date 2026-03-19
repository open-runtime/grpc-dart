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

// Stub for platforms that don't support dart:ffi (e.g. web).
// The real implementation is in named_pipe_channel.dart.
import 'channel.dart';
import 'connection.dart';
import 'options.dart';
import 'transport/http2_credentials.dart';

UnsupportedError _namedPipeChannelUnsupported(String member) {
  return UnsupportedError(
    '$member is not supported on this platform. '
    'Named pipes require dart:ffi, which is unavailable.',
  );
}

/// A gRPC client channel for Windows named pipes on FFI-capable platforms.
///
/// This stub is selected on platforms without `dart:ffi` support.
class NamedPipeClientChannel extends ClientChannelBase {
  /// The name of the pipe to connect to (without `\\.\pipe\` prefix).
  final String pipeName;

  /// Channel options (credentials, timeouts, etc.).
  final ChannelOptions options;

  /// Creates a named pipe client channel.
  NamedPipeClientChannel(this.pipeName, {this.options = const ChannelOptions(), super.channelShutdownHandler}) {
    throw _namedPipeChannelUnsupported('NamedPipeClientChannel');
  }

  /// The full Windows path for the named pipe.
  String get pipePath => r'\\.\pipe\' + pipeName;

  @override
  ClientConnection createConnection() {
    throw _namedPipeChannelUnsupported('NamedPipeClientChannel.createConnection');
  }
}

/// Channel options preset for local named pipe communication.
///
/// This type is kept for API compatibility on non-FFI platforms.
class NamedPipeChannelOptions extends ChannelOptions {
  const NamedPipeChannelOptions({
    super.idleTimeout,
    super.backoffStrategy,
    super.connectTimeout,
    super.connectionTimeout,
    super.codecRegistry,
    super.keepAlive,
    super.maxInboundMessageSize,
  }) : super(credentials: const ChannelCredentials.insecure(), proxy: null);
}
