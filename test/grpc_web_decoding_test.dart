// Copyright (c) 2024, the gRPC project authors. Please see the AUTHORS file
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
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:grpc/src/client/transport/web_streams.dart';
import 'package:test/test.dart';

void main() {
  test('decoding an empty repeated', () async {
    final data =
        await GrpcWebDecoder()
                .bind(
                  Stream.fromIterable([
                    Uint8List.fromList([0, 0, 0, 0, 0]).buffer,
                  ]),
                )
                .first
            as GrpcData;
    expect(data.data, []);
  });

  test('decoding a message larger than 4MB succeeds by default', () async {
    const payloadLength = 4 * 1024 * 1024 + 1;
    final payload = Uint8List(5 + payloadLength)
      ..[0] = 0x00
      ..[1] = 0x00
      ..[2] = 0x40
      ..[3] = 0x00
      ..[4] = 0x01;

    final data = await GrpcWebDecoder().bind(Stream.value(payload.buffer)).first as GrpcData;
    expect(data.data.length, equals(payloadLength));
  });

  test('decoding rejects oversized message when limit is configured', () async {
    final payload = Uint8List.fromList([0x00, 0x00, 0x00, 0x00, 0x05]);
    await expectLater(
      GrpcWebDecoder(maxInboundMessageSize: 4).bind(Stream.value(payload.buffer)).drain<void>(),
      throwsA(
        isA<GrpcError>()
            .having((e) => e.code, 'code', StatusCode.resourceExhausted)
            .having((e) => e.message, 'message', contains('Received message larger than max')),
      ),
    );
  });
}
