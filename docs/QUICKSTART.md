# QUICKSTART: Package Entry Points

## 1. Overview
The Package Entry Points module provides the core API surface for building robust gRPC clients and servers in Dart. It offers cross-platform channels for native and web execution, IPC capabilities via Unix Domain Sockets and Windows Named Pipes, server configuration tools, interceptors, and complete Dart representations of standard Google Protocol Buffer well-known types (such as `Duration`, `Any`, and detailed `Status` errors).

## 2. Import
Depending on your application type, use one of the following real import paths:

```dart
// Native client, server, and core gRPC utilities
import 'package:grpc/grpc.dart';

// Web-specific client utilities
import 'package:grpc/grpc_web.dart';

// Cross-platform channel (auto-switches between native and gRPC-Web)
import 'package:grpc/grpc_or_grpcweb.dart';

// Standard Google protobuf types (e.g., Duration, ErrorInfo, etc.)
import 'package:grpc/protos.dart';

// Specific imports for Any and Status types
import 'package:grpc/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc/src/generated/google/rpc/status.pb.dart';

// Minimum API exports required for generated client/server stubs
import 'package:grpc/service_api.dart';
```

## 3. Setup

### Client Setup
To create a client channel that seamlessly handles both Native (HTTP/2) and Web (gRPC-Web) environments, instantiate `GrpcOrGrpcWebClientChannel`:

```dart
final channel = GrpcOrGrpcWebClientChannel.grpc(
  'api.example.com',
  port: 443,
  options: ChannelOptions(
    credentials: ChannelCredentials.secure(),
  ),
);
```

### Server Setup
To configure and start a gRPC server on native platforms, use `Server.create`:

```dart
final server = Server.create(
  services: [ /* Provide your Service implementations here */ ],
  interceptors: [ /* Add global ServerInterceptor instances */ ],
  codecRegistry: CodecRegistry(codecs: const [GzipCodec(), IdentityCodec()]),
);

await server.serve(port: 8080);
print('Server is listening on port ${server.port}');
```

## 4. Common Operations

### Authentication
Attach credentials dynamically using HTTP-based authenticators. The module provides `ServiceAccountAuthenticator`, `ComputeEngineAuthenticator`, and `JwtServiceAccountAuthenticator`.

```dart
final authenticator = ServiceAccountAuthenticator(serviceAccountJsonString, ['https://www.googleapis.com/auth/cloud-platform']);
final callOptions = authenticator.toCallOptions;
```

### Local Inter-Process Communication (IPC)
Establish local-only connections without network overhead using `LocalGrpcServer` and `LocalGrpcChannel`:

```dart
// Server
final localServer = LocalGrpcServer('my-service', services: [ /* services */ ]);
await localServer.serve();

// Client
final localChannel = LocalGrpcChannel('my-service', options: LocalChannelOptions());
```

### Protocol Buffer Types and RPC Error Handling
The module exports fully-featured `google.protobuf` and `google.rpc` types to build structured, well-known responses and complex error payloads. 

Below is an exhaustive example showcasing **every** message, field, and type defined by the module's included protocol buffer sources. All examples use proper cascade notation and apply camelCase field access as per Dart conventions.

```dart
import 'package:fixnum/fixnum.dart';

// 1. Any (google/protobuf/any.proto)
// `Any` contains an arbitrary serialized protocol buffer message along with a
// URL that describes the type of the serialized message.
final anyMessage = Any()
  // A URL/resource name that uniquely identifies the type of the serialized
  // protocol buffer message.
  ..typeUrl = 'type.googleapis.com/my.custom.Message'
  // Must be a valid serialized protocol buffer of the above specified type.
  ..value = <int>[1, 2, 3];

// Example of packing a generated message into an Any
// Note: Duration is used as an example GeneratedMessage
final myDuration = Duration()..seconds = Int64(60);
final packedAny = Any.pack(myDuration);

// 2. Duration (google/protobuf/duration.proto)
// A Duration represents a signed, fixed-length span of time represented
// as a count of seconds and fractions of seconds at nanosecond resolution.
final duration = Duration()
  // Signed seconds of the span of time. Must be from -315,576,000,000
  // to +315,576,000,000 inclusive.
  ..seconds = Int64(60)
  // Signed fractions of a second at nanosecond resolution of the span
  // of time. Must be from -999,999,999 to +999,999,999 inclusive.
  ..nanos = 500000;

// Duration provides helper methods for Dart's core Duration
final dartDuration = duration.toDart();
final fromDart = Duration.fromDart(dartDuration);

// 3. Status (google/rpc/status.proto)
// The `Status` type defines a logical error model that is suitable for
// different programming environments, including REST APIs and RPC APIs.
final status = Status()
  // The status code, which should be an enum value of google.rpc.Code.
  ..code = StatusCode.notFound
  // A developer-facing error message, which should be in English.
  ..message = 'Resource not found'
  // A list of messages that carry the error details.
  ..details.add(anyMessage);

// 4. RetryInfo (google/rpc/error_details.proto)
// Describes when the clients can retry a failed request.
final retryInfo = RetryInfo()
  // Clients should wait at least this long between retrying the same request.
  ..retryDelay = duration;

// 5. DebugInfo (google/rpc/error_details.proto)
// Describes additional debugging info.
final debugInfo = DebugInfo()
  // The stack trace entries indicating where the error occurred.
  ..stackEntries.addAll(['src/client/call.dart:123', 'src/server/handler.dart:456'])
  // Additional debugging information provided by the server.
  ..detail = 'Internal pipeline exception';

// 6. QuotaFailure and QuotaFailure_Violation (google/rpc/error_details.proto)
// Describes how a quota check failed.
final quotaViolation = QuotaFailure_Violation()
  // The subject on which the quota check failed.
  ..subject = 'clientip:192.168.1.1'
  // A description of how the quota check failed.
  ..description = 'Daily Limit for read operations exceeded';

final quotaFailure = QuotaFailure()
  // Describes all quota violations.
  ..violations.add(quotaViolation);

// 7. ErrorInfo (google/rpc/error_details.proto)
// Describes the cause of the error with structured details.
final errorInfo = ErrorInfo()
  // The reason of the error. This is a constant value that identifies the
  // proximate cause of the error.
  ..reason = 'API_DISABLED'
  // The logical grouping to which the "reason" belongs.
  ..domain = 'googleapis.com'
  // Additional structured details about this error.
  ..metadata.addAll({'service': 'pubsub.googleapis.com'});

// 8. PreconditionFailure and PreconditionFailure_Violation (google/rpc/error_details.proto)
// Describes what preconditions have failed.
final preconditionViolation = PreconditionFailure_Violation()
  // The type of PreconditionFailure.
  ..type = 'TOS'
  // The subject, relative to the type, that failed.
  ..subject = 'google.com/cloud'
  // A description of how the precondition failed.
  ..description = 'Terms of service not accepted';

final preconditionFailure = PreconditionFailure()
  // Describes all precondition violations.
  ..violations.add(preconditionViolation);

// 9. BadRequest and BadRequest_FieldViolation (google/rpc/error_details.proto)
// Describes violations in a client request.
// Note: 'field' is translated to 'field_1' in Dart to avoid conflicts.
final fieldViolation = BadRequest_FieldViolation()
  // A path leading to a field in the request body.
  ..field_1 = 'request.id'
  // A description of why the request element is bad.
  ..description = 'ID must be a positive integer';

final badRequest = BadRequest()
  // Describes all violations in a client request.
  ..fieldViolations.add(fieldViolation);

// 10. RequestInfo (google/rpc/error_details.proto)
// Contains metadata about the request that clients can attach when filing a bug.
final requestInfo = RequestInfo()
  // An opaque string that should only be interpreted by the service generating it.
  ..requestId = 'req-123456789'
  // Any data that was used to serve this request.
  ..servingData = 'encrypted-stack-trace-data';

// 11. ResourceInfo (google/rpc/error_details.proto)
// Describes the resource that is being accessed.
final resourceInfo = ResourceInfo()
  // A name for the type of resource being accessed.
  ..resourceType = 'cloud storage bucket'
  // The name of the resource being accessed.
  ..resourceName = 'gs://my-bucket'
  // The owner of the resource (optional).
  ..owner = 'user:admin@example.com'
  // Describes what error is encountered when accessing this resource.
  ..description = 'Bucket requires writer permission';

// 12. Help and Help_Link (google/rpc/error_details.proto)
// Provides links to documentation or for performing an out of band action.
final helpLink = Help_Link()
  // Describes what the link offers.
  ..description = 'Developer Console'
  // The URL of the link.
  ..url = 'https://console.cloud.google.com';

final help = Help()
  // URL(s) pointing to additional information on handling the current error.
  ..links.add(helpLink);

// 13. LocalizedMessage (google/rpc/error_details.proto)
// Provides a localized error message that is safe to return to the user.
final localizedMessage = LocalizedMessage()
  // The locale used following the specification defined at
  // http://www.rfc-editor.org/rfc/bcp/bcp47.txt.
  ..locale = 'en-US'
  // The localized error message in the above locale.
  ..message = 'An unexpected networking error occurred.';
```

## 5. Configuration
The module relies on several foundational configuration classes:
*   **`ChannelOptions`**: Configures client channels with HTTP/2 attributes including `credentials` (e.g., `ChannelCredentials.insecure()` or `ChannelCredentials.secure()`), `idleTimeout`, `connectionTimeout`, `connectTimeout`, `backoffStrategy`, `userAgent`, `maxInboundMessageSize`, and a custom `proxy` object.
*   **`ClientKeepAliveOptions`**: Embedded in `ChannelOptions` to send active HTTP/2 pings (`pingInterval`, `timeout`, `permitWithoutCalls`).
*   **`ServerKeepAliveOptions`**: Controls server-side safeguards via `minIntervalBetweenPingsWithoutData` and `maxBadPings` to protect against ping floods.
*   **`LocalChannelOptions`**: Scoped configuration explicitly tailored for IPC paths (like `connectTimeout` and `backoffStrategy`).
*   **`ServerTlsCredentials`**: Encapsulates TLS parameters using `certificate` and `privateKey` byte lists along with passwords.
*   **`ServerLocalCredentials`**: Credentials restricted to accepting only local loopback networking.

## 6. Related Modules
*   **`package:protobuf`**: Provides the foundational `GeneratedMessage` and parsing runtime backing the generated proto outputs.
*   **`package:googleapis_auth`**: Supplies robust credential exchange and refreshing (utilized under the hood by `HttpBasedAuthenticator`).
