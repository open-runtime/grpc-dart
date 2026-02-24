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

/// Shared EchoClient and EchoService test doubles used across transport and
/// named-pipe stress tests.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';

// =============================================================================
// Test Client
// =============================================================================

class EchoClient extends Client {
  static final _$echo = ClientMethod<int, int>(
    '/test.EchoService/Echo',
    (int value) => [value],
    (List<int> value) => value[0],
  );

  static final _$serverStream = ClientMethod<int, int>(
    '/test.EchoService/ServerStream',
    (int value) => [value],
    (List<int> value) => value[0],
  );

  static final _$clientStream = ClientMethod<int, int>(
    '/test.EchoService/ClientStream',
    (int value) => [value],
    (List<int> value) => value[0],
  );

  static final _$bidiStream = ClientMethod<int, int>(
    '/test.EchoService/BidiStream',
    (int value) => [value],
    (List<int> value) => value[0],
  );

  // -- Large payload methods (identity serialization) --

  static final _$echoBytes = ClientMethod<List<int>, List<int>>(
    '/test.EchoService/EchoBytes',
    (List<int> value) => value,
    (List<int> value) => value,
  );

  static final _$serverStreamBytes = ClientMethod<List<int>, List<int>>(
    '/test.EchoService/ServerStreamBytes',
    (List<int> value) => value,
    (List<int> value) => value,
  );

  static final _$bidiStreamBytes = ClientMethod<List<int>, List<int>>(
    '/test.EchoService/BidiStreamBytes',
    (List<int> value) => value,
    (List<int> value) => value,
  );

  EchoClient(super.channel);

  ResponseFuture<int> echo(int request, {CallOptions? options}) {
    return $createUnaryCall(_$echo, request, options: options);
  }

  ResponseStream<int> serverStream(int request, {CallOptions? options}) {
    return $createStreamingCall(
      _$serverStream,
      Stream.value(request),
      options: options,
    );
  }

  ResponseFuture<int> clientStream(
    Stream<int> requests, {
    CallOptions? options,
  }) {
    return $createStreamingCall(
      _$clientStream,
      requests,
      options: options,
    ).single;
  }

  ResponseStream<int> bidiStream(Stream<int> requests, {CallOptions? options}) {
    return $createStreamingCall(_$bidiStream, requests, options: options);
  }

  /// Echoes raw bytes back. Use for large payload testing (>64KB).
  ResponseFuture<List<int>> echoBytes(
    List<int> request, {
    CallOptions? options,
  }) {
    return $createUnaryCall(_$echoBytes, request, options: options);
  }

  /// Server-streams byte chunks. Request: 8 bytes big-endian
  /// [chunkCount(4), chunkSize(4)]. Each response is chunkSize bytes
  /// filled with (chunkIndex & 0xFF).
  ResponseStream<List<int>> serverStreamBytes(
    List<int> request, {
    CallOptions? options,
  }) {
    return $createStreamingCall(
      _$serverStreamBytes,
      Stream.value(request),
      options: options,
    );
  }

  /// Bidirectional byte echo — each received chunk is echoed back.
  ResponseStream<List<int>> bidiStreamBytes(
    Stream<List<int>> requests, {
    CallOptions? options,
  }) {
    return $createStreamingCall(_$bidiStreamBytes, requests, options: options);
  }
}

// =============================================================================
// Test Service
// =============================================================================

class EchoService extends Service {
  @override
  String get $name => 'test.EchoService';

  EchoService() {
    $addMethod(
      ServiceMethod<int, int>(
        'Echo',
        _echo,
        false,
        false,
        (List<int> value) => value[0],
        (int value) => [value],
      ),
    );
    $addMethod(
      ServiceMethod<int, int>(
        'ServerStream',
        _serverStream,
        false,
        true,
        (List<int> value) => value[0],
        (int value) => [value],
      ),
    );
    $addMethod(
      ServiceMethod<int, int>(
        'ClientStream',
        _clientStream,
        true,
        false,
        (List<int> value) => value[0],
        (int value) => [value],
      ),
    );
    $addMethod(
      ServiceMethod<int, int>(
        'BidiStream',
        _bidiStream,
        true,
        true,
        (List<int> value) => value[0],
        (int value) => [value],
      ),
    );

    // -- Large payload methods (identity serialization) --
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'EchoBytes',
        _echoBytes,
        false,
        false,
        (List<int> value) => value,
        (List<int> value) => value,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'ServerStreamBytes',
        _serverStreamBytes,
        false,
        true,
        (List<int> value) => value,
        (List<int> value) => value,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'BidiStreamBytes',
        _bidiStreamBytes,
        true,
        true,
        (List<int> value) => value,
        (List<int> value) => value,
      ),
    );
  }

  Future<int> _echo(ServiceCall call, Future<int> request) async {
    return await request;
  }

  Stream<int> _serverStream(ServiceCall call, Future<int> request) async* {
    final count = await request;
    for (var i = 1; i <= count; i++) {
      yield i;
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<int> _clientStream(ServiceCall call, Stream<int> requests) async {
    var sum = 0;
    await for (final value in requests) {
      sum += value;
    }
    return sum;
  }

  Stream<int> _bidiStream(ServiceCall call, Stream<int> requests) async* {
    await for (final value in requests) {
      yield value * 2;
    }
  }

  /// Echoes raw bytes back unchanged.
  Future<List<int>> _echoBytes(
    ServiceCall call,
    Future<List<int>> request,
  ) async {
    return await request;
  }

  /// Server-streams byte chunks. Request: 8 bytes big-endian
  /// [chunkCount(4), chunkSize(4)]. Each response chunk is chunkSize bytes
  /// filled with (chunkIndex & 0xFF) for integrity verification.
  Stream<List<int>> _serverStreamBytes(
    ServiceCall call,
    Future<List<int>> request,
  ) async* {
    final req = await request;
    final bd = ByteData.sublistView(Uint8List.fromList(req));
    final chunkCount = bd.getUint32(0);
    final chunkSize = bd.getUint32(4);
    for (var i = 0; i < chunkCount; i++) {
      final chunk = Uint8List(chunkSize);
      // Fill with repeating pattern for integrity verification.
      for (var j = 0; j < chunkSize; j++) {
        chunk[j] = (i + j) & 0xFF;
      }
      yield chunk;
    }
  }

  /// Bidirectional byte echo — returns each received chunk unchanged.
  Stream<List<int>> _bidiStreamBytes(
    ServiceCall call,
    Stream<List<int>> requests,
  ) async* {
    await for (final chunk in requests) {
      yield chunk;
    }
  }
}
