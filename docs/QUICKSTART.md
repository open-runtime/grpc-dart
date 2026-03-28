# QUICKSTART

## 1. Overview
The `grpc` package provides a pure Dart implementation of gRPC for both clients and servers. It enables you to communicate between services using HTTP/2, support browser-based clients via gRPC-Web, and use secure local IPC mechanisms like Unix domain sockets and Windows named pipes. The library includes all the foundational building blocks required to run and consume gRPC services, including authentication, interceptors, error handling, and keep-alive configuration.

## 2. Import
Depending on your platform and requirements, you can import the appropriate entry points for the package. Always use the `package:grpc-dart/` prefix for imports in this module.

```dart
// Standard gRPC for native platforms (server and client)
import 'package:grpc-dart/grpc.dart';

// gRPC-Web exclusively for browser platforms
import 'package:grpc-dart/grpc_web.dart';

// Cross-platform client channel (automatically chooses HTTP/2 or gRPC-Web)
import 'package:grpc-dart/grpc_or_grpcweb.dart';

// Minimal API for generated service stubs (typically used by protoc-gen-dart)
import 'package:grpc-dart/service_api.dart';

// Provided Google RPC error details and protobuf Duration classes
import 'package:grpc-dart/protos.dart';
```

## 3. Setup

### Client Setup
To connect to a gRPC server, you configure a channel. Use `ClientChannel` for native apps, `GrpcWebClientChannel` for web, or `GrpcOrGrpcWebClientChannel` for cross-platform code:

```dart
import 'package:grpc-dart/grpc.dart';

final channel = ClientChannel(
  'api.example.com',
  port: 443,
  options: const ChannelOptions(
    credentials: ChannelCredentials.secure(),
    idleTimeout: Duration(minutes: 5),
  ),
);
```

### Server Setup
To create a standard HTTP/2 gRPC server, use the `Server.create` factory and pass in your generated service implementations:

```dart
import 'package:grpc-dart/grpc.dart';

// Assumes MyServiceImpl extends the generated Service class
final server = Server.create(
  services: [ /* MyServiceImpl() */ ],
  codecRegistry: CodecRegistry(codecs: const [GzipCodec(), IdentityCodec()]),
);
```

## 4. Common Operations

### Starting a gRPC Server
```dart
import 'package:grpc-dart/grpc.dart';

Future<void> main() async {
  final server = Server.create(services: [ /* MyServiceImpl() */ ]);
  await server.serve(port: 50051);
  print('Server listening on port ${server.port}...');
}
```

### Creating a Cross-Platform Client Channel
This channel automatically uses `ClientChannel` on native platforms and `GrpcWebClientChannel` on the web, making it ideal for Flutter projects.

```dart
import 'package:grpc-dart/grpc_or_grpcweb.dart';

final channel = GrpcOrGrpcWebClientChannel.toSingleEndpoint(
  host: 'api.example.com',
  port: 443,
  transportSecure: true,
);

// final stub = MyServiceClient(channel);
```

### Making a Call with Interceptors and Options
You can configure timeouts and metadata per-call using `CallOptions` and intercept operations using `ClientInterceptor`.

```dart
import 'package:grpc-dart/grpc.dart';

final options = CallOptions(
  timeout: Duration(seconds: 30),
  metadata: {'x-custom-header': 'value'},
);

// Example stub call:
// final response = await stub.myMethod(request, options: options);
```

### Error Handling with Rich Details
gRPC supports rich error details using the `google.rpc.Status` model. You can pack specific error information like `RetryInfo`, `ErrorInfo`, or `BadRequest` into your errors.

```dart
import 'package:fixnum/fixnum.dart';
import 'package:grpc-dart/grpc.dart';
import 'package:grpc-dart/protos.dart';

void handleGrpcError(GrpcError error) {
  print('Error code: ${error.code}');
  print('Error message: ${error.message}');

  if (error.details != null) {
    for (final detail in error.details!) {
      if (detail is RetryInfo) {
        // Clients should wait at least this long between retrying the same request.
        print('Retry delay: ${detail.retryDelay.seconds}s');
      } else if (detail is ErrorInfo) {
        // The reason of the error.
        print('Reason: ${detail.reason}');
        // The logical grouping to which the "reason" belongs.
        print('Domain: ${detail.domain}');
        // Additional structured details.
        detail.metadata.forEach((key, value) => print('$key: $value'));
      } else if (detail is BadRequest) {
        for (final violation in detail.fieldViolations) {
          // A path leading to a field in the request body.
          print('Field: ${violation.field_1}');
          // A description of why the request element is bad.
          print('Description: ${violation.description}');
        }
      }
    }
  }
}

// Example of creating a rich error on the server:
GrpcError createRichError() {
  final errorInfo = ErrorInfo()
    ..reason = 'API_DISABLED'
    ..domain = 'googleapis.com'
    ..metadata['resource'] = 'projects/123';

  final retryInfo = RetryInfo()
    ..retryDelay = (Duration()..seconds = Int64(30));

  return GrpcError.custom(
    StatusCode.unavailable,
    'Service is currently disabled.',
    [errorInfo, retryInfo],
  );
}
```

### Setting up a Local IPC Server and Client
For local-only communication, use `LocalGrpcServer` and `LocalGrpcChannel` which automatically utilize Unix domain sockets (macOS/Linux) or Named Pipes (Windows).

```dart
import 'package:grpc-dart/grpc.dart';

// Server side
final localServer = LocalGrpcServer('my-service', services: [ /* MyServiceImpl() */ ]);
await localServer.serve();

// Client side
final localChannel = LocalGrpcChannel('my-service');
// final stub = MyServiceClient(localChannel);
```

## 5. Configuration

Various options can be provided when creating channels or servers to control their behavior:

*   **`ChannelOptions`**: Configures client timeouts (`connectTimeout`, `idleTimeout`), keep-alive (`keepAlive` using `ClientKeepAliveOptions`), backoff strategy (`backoffStrategy`), max inbound message size (`maxInboundMessageSize`), and security (`credentials` using `ChannelCredentials`).
*   **`ServerKeepAliveOptions`**: Configures server-side keep-alive behavior like `minIntervalBetweenPingsWithoutData` and `maxBadPings` to protect against DDoS.
*   **`CodecRegistry`**: Allows configuration of message compression mechanisms (e.g., `GzipCodec`, `IdentityCodec`).
*   **Authentication**: Configured via `ChannelCredentials` for TLS, or classes like `JwtServiceAccountAuthenticator`, `ComputeEngineAuthenticator`, and `ServiceAccountAuthenticator` from `package:grpc-dart/grpc.dart` for Google Cloud authentication workflows.

## 6. Message Types and Models
The package provides several built-in message types for common gRPC patterns, primarily available via `package:grpc-dart/protos.dart`. Dart protobuf generated code uses `camelCase` for field access.

### google.rpc.Status
A logical error model suitable for different programming environments.
- `code`: The status code (enum value of `google.rpc.Code`).
- `message`: A developer-facing error message (English).
- `details`: A list of messages that carry the error details (as `google.protobuf.Any`).

### google.rpc.RetryInfo
Describes when the clients can retry a failed request.
- `retryDelay`: Clients should wait at least this long before retrying.

### google.rpc.DebugInfo
Describes additional debugging info.
- `stackEntries`: The stack trace entries indicating where the error occurred.
- `detail`: Additional debugging information provided by the server.

### google.rpc.QuotaFailure
Describes how a quota check failed.
- `violations`: List of `Violation` messages.
  - `Violation.subject`: The subject on which the quota check failed.
  - `Violation.description`: A description of how the quota check failed.

### google.rpc.ErrorInfo
Describes the cause of the error with structured details.
- `reason`: A constant value identifying the proximate cause.
- `domain`: The logical grouping to which the "reason" belongs.
- `metadata`: Additional structured details about this error.

### google.rpc.PreconditionFailure
Describes what preconditions have failed.
- `violations`: List of `Violation` messages.
  - `Violation.type`: The type of PreconditionFailure (e.g., "TOS").
  - `Violation.subject`: The subject relative to the type that failed.
  - `Violation.description`: A description of how the precondition failed.

### google.rpc.BadRequest
Describes violations in a client request (syntactic aspects).
- `fieldViolations`: List of `FieldViolation` messages.
  - `FieldViolation.field_1`: A path leading to a field in the request body. (*Note: suffixed with _1 to avoid conflict with Dart keyword*).
  - `FieldViolation.description`: A description of why the request element is bad.

### google.rpc.RequestInfo
Contains metadata about the request for filing bugs or feedback.
- `requestId`: An opaque string identifying the request in service logs.
- `servingData`: Any data used to serve this request.

### google.rpc.ResourceInfo
Describes the resource being accessed.
- `resourceType`: A name for the type of resource.
- `resourceName`: The name of the resource being accessed.
- `owner`: The owner of the resource (optional).
- `description`: Describes what error is encountered when accessing this resource.

### google.rpc.Help
Provides links to documentation or out-of-band actions.
- `links`: List of `Link` messages.
  - `Link.description`: Describes what the link offers.
  - `Link.url`: The URL of the link.

### google.rpc.LocalizedMessage
Provides a localized error message safe to return to the user.
- `locale`: The locale used (e.g., "en-US").
- `message`: The localized error message.

### google.protobuf.Duration
A signed, fixed-length span of time.
- `seconds`: Signed seconds of the span.
- `nanos`: Signed fractions of a second at nanosecond resolution.

### google.protobuf.Any
Contains an arbitrary serialized protocol buffer message along with a URL.
- `typeUrl`: A URL/resource name uniquely identifying the type of the serialized message.
- `value`: Must be a valid serialized protocol buffer of the specified type.

## 7. Related Modules

*   **Protobuf Generator**: To generate the Dart stubs for your `Service` and `Client` classes, you will use the `protoc_plugin` package. The generated code relies heavily on the `package:grpc-dart/service_api.dart` and `package:grpc-dart/protos.dart` imports.
