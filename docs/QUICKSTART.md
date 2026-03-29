# gRPC Dart Package Entry Points - Quickstart

## 1. Overview
The gRPC Package Entry Points module provides the top-level public APIs required to build gRPC clients and servers in Dart. It exports the classes and utilities needed for configuring channels, creating servers, implementing services, and handling authentication.

This package supports multiple transport layers:
-   **Native (HTTP/2)**: Standard gRPC for server-to-server and mobile communication.
-   **gRPC-Web**: For web applications using the gRPC-Web protocol.
-   **Local IPC**: High-performance local communication using Unix Domain Sockets (macOS/Linux) or Named Pipes (Windows).

## 2. Imports
Depending on your target platform and needs, you can import different entry points. Always use the `package:grpc-dart/` prefix for imports.

```dart
// Main entry point for native (io) gRPC clients and servers
import 'package:grpc-dart/grpc.dart';

// Entry point for web-only clients (gRPC-Web)
import 'package:grpc-dart/grpc_web.dart';

// Cross-platform entry point that automatically selects native gRPC or gRPC-Web
import 'package:grpc-dart/grpc_or_grpcweb.dart';

// Common utility types like Duration and detailed ErrorInfo
import 'package:grpc-dart/protos.dart';

// Minimal API surface intended primarily for generated stubs
import 'package:grpc-dart/service_api.dart';
```

## 3. Client Setup

### Native HTTP/2 Channel
Used for standard gRPC communication over TCP/TLS.

```dart
import 'package:grpc-dart/grpc.dart';

final channel = ClientChannel(
  'localhost',
  port: 8080,
  options: const ChannelOptions(
    credentials: ChannelCredentials.insecure(), // Use secure() for TLS
    idleTimeout: Duration(minutes: 5),
  ),
);
```

### Cross-Platform (Native & Web)
This channel automatically selects the appropriate implementation based on the platform.

```dart
import 'package:grpc-dart/grpc_or_grpcweb.dart';

final channel = GrpcOrGrpcWebClientChannel.toSingleEndpoint(
  host: 'api.example.com',
  port: 443,
  transportSecure: true,
);
```

### Local IPC Channel
Provides the best performance for same-machine communication.

```dart
import 'package:grpc-dart/grpc.dart';

// Automatically uses Unix Domain Sockets on Linux/macOS and Named Pipes on Windows
final channel = LocalGrpcChannel('my-service');
```

## 4. Server Setup

### Native Server
```dart
import 'package:grpc-dart/grpc.dart';

Future<void> main() async {
  final server = Server.create(
    services: [MyServiceImplementation()],
    interceptors: [loggingInterceptor],
    codecRegistry: CodecRegistry(codecs: const [GzipCodec(), IdentityCodec()]),
  );

  await server.serve(port: 8080);
  print('Server listening on port ${server.port}...');
}
```

### Local IPC Server
```dart
import 'package:grpc-dart/grpc.dart';

final server = LocalGrpcServer(
  'my-service',
  services: [MyServiceImplementation()],
);
await server.serve();
```

## 5. Working with Utility Protos
The `package:grpc-dart/protos.dart` library provides access to common RPC and Protobuf utility types.

### Duration
Protobuf `Duration` can be converted to and from native Dart `Duration`.

```dart
import 'package:grpc-dart/protos.dart';
import 'package:fixnum/fixnum.dart';

// 1. Constructing a Proto Duration using cascades
final protoDuration = Duration()
  ..seconds = Int64(30) // Signed seconds of the span of time
  ..nanos = 500000000;  // Signed fractions of a second at nanosecond resolution

// 2. Conversion methods
final dartDuration = protoDuration.toDart();
final backToProto = Duration.fromDart(const Duration(minutes: 1));
```

### Structured Error Details
Structured errors provide rich context to clients beyond a simple status code.

```dart
import 'package:grpc-dart/grpc.dart';
import 'package:grpc-dart/protos.dart';
import 'package:fixnum/fixnum.dart';

// 1. Constructing a QuotaFailure
final violation = QuotaFailure_Violation()
  ..subject = 'user:123'
  ..description = 'Daily API rate limit exceeded';

final quotaFailure = QuotaFailure()
  ..violations.add(violation);

// 2. Constructing a RetryInfo
final retryInfo = RetryInfo()
  ..retryDelay = (Duration()..seconds = Int64(60));

// 3. Throwing a GrpcError with structured details
throw GrpcError.resourceExhausted(
  'Quota exceeded',
  [quotaFailure, retryInfo],
);
```

### Supported Message Types
The following messages from `google/rpc/error_details.proto` are available:

*   **`RetryInfo`**: Recommends when to retry.
    *   `retryDelay`: The delay before retrying.
*   **`DebugInfo`**: Detailed stack traces.
    *   `stackEntries`: List of stack trace entries.
    *   `detail`: Additional debugging information.
*   **`QuotaFailure`**: Details about quota violations.
    *   `violations`: List of `QuotaFailure_Violation` objects.
*   **`ErrorInfo`**: Machine-readable error cause.
    *   `reason`: Error reason identifier (e.g., `API_DISABLED`).
    *   `domain`: The logical grouping of the error (e.g., `googleapis.com`).
    *   `metadata`: Map of additional structured details.
*   **`PreconditionFailure`**: Requirements that were not met.
    *   `violations`: List of `PreconditionFailure_Violation` objects.
*   **`BadRequest`**: Syntactic violations in the request.
    *   `fieldViolations`: List of `BadRequest_FieldViolation` objects.
*   **`RequestInfo`**: Metadata for bug reporting.
    *   `requestId`: Opaque string identifying the request.
    *   `servingData`: Encrypted trace or server-specific data.
*   **`ResourceInfo`**: The resource being accessed.
    *   `resourceType`: Name of the resource type (e.g., `sql table`).
    *   `resourceName`: Unique name of the resource.
    *   `owner`: Owner of the resource (optional).
    *   `description`: Description of the error encountered.
*   **`Help`**: Links to documentation.
    *   `links`: List of `Help_Link` objects (containing `description` and `url`).
-   **`LocalizedMessage`**: User-facing error message.
    *   `locale`: The BCP-47 locale (e.g., `en-US`).
    *   `message`: The translated error message.
-   **`Any`**: A generic message wrapper.
    *   `typeUrl`: URL identifying the type of the serialized message.
    *   `value`: The serialized message bytes.
-   **`Status`**: The standard error model.
    *   `code`: The status code.
    *   `message`: A developer-facing error message.
    *   `details`: A list of messages that carry error details (typically `Any` messages).


## 6. Configuration Reference

### ChannelOptions
Controls client connection behavior.
- `credentials`: Security settings (`ChannelCredentials.secure()` or `insecure()`).
- `idleTimeout`: Duration to keep an idle connection open.
- `connectTimeout`: Maximum time for connection establishment.
- `connectionTimeout`: Proactive refresh interval (default 50 mins).
- `maxInboundMessageSize`: Limit on incoming payload size in bytes.
- `backoffStrategy`: Custom exponential backoff logic.
- `userAgent`: Custom string for the `User-Agent` header.

### ServerKeepAliveOptions
Configures server-side health checks.
- `maxBadPings`: Number of out-of-interval pings tolerated before termination.
- `minIntervalBetweenPingsWithoutData`: Expected minimum time between pings when no data is flowing.

### ClientKeepAliveOptions
Configures client-side health checks.
- `pingInterval`: How often to send a keep-alive ping.
- `timeout`: Wait time for ping response before closing.
- `permitWithoutCalls`: Send pings even when there are no active RPCs.
