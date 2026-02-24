// Copyright (c) 2025, Tsavo Knott, Mesh Intelligent Technologies, Inc. dba
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
}
