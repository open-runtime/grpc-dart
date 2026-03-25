# Shared Utilities API Reference

This document provides the API reference for the Shared Utilities module in `grpc-dart`. This module contains the foundational building blocks used by both the client and server implementations.

## 1. Protobuf Naming Conventions (CRITICAL)

When using Protobuf-generated Dart code, **always use `camelCase` for field access**. While the `.proto` files use `snake_case`, the `protoc` plugin for Dart converts these to `camelCase` to follow Dart language conventions.

| Proto Field Name | Dart Property Name |
| :--- | :--- |
| `batch_id` | `batchId` |
| `send_at` | `sendAt` |
| `mail_settings` | `mailSettings` |
| `tracking_settings` | `trackingSettings` |
| `click_tracking` | `clickTracking` |
| `open_tracking` | `openTracking` |
| `sandbox_mode` | `sandboxMode` |
| `dynamic_template_data` | `dynamicTemplateData` |
| `content_id` | `contentId` |
| `custom_args` | `customArgs` |
| `ip_pool_name` | `ipPoolName` |
| `reply_to` | `replyTo` |
| `reply_to_list` | `replyToList` |
| `template_id` | `templateId` |
| `enable_text` | `enableText` |
| `substitution_tag` | `substitutionTag` |
| `group_id` | `groupId` |
| `groups_to_display` | `groupsToDisplay` |

**Example of correct naming convention:**

```dart
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart';

// CORRECT: Using camelCase
final request = SendMailRequest()
  ..batchId = 'batch-123'
  ..sendAt = Int64(123456789)
  ..mailSettings = (MailSettings()..sandboxMode = true)
  ..trackingSettings = (TrackingSettings()
    ..clickTracking = (ClickTracking()..enable = true)
    ..openTracking = (OpenTracking()..enable = true));

// CORRECT: Protobuf-generated objects also use camelCase for accessors
final String batchId = request.batchId;
final bool sandboxMode = request.mailSettings.sandboxMode;

// INCORRECT: Do not use snake_case in Dart
// request.batch_id = '123'; // Compilation error
```

---

## 2. Classes

### Codec
Abstract base class for message compression and decompression.

- **Properties:**
  - `String encodingName`: The name of the encoding (e.g., "gzip", "identity").
- **Methods:**
  - `List<int> compress(List<int> data)`: Compresses the provided data.
  - `List<int> decompress(List<int> data)`: Decompresses the provided data.

### CodecRegistry
A registry of available codecs for a channel or server.

- **Constructors:**
  - `CodecRegistry({List<Codec> codecs})`: Creates a registry with the provided codecs. Defaults to `[IdentityCodec()]`.
  - `factory CodecRegistry.empty()`: Creates an empty registry.
- **Properties:**
  - `String supportedEncodings`: A comma-separated list of supported encoding names.
- **Methods:**
  - `Codec? lookup(String codecName)`: Looks up a codec by its encoding name.

**Example:**
```dart
import 'package:grpc/grpc.dart';

final registry = CodecRegistry(codecs: [
  IdentityCodec(),
  GzipCodec(),
]);

final codec = registry.lookup('gzip');
```

### GrpcError
Exception class representing a gRPC error.

- **Properties:**
  - `final int code`: The gRPC status code.
  - `final String? message`: The error message.
  - `final List<GeneratedMessage>? details`: A list of error details (e.g., `RetryInfo`, `BadRequest`).
  - `final Object? rawResponse`: The raw response object if available.
  - `final Map<String, String>? trailers`: The response trailers.
  - `String get codeName`: Returns the string representation of the status code (e.g., "NOT_FOUND").

- **Named Constructors:**
  - `GrpcError.custom(int code, [String? message, List<GeneratedMessage>? details, ...])`
  - `GrpcError.ok([String? message, ...])`
  - `GrpcError.cancelled([String? message, ...])`
  - `GrpcError.unknown([String? message, ...])`
  - `GrpcError.invalidArgument([String? message, ...])`
  - `GrpcError.deadlineExceeded([String? message, ...])`
  - `GrpcError.notFound([String? message, ...])`
  - `GrpcError.alreadyExists([String? message, ...])`
  - `GrpcError.permissionDenied([String? message, ...])`
  - `GrpcError.resourceExhausted([String? message, ...])`
  - `GrpcError.failedPrecondition([String? message, ...])`
  - `GrpcError.aborted([String? message, ...])`
  - `GrpcError.outOfRange([String? message, ...])`
  - `GrpcError.unimplemented([String? message, ...])`
  - `GrpcError.internal([String? message, ...])`
  - `GrpcError.unavailable([String? message, ...])`
  - `GrpcError.dataLoss([String? message, ...])`
  - `GrpcError.unauthenticated([String? message, ...])`

**Example:**
```dart
import 'package:grpc/grpc.dart';
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

throw GrpcError.invalidArgument(
  'Invalid batch ID',
  [
    BadRequest_FieldViolation()
      ..field = 'batchId'
      ..description = 'Must be a UUID'
  ],
);
```

### StatusCode
Defines standard gRPC status codes.

- **Constants:**
  - `ok`, `cancelled`, `unknown`, `invalidArgument`, `deadlineExceeded`, `notFound`, `alreadyExists`, `permissionDenied`, `resourceExhausted`, `failedPrecondition`, `aborted`, `outOfRange`, `unimplemented`, `internal`, `unavailable`, `dataLoss`, `unauthenticated`.
- **Static Methods:**
  - `static int fromHttpStatus(int status)`: Maps an HTTP status code to a gRPC status code.
  - `static String? name(int status)`: Returns the name for a status code.

### GrpcMessage
Base class for messages transferred over the gRPC transport.

- **Subclasses:**
  - **GrpcMetadata**: Contains metadata (headers/trailers).
    - `final Map<String, String> metadata`
  - **GrpcData**: Contains framed message data.
    - `final List<int> data`
    - `final bool isCompressed`

### GrpcLogEvent
Structured log event object for production observability.

- **Properties:**
  - `final String component`: The component that generated the event (e.g., `ServerHandler`).
  - `final String event`: The type of event (e.g., `deliver_error`).
  - `final String context`: The execution context, usually the method name.
  - `final Object? error`: The underlying error, if any.
  - `final String formattedMessage`: Pre-formatted human-readable message.

### GrpcHttpEncoder
Converts `GrpcMessage` objects into HTTP/2 `StreamMessage` frames.

- **Methods:**
  - `StreamMessage convert(GrpcMessage input)`: Performs the conversion.

### GrpcHttpDecoder
Converts HTTP/2 `StreamMessage` frames back into `GrpcMessage` objects.

- **Properties:**
  - `final bool forResponse`: Whether this decoder is being used for a response stream (enables HTTP status validation).
  - `final int? maxInboundMessageSize`: Optional limit on the size of inbound messages.
- **Methods:**
  - `GrpcMessage convert(StreamMessage input)`: Performs the conversion.
  - `Sink<StreamMessage> startChunkedConversion(Sink<GrpcMessage> sink)`: Starts a chunked conversion process.

### IdlePollBackoff
Exponential backoff state for named-pipe idle polling (Windows).

- **Properties:**
  - `int zeroDelayCount`: Number of zero-delay polls before escalating.
  - `int initialDelayMs`: Starting delay in milliseconds.
  - `int maxDelayMs`: Maximum delay in milliseconds.

---

## 3. Top-Level Functions

### Formatting and Framing
- `List<int> frame(List<int> rawPayload, [Codec? codec])`: Frames a raw payload for gRPC transport, optionally compressing it.
- `String toTimeoutString(Duration duration)`: Converts a `Duration` to the gRPC timeout header format.
- `Duration? fromTimeoutString(String? timeout)`: Parses a gRPC timeout header string into a `Duration`.

### Local IPC (UDS and Named Pipes)
- `String defaultUdsDirectory()`: Returns the platform-conventional directory for Unix Domain Sockets.
- `String udsSocketPath(String serviceName)`: Constructs a UDS path from a service name.
- `void validateServiceName(String serviceName)`: Ensures a service name is valid for local IPC (e.g., length, characters).
- `String namedPipePath(String pipeName)`: Constructs the full Windows named pipe path (e.g., `\\.\pipe\service`).

### Parsing and Validation
- `List<GeneratedMessage> decodeStatusDetails(String data)`: Decodes the `grpc-status-details-bin` trailer.
- `GeneratedMessage parseErrorDetailsFromAny(Any any)`: Maps a Google RPC `Any` object to a concrete message type.
- `void validateHttpStatusAndContentType(int? httpStatus, Map<String, String> headers)`: Validates that the HTTP response is a valid gRPC response.

### Logging
- `void logGrpcError(String message)`: Logs an internal gRPC error using the configured `grpcErrorLogger`.
- `void logGrpcEvent(String message, {required String component, ...})`: Logs a structured event.

---

## 4. Global Configuration

### Profiling and Timeline
- `bool isTimelineLoggingEnabled`: If `true`, gRPC events will be logged to the Dart developer timeline. Defaults to `false`.

### Custom Logging
- `GrpcErrorLogger grpcErrorLogger`: Global callback for string-based error logging. Defaults to `stderr.writeln`.
- `GrpcEventLogger? grpcEventLogger`: Optional global callback for structured event logging.

**Example: Redirecting gRPC logs to a custom framework:**
```dart
import 'package:grpc/grpc.dart';

void main() {
  grpcErrorLogger = (message) {
    print('[gRPC-Internal] $message');
  };

  grpcEventLogger = (event) {
    // Send to Sentry, Google Cloud Logging, etc.
    myAnalytics.log(
      'grpc_event',
      {
        'component': event.component,
        'type': event.event,
        'error': event.error?.toString(),
      },
    );
  };
}
```

### Security Constants
- `const List<String> supportedAlpnProtocols`: The ALPN protocols supported by this implementation (`['grpc-exp', 'h2']`).
