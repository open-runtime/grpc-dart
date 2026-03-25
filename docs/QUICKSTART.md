# gRPC Dart Quickstart

## 1. Overview
The `grpc` module provides a pure-Dart implementation of the gRPC framework for building robust, cross-platform APIs. It features support for both clients and servers, HTTP/2 multiplexing, local IPC (Unix Domain Sockets / Windows Named Pipes), interceptors, and gRPC-Web.

## 2. Import
Depending on your target platform and features, use one of the following imports:

```dart
// Core gRPC library for clients, servers, and IPC
import 'package:grpc-dart/grpc.dart';

// For browser applications using gRPC-Web
import 'package:grpc-dart/grpc_web.dart';

// Automatic selection between gRPC (native) and gRPC-Web (browser)
import 'package:grpc-dart/grpc_or_grpcweb.dart';

// Optional: For pre-generated protobuf error details and durations
import 'package:grpc-dart/protos.dart';
```

## 3. Setup
gRPC heavily relies on generated code. While the `protoc` compiler typically generates your `Service` and `Client` stubs, the following examples illustrate how to construct and configure the underlying `Server` and `ClientChannel`.

```dart
import 'package:grpc-dart/grpc.dart';

// 1. Setting up a client channel
final channel = ClientChannel(
  'localhost',
  port: 50051,
  options: const ChannelOptions(
    credentials: ChannelCredentials.insecure(),
  ),
);

// 2. Setting up a server
final server = Server.create(
  services: [], // Add your generated services here
  codecRegistry: CodecRegistry(
    codecs: const [GzipCodec(), IdentityCodec()],
  ),
);
```

## 4. Constructing Messages
Protobuf messages in Dart are best constructed using the cascade operator (`..`) for a clean, builder-like syntax.

```dart
import 'package:fixnum/fixnum.dart';
import 'package:grpc-dart/protos.dart';

// Constructing a RetryInfo message
final retryInfo = RetryInfo()
  ..retryDelay = (Duration()
    ..seconds = Int64(5)
    ..nanos = 0);

// Constructing a BadRequest message with multiple field violations
final badRequest = BadRequest()
  ..fieldViolations.addAll([
    BadRequest_FieldViolation()
      ..field_1 = 'email'
      ..description = 'Invalid email format',
    BadRequest_FieldViolation()
      ..field_1 = 'password'
      ..description = 'Password too short',
  ]);
```

## 5. Common Operations

> **Note:** `MyService` and `MyClient` in these examples represent the stubs that are typically generated for you by `protoc`.

### Starting a Server
```dart
import 'dart:async';
import 'package:grpc-dart/grpc.dart';

class MyService extends Service {
  @override
  String get $name => 'MyService';

  MyService() {
    $addMethod(ServiceMethod<int, int>(
      'MyMethod',
      _myMethod,
      false,
      false,
      (List<int> request) => request.isNotEmpty ? request[0] : 0,
      (int response) => [response],
    ));
  }

  Future<int> _myMethod(ServiceCall call, int request) async {
    return request * 2;
  }
}

Future<void> main() async {
  final server = Server.create(services: [MyService()]);
  await server.serve(port: 50051);
  print('Server listening on port ${server.port}...');
}
```

### Making a Client Call
```dart
import 'dart:async';
import 'package:grpc-dart/grpc.dart';

class MyClient extends Client {
  MyClient(ClientChannel channel) : super(channel);

  ResponseFuture<int> myMethod(int request, {CallOptions? options}) {
    final method = ClientMethod<int, int>(
      '/MyService/MyMethod',
      (int value) => [value],
      (List<int> value) => value.isNotEmpty ? value[0] : 0,
    );
    return $createUnaryCall(method, request, options: options);
  }
}

Future<void> main() async {
  final channel = ClientChannel(
    'localhost',
    port: 50051,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  
  final client = MyClient(channel);
  
  try {
    final response = await client.myMethod(
      42, 
      options: CallOptions(timeout: const Duration(seconds: 5)),
    );
    print('Response: $response');
  } on GrpcError catch (e) {
    print('gRPC Error: ${e.codeName} - ${e.message}');
  } finally {
    await channel.shutdown();
  }
}
```

### Connecting via gRPC-Web
For web applications, use `GrpcWebClientChannel` or `GrpcOrGrpcWebClientChannel`.

```dart
import 'package:grpc-dart/grpc_web.dart';

Future<void> main() async {
  final channel = GrpcWebClientChannel.xhr(
    Uri.parse('https://localhost:8080'),
  );

  // In a real application: 
  // final client = MyClient(channel);
  // await client.myMethod(42, options: WebCallOptions(bypassCorsPreflight: true));
}
```

### Using Local IPC
You can easily create secure, local-only communication across Unix Domain Sockets (macOS/Linux) and Named Pipes (Windows).

```dart
import 'package:grpc-dart/grpc.dart';

Future<void> main() async {
  // Start a local IPC server
  final server = LocalGrpcServer('my-ipc-service', services: []);
  await server.serve();
  
  // Connect via a local IPC channel
  final channel = LocalGrpcChannel('my-ipc-service');
  // final client = MyClient(channel);
}
```


## 6. Configuration
The package can be finely tuned using various option objects:

- **`ChannelOptions`**: Configures the `ClientChannel` with properties like `credentials` (e.g., `ChannelCredentials.secure()`), `idleTimeout`, and `backoffStrategy`.
- **`CallOptions`**: Used per RPC to set custom `metadata`, specify a `timeout`, or apply a specific `compression` codec.
- **`WebCallOptions`**: Extended options for gRPC-Web calls to handle CORS via parameters like `bypassCorsPreflight` and `withCredentials`.
- **`ServerKeepAliveOptions`**: Defines ping intervals and bad-ping limits to protect the server from DDoS and keep connections alive.
- **`CodecRegistry`**: Allows payload compression configuring codecs like `GzipCodec` and `IdentityCodec`.

## 7. Included Protobuf Messages
The package provides pre-generated standard Google protobuf messages (from `google/protobuf` and `google/rpc`) that are commonly used within gRPC error details. Use `import 'package:grpc-dart/protos.dart';` to access these models.

### `Any` (from `google/protobuf/any.proto`)
Contains an arbitrary serialized protocol buffer message along with a URL that describes the type.
- `typeUrl` (`String`): A URL/resource name that uniquely identifies the type.
- `value` (`List<int>`): Must be a valid serialized protocol buffer of the above specified type.

### `Duration` (from `google/protobuf/duration.proto`)
Represents a signed, fixed-length span of time.
- `seconds` (`Int64`): Signed seconds of the span of time. Must be from -315,576,000,000 to +315,576,000,000 inclusive.
- `nanos` (`int`): Signed fractions of a second at nanosecond resolution of the span of time. Must be from -999,999,999 to +999,999,999 inclusive.

### `Status` (from `google/rpc/status.proto`)
Defines a logical error model suitable for REST and RPC APIs.
- `code` (`int`): The status code, which should be an enum value of `google.rpc.Code` (see `StatusCode` in `grpc-dart`).
- `message` (`String`): A developer-facing error message, which should be in English.
- `details` (`List<Any>`): A list of messages that carry the error details.

### `RetryInfo` (from `google/rpc/error_details.proto`)
Describes when the clients can retry a failed request.
- `retryDelay` (`Duration`): Clients should wait at least this long between retrying the same request.

### `DebugInfo` (from `google/rpc/error_details.proto`)
Describes additional debugging info.
- `stackEntries` (`List<String>`): The stack trace entries indicating where the error occurred.
- `detail` (`String`): Additional debugging information provided by the server.

### `QuotaFailure` (from `google/rpc/error_details.proto`)
Describes how a quota check failed.
- `violations` (`List<QuotaFailure_Violation>`): Describes all quota violations.

### `QuotaFailure_Violation` (from `google/rpc/error_details.proto`)
- `subject` (`String`): The subject on which the quota check failed.
- `description` (`String`): A description of how the quota check failed.

### `ErrorInfo` (from `google/rpc/error_details.proto`)
Describes the cause of the error with structured details.
- `reason` (`String`): The reason of the error.
- `domain` (`String`): The logical grouping to which the "reason" belongs.
- `metadata` (`Map<String, String>`): Additional structured details about this error.

### `PreconditionFailure` (from `google/rpc/error_details.proto`)
Describes what preconditions have failed.
- `violations` (`List<PreconditionFailure_Violation>`): Describes all precondition violations.

### `PreconditionFailure_Violation` (from `google/rpc/error_details.proto`)
- `type` (`String`): The type of PreconditionFailure.
- `subject` (`String`): The subject, relative to the type, that failed.
- `description` (`String`): A description of how the precondition failed.

### `BadRequest` (from `google/rpc/error_details.proto`)
Describes violations in a client request.
- `fieldViolations` (`List<BadRequest_FieldViolation>`): Describes all violations in a client request.

### `BadRequest_FieldViolation` (from `google/rpc/error_details.proto`)
- `field_1` (`String`): A path leading to a field in the request body. *(Note: Generated as `field_1` in Dart to avoid conflicts).*
- `description` (`String`): A description of why the request element is bad.

### `RequestInfo` (from `google/rpc/error_details.proto`)
Contains metadata about the request that clients can attach when filing a bug.
- `requestId` (`String`): An opaque string that should only be interpreted by the service generating it.
- `servingData` (`String`): Any data that was used to serve this request.

### `ResourceInfo` (from `google/rpc/error_details.proto`)
Describes the resource that is being accessed.
- `resourceType` (`String`): A name for the type of resource being accessed.
- `resourceName` (`String`): The name of the resource being accessed.
- `owner` (`String`): The owner of the resource (optional).
- `description` (`String`): Describes what error is encountered when accessing this resource.

### `Help` (from `google/rpc/error_details.proto`)
Provides links to documentation or for performing an out of band action.
- `links` (`List<Help_Link>`): URL(s) pointing to additional information.

### `Help_Link` (from `google/rpc/error_details.proto`)
- `description` (`String`): Describes what the link offers.
- `url` (`String`): The URL of the link.

### `LocalizedMessage` (from `google/rpc/error_details.proto`)
Provides a localized error message that is safe to return to the user.
- `locale` (`String`): The locale used following the specification defined at http://www.rfc-editor.org/rfc/bcp/bcp47.txt.
- `message` (`String`): The localized error message in the above locale.

## 8. Advanced Error Handling
gRPC Dart allows you to attach structured error details to your RPC responses using the `google.rpc.Status` model.

```dart
import 'package:grpc-dart/grpc.dart';
import 'package:grpc-dart/protos.dart';

// Server-side: Throwing a detailed error
Future<void> handleRequest() async {
  final status = Status()
    ..code = StatusCode.invalidArgument
    ..message = 'Invalid request parameters'
    ..details.add(Any.pack(BadRequest()
      ..fieldViolations.add(BadRequest_FieldViolation()
        ..field_1 = 'user_id'
        ..description = 'Must be a valid UUID')));

  throw GrpcError.custom(
    status.code,
    status.message,
    status.details,
  );
}

// Client-side: Handling a detailed error
try {
  await stub.someMethod(request);
} on GrpcError catch (e) {
  print('Error: ${e.message}');
  if (e.details != null) {
    for (final detail in e.details!) {
      if (detail is BadRequest) {
        for (final violation in detail.fieldViolations) {
          print('Violation on ${violation.field_1}: ${violation.description}');
        }
      }
    }
  }
}
```

## 9. Related Modules
- **`googleapis_auth`**: Helpful for generating OAuth 2.0 access credentials using `ServiceAccountAuthenticator` or `ComputeEngineAuthenticator` which can be injected into client calls via the `CallOptions` providers.
- **`protobuf`**: Essential for generating and representing strongly-typed messages using Google's protocol buffers compiler (`protoc`).
