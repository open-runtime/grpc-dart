# Shared Utilities API Reference

This module provides common utilities, classes, functions, and standard constants for the `grpc` package.

## 1. Classes

### Codec
Abstract class representing a message encoding and decoding mechanism.
- **Fields:**
  - `String encodingName`: Returns the message encoding that this compressor uses (e.g., "gzip", "deflate", "snappy").
- **Methods:**
  - `List<int> compress(List<int> data)`: Wraps an existing output stream with a compressed output.
  - `List<int> decompress(List<int> data)`: Wraps an existing output stream with a uncompressed input data.

### CodecRegistry
Encloses classes related to the compression and decompression of messages.
- **Example:**
  ```dart
  import 'package:grpc/grpc.dart';

  final registry = CodecRegistry(codecs: [
    const GzipCodec(),
    const IdentityCodec(),
  ]);
  
  final codec = registry.lookup('gzip');
  ```
- **Constructors:**
  - `CodecRegistry({List<Codec> codecs = const [IdentityCodec()]})`
  - `factory CodecRegistry.empty()`: Creates an empty registry.
- **Fields:**
  - `String supportedEncodings`: Comma-separated string of supported encoding names.
- **Methods:**
  - `Codec? lookup(String codecName)`: Looks up a codec by its encoding name.

### GrpcData
Represents a gRPC Data message payload.
- **Fields:**
  - `List<int> data`: The data bytes.
  - `bool isCompressed`: Indicates whether the data is compressed.

### GrpcError
Exception representing a gRPC error with status code, message, and details.
- **Example:**
  ```dart
  import 'package:grpc/grpc.dart';
  import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

  // Throwing a custom error with details using builder pattern with cascade notation.
  // Note: Protobuf-generated Dart fields use camelCase.
  throw GrpcError.custom(
    StatusCode.invalidArgument,
    'Invalid input provided',
    [
      BadRequest()
        ..fieldViolations.add(
          BadRequest_FieldViolation()
            ..field = 'mailSettings' // correctly using camelCase for protobuf field
            ..description = 'Must not be empty'
        )
    ],
  );
  ```
- **Constructors:**
  - `const GrpcError.custom(int code, [String? message, List<GeneratedMessage>? details, Object? rawResponse, Map<String, String>? trailers])`
  - Named constructors for standard gRPC status codes: `.ok()`, `.cancelled()`, `.unknown()`, `.invalidArgument()`, `.deadlineExceeded()`, `.notFound()`, `.alreadyExists()`, `.permissionDenied()`, `.resourceExhausted()`, `.failedPrecondition()`, `.aborted()`, `.outOfRange()`, `.unimplemented()`, `.internal()`, `.unavailable()`, `.dataLoss()`, `.unauthenticated()`.
- **Fields:**
  - `int code`: The gRPC status code.
  - `String? message`: The error message.
  - `Object? rawResponse`: The raw HTTP response.
  - `Map<String, String>? trailers`: Error trailers.
  - `List<GeneratedMessage>? details`: List of error details.
  - `String codeName`: The string representation of the status code.

### GrpcHttpDecoder
Converter for decoding HTTP/2 `StreamMessage` frames to `GrpcMessage` instances.
- **Fields:**
  - `bool forResponse`: `true` if this decoder is used for decoding responses.
  - `int? maxInboundMessageSize`: Maximum allowed inbound message size in bytes.
- **Methods:**
  - `GrpcMessage convert(StreamMessage input)`: Converts a `StreamMessage` to a `GrpcMessage`.
  - `Sink<StreamMessage> startChunkedConversion(Sink<GrpcMessage> sink)`: Starts a chunked conversion.

### GrpcHttpEncoder
Converter for encoding `GrpcMessage` instances into HTTP/2 `StreamMessage` frames.
- **Methods:**
  - `StreamMessage convert(GrpcMessage input)`: Converts a `GrpcMessage` into a `StreamMessage`.

### GrpcLogEvent
A structured gRPC log event for production observability.
- **Example:**
  ```dart
  import 'package:grpc/grpc.dart';

  grpcEventLogger = (GrpcLogEvent event) {
    print('Component: ${event.component}');
    print('Event: ${event.event}');
    print('Context: ${event.context}');
  };
  
  logGrpcEvent(
    'Stream closed unexpectedly',
    component: 'ServerHandler',
    event: 'closeStream',
    context: 'cancel',
    error: GrpcError.cancelled(),
  );
  ```
- **Fields:**
  - `String component`: Component that generated the event.
  - `String event`: What happened.
  - `String context`: Where it happened (typically the method name).
  - `Object? error`: The underlying error, if any.
  - `String formattedMessage`: The pre-formatted log message string.

### GrpcMessage
Base class for gRPC messages.

### GrpcMessageSink
Sink for receiving gRPC messages.
- **Fields:**
  - `GrpcMessage message`: The received message.
- **Methods:**
  - `void add(GrpcMessage data)`: Adds a message to the sink.
  - `void close()`: Closes the sink.

### GrpcMetadata
Represents a gRPC Metadata message.
- **Fields:**
  - `Map<String, String> metadata`: The metadata key-value pairs.

### GzipCodec
A gzip compressor and decompressor.
- **Fields:**
  - `String encodingName`: Returns `'gzip'`.
- **Methods:**
  - `List<int> compress(List<int> data)`: Compresses data using gzip (unsupported on web).
  - `List<int> decompress(List<int> data)`: Decompresses data using gzip (unsupported on web).

### IdentityCodec
The "identity" or "none" codec, used to explicitly disable call compression.
- **Fields:**
  - `String encodingName`: Returns `'identity'`.
- **Methods:**
  - `List<int> compress(List<int> data)`: Returns the data unmodified.
  - `List<int> decompress(List<int> data)`: Returns the data unmodified.

### IdlePollBackoff
Exponential backoff state for named-pipe idle polling.
- **Example:**
  ```dart
  import 'package:grpc/grpc.dart';

  final backoff = IdlePollBackoff(initialDelayMs: 1, maxDelayMs: 50);
  
  while (true) {
    if (hasData()) {
      backoff.reset();
      processData();
    } else {
      await Future.delayed(backoff.nextDelay());
    }
  }
  ```
- **Constructors:**
  - `IdlePollBackoff({int? initialDelayMs, int? maxDelayMs})`: Creates backoff object.
- **Fields:**
  - `int initialDelayMs`: Initial delay in milliseconds.
  - `int maxDelayMs`: Maximum delay in milliseconds.
- **Methods:**
  - `Duration nextDelay()`: Returns the next backoff delay duration.
  - `void reset()`: Resets the delay back to initial value.

### InternetAddress
Shim class for `InternetAddress` on the web (unavailable).

### NoDataRetryState
Shared state for `ERROR_NO_DATA` retry logic in named pipe read loops.
- **Constructors:**
  - `NoDataRetryState({int? maxRetries})`: Creates retry state object.
- **Fields:**
  - `int maxRetries`: Maximum number of retries before exhaustion.
- **Methods:**
  - `NoDataRetryResult recordNoData()`: Records an `ERROR_NO_DATA` occurrence. Returns whether to retry or exhaust.
  - `void reset()`: Resets the retry count.

### StatusCode
Contains gRPC Status codes and conversion utilities.
- **Fields:**
  - `static const int ok`: 0
  - `static const int cancelled`: 1
  - `static const int unknown`: 2
  - `static const int invalidArgument`: 3
  - `static const int deadlineExceeded`: 4
  - `static const int notFound`: 5
  - `static const int alreadyExists`: 6
  - `static const int permissionDenied`: 7
  - `static const int resourceExhausted`: 8
  - `static const int failedPrecondition`: 9
  - `static const int aborted`: 10
  - `static const int outOfRange`: 11
  - `static const int unimplemented`: 12
  - `static const int internal`: 13
  - `static const int unavailable`: 14
  - `static const int dataLoss`: 15
  - `static const int unauthenticated`: 16
- **Methods:**
  - `static int fromHttpStatus(int status)`: Creates a gRPC Status code from an HTTP Status code.
  - `static String? name(int status)`: Creates a string representation from a gRPC status code.

### X509Certificate
Shim class for `X509Certificate` on the web (unavailable).

## 2. Enums

### NoDataRetryResult
Result of evaluating `ERROR_NO_DATA` retry.
- `retry`: Apply idle backoff delay and loop again.
- `exhausted`: Bail out and log/error.

## 3. Extensions

*(None)*

## 4. Top-Level Functions

- **copyFromNativeBuffer** -- Copies `count` bytes from a native `buffer` into a new `Uint8List`.
  - Signature: `Uint8List copyFromNativeBuffer(Pointer<Uint8> buffer, int count)`
- **copyToNativeBuffer** -- Copies `data` bytes into a native `buffer`.
  - Signature: `void copyToNativeBuffer(Pointer<Uint8> buffer, List<int> data)`
- **createSecurityContext** -- Creates a `SecurityContext` for gRPC, configuring ALPN protocols.
  - Signature: `SecurityContext createSecurityContext(bool isServer)`
- **decodeStatusDetails** -- Decodes status details from a base64url string.
  - Signature: `List<GeneratedMessage> decodeStatusDetails(String data)`
- **defaultUdsDirectory** -- Default base directory for Unix domain socket files.
  - Signature: `String defaultUdsDirectory()`
- **frame** -- Frames a gRPC payload by prepending compression flags and length.
  - Signature: `List<int> frame(List<int> rawPayload, [Codec? codec])`
- **fromTimeoutString** -- Converts a grpc-timeout header string format to a `Duration`.
  - Signature: `Duration? fromTimeoutString(String? timeout)`
- **grpcDecompressor** -- Returns a stream transformer that decompresses gRPC messages.
  - Signature: `StreamTransformer<GrpcMessage, GrpcMessage> grpcDecompressor({CodecRegistry? codecRegistry})`
- **grpcErrorDetailsFromTrailers** -- Extracts a `GrpcError` from response trailers.
  - Signature: `GrpcError? grpcErrorDetailsFromTrailers(Map<String, String> trailers)`
- **logGrpcError** -- Logs a gRPC internal error using the configured logger.
  - Signature: `void logGrpcError(String message)`
- **logGrpcEvent** -- Logs a structured gRPC event.
  - Signature: `void logGrpcEvent(String message, {required String component, required String event, required String context, Object? error})`
- **namedPipePath** -- Constructs the full Windows named pipe path from a pipe name.
  - Signature: `String namedPipePath(String pipeName)`
- **parseErrorDetailsFromAny** -- Parses an error details `Any` object into the corresponding `GeneratedMessage`.
  - Signature: `GeneratedMessage parseErrorDetailsFromAny(Any any)`
- **toCustomTrailers** -- Returns custom trailers by removing gRPC-specific headers.
  - Signature: `Map<String, String> toCustomTrailers(Map<String, String> trailers)`
- **toTimeoutString** -- Converts a `Duration` to grpc-timeout header string format.
  - Signature: `String toTimeoutString(Duration duration)`
- **udsSocketPath** -- Returns the UDS socket path for a given service name.
  - Signature: `String udsSocketPath(String serviceName)`
- **validateHttpStatusAndContentType** -- Validates HTTP status and Content-Type which arrived with the response.
  - Signature: `void validateHttpStatusAndContentType(int? httpStatus, Map<String, String> headers, {Object? rawResponse})`
- **validateServiceName** -- Validates a service name for use as a local IPC address.
  - Signature: `void validateServiceName(String serviceName)`
