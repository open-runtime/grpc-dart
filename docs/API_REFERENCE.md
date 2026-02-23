# Shared Utilities API Reference

This document provides the API reference for the shared utilities module in `grpc-dart`, encompassing codec management, HTTP/2 streaming, error handling, and general utilities.

## Classes

* **Codec** -- Abstract class for compressing and decompressing messages.
  * **Fields:**
    * `String get encodingName` - The message encoding that this compressor uses (e.g., "gzip", "identity").
  * **Methods:**
    * `List<int> compress(List<int> data)` - Wraps an existing output stream with a compressed output.
    * `List<int> decompress(List<int> data)` - Wraps an existing output stream with uncompressed input data.

* **CodecRegistry** -- Encloses classes related to the compression and decompression of messages.
  * **Constructors:**
    * `CodecRegistry({List<Codec> codecs = const [IdentityCodec()]})` - Creates a registry with the provided codecs.
    * `factory CodecRegistry.empty()` - Creates an empty codec registry.
  * **Fields:**
    * `String get supportedEncodings` - A comma-separated string of supported encoding names.
  * **Methods:**
    * `Codec? lookup(String codecName)` - Looks up and returns a codec by its encoding name.
  * **Example:**
    ```dart
    import 'package:grpc/grpc.dart';

    // Create a registry supporting both gzip and identity encodings
    final registry = CodecRegistry(codecs: [
      const GzipCodec(),
      const IdentityCodec(),
    ]);
    ```

* **GrpcData** -- Represents a gRPC data message.
  * **Fields:**
    * `final List<int> data` - The raw or compressed byte data.
    * `final bool isCompressed` - Indicates whether the data is currently compressed.

* **GrpcError** -- Represents a gRPC error exception.
  * **Constructors:**
    * `const GrpcError.custom(this.code, [this.message, this.details, this.rawResponse, this.trailers = const {}])`
    * Named constructors for standard gRPC status codes: `.ok`, `.cancelled`, `.unknown`, `.invalidArgument`, `.deadlineExceeded`, `.notFound`, `.alreadyExists`, `.permissionDenied`, `.resourceExhausted`, `.failedPrecondition`, `.aborted`, `.outOfRange`, `.unimplemented`, `.internal`, `.unavailable`, `.dataLoss`, `.unauthenticated`.
  * **Fields:**
    * `final int code` - The gRPC status code.
    * `final String? message` - Optional error message detailing the issue.
    * `final Object? rawResponse` - The raw response object, if applicable.
    * `final Map<String, String>? trailers` - Any HTTP trailers associated with the error.
    * `final List<GeneratedMessage>? details` - A list of protobuf `GeneratedMessage` details providing structured error information.
    * `String get codeName` - The string representation of the status code.
  * **Methods:**
    * `bool operator ==(other)` - Checks equality based on code and message.
    * `int get hashCode` - Returns a hash code for the object.
    * `String toString()` - String representation of the error.
  * **Example:**
    ```dart
    import 'package:grpc/grpc.dart';
    import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

    // Construct an ErrorInfo detail message using the cascade builder pattern
    final errorInfo = ErrorInfo()
      ..reason = 'INVALID_TOKEN'
      ..domain = 'example.com'
      ..metadata.addAll({'requestId': '12345'});

    // Create a custom GrpcError including the detail
    final error = GrpcError.custom(
      StatusCode.unauthenticated,
      'Authentication failed',
      [errorInfo],
    );
    ```

* **GrpcHttpDecoder** -- Decodes `StreamMessage` frames into `GrpcMessage` objects.
  * **Constructors:**
    * `GrpcHttpDecoder({this.forResponse = false})`
  * **Fields:**
    * `final bool forResponse` - Indicates if this decoder is used for decoding responses.
  * **Methods:**
    * `GrpcMessage convert(StreamMessage input)` - Converts a single stream message frame.
    * `Sink<StreamMessage> startChunkedConversion(Sink<GrpcMessage> sink)` - Starts chunked conversion of stream messages.

* **GrpcHttpEncoder** -- Encodes `GrpcMessage` objects into `StreamMessage` frames.
  * **Methods:**
    * `StreamMessage convert(GrpcMessage input)` - Converts a `GrpcMessage` into HTTP/2 headers or data stream frames.

* **GrpcMessage** -- Abstract base class for gRPC messages.

* **GrpcMessageSink** -- Sink for collecting a single `GrpcMessage`.
  * **Fields:**
    * `late final GrpcMessage message` - The received message.
  * **Methods:**
    * `void add(GrpcMessage data)` - Adds a message to the sink.
    * `void close()` - Closes the sink.

* **GrpcMetadata** -- Represents gRPC metadata message.
  * **Fields:**
    * `final Map<String, String> metadata` - The key-value pairs of the metadata headers.
  * **Example:**
    ```dart
    import 'package:grpc/grpc.dart';

    final metadata = GrpcMetadata({
      'authorization': 'Bearer token...',
      'x-custom-header': 'value',
    });
    ```

* **GzipCodec** -- A gzip compressor and decompressor implementation of `Codec`.
  * **Fields:**
    * `final String encodingName` - Always `'gzip'`.
  * **Methods:**
    * `List<int> compress(List<int> data)` - Compresses data using GZIP (throws UnsupportedError on web).
    * `List<int> decompress(List<int> data)` - Decompresses GZIP data (throws UnsupportedError on web).

* **IdentityCodec** -- The "identity" or "none" codec implementation of `Codec`.
  * **Fields:**
    * `final String encodingName` - Always `'identity'`.
  * **Methods:**
    * `List<int> compress(List<int> data)` - Returns the data unchanged.
    * `List<int> decompress(List<int> data)` - Returns the data unchanged.

* **InternetAddress** -- Stub class for `InternetAddress`.
  * *Note:* Unavailable natively on the web platform.

* **StatusCode** -- Class containing static constants for gRPC status codes and mapping logic.
  * **Fields:**
    * Static constant integers representing standard gRPC status codes: `ok`, `cancelled`, `unknown`, `invalidArgument`, `deadlineExceeded`, `notFound`, `alreadyExists`, `permissionDenied`, `resourceExhausted`, `failedPrecondition`, `aborted`, `outOfRange`, `unimplemented`, `internal`, `unavailable`, `dataLoss`, `unauthenticated`.
  * **Methods:**
    * `static int fromHttpStatus(int status)` - Creates a gRPC Status code from an HTTP Status code.
    * `static String? name(int status)` - Creates a string name from a gRPC status code.

* **X509Certificate** -- Stub class for `X509Certificate`.
  * *Note:* Should not be used on the Web, but is pulled through protoc-generated code.

## Enums

*(No public enums are defined in this module)*

## Extensions

*(No public extensions are defined in this module)*

## Top-Level Functions

* **createSecurityContext** -- `SecurityContext createSecurityContext(bool isServer)`
  * Creates a `SecurityContext` with supported ALPN protocols populated.
  * **Parameters:** `bool isServer`
  * **Returns:** `SecurityContext`

* **decodeStatusDetails** -- `List<GeneratedMessage> decodeStatusDetails(String data)`
  * Given a string of base64url data, attempts to parse a Status object and its detailed `GeneratedMessage` items.
  * **Parameters:** `String data`
  * **Returns:** `List<GeneratedMessage>`

* **frame** -- `List<int> frame(List<int> rawPayload, [Codec? codec])`
  * Frames a raw payload according to gRPC specification, conditionally compressing it if a `Codec` is provided.
  * **Parameters:** `List<int> rawPayload`, optional `Codec? codec`
  * **Returns:** `List<int>`

* **fromTimeoutString** -- `Duration? fromTimeoutString(String? timeout)`
  * Converts a timeout from grpc-timeout header string format to a `Duration`. Returns `null` if incorrectly formatted.
  * **Parameters:** `String? timeout`
  * **Returns:** `Duration?`

* **grpcDecompressor** -- `StreamTransformer<GrpcMessage, GrpcMessage> grpcDecompressor({CodecRegistry? codecRegistry})`
  * Returns a `StreamTransformer` that decompresses incoming `GrpcData` messages based on the active `grpc-encoding`.
  * **Parameters:** optional `CodecRegistry? codecRegistry`
  * **Returns:** `StreamTransformer<GrpcMessage, GrpcMessage>`

* **grpcErrorDetailsFromTrailers** -- `GrpcError? grpcErrorDetailsFromTrailers(Map<String, String> trailers)`
  * Extracts error details, including `grpc-status` and `grpc-message`, from an HTTP trailers map.
  * **Parameters:** `Map<String, String> trailers`
  * **Returns:** `GrpcError?`

* **logGrpcError** -- `void logGrpcError(String message)`
  * Platform-specific logging. Uses `stderr` in VM/IO environments and `print` in web/browser environments.
  * **Parameters:** `String message`
  * **Returns:** `void`

* **parseErrorDetailsFromAny** -- `GeneratedMessage parseErrorDetailsFromAny(Any any)`
  * Parses an error details `Any` object into the right kind of `GeneratedMessage` (e.g. `RetryInfo`, `DebugInfo`).
  * **Parameters:** `Any any`
  * **Returns:** `GeneratedMessage`

* **toCustomTrailers** -- `Map<String, String> toCustomTrailers(Map<String, String> trailers)`
  * Filters standard gRPC keys (`:status`, `content-type`, `grpc-status`, `grpc-message`) out of a trailers map.
  * **Parameters:** `Map<String, String> trailers`
  * **Returns:** `Map<String, String>`

* **toTimeoutString** -- `String toTimeoutString(Duration duration)`
  * Converts a `Duration` to the grpc-timeout header string format (e.g., `100m`, `5S`).
  * **Parameters:** `Duration duration`
  * **Returns:** `String`

* **validateHttpStatusAndContentType** -- `void validateHttpStatusAndContentType(int? httpStatus, Map<String, String> headers, {Object? rawResponse})`
  * Validates HTTP status and Content-Type arriving with the response, rejecting non-ok (200) statuses or unsupported types.
  * **Parameters:** `int? httpStatus`, `Map<String, String> headers`, optional `Object? rawResponse`
  * **Returns:** `void`

## Constants and Variables

* **clientTimelineFilterKey** -- `const String clientTimelineFilterKey = 'grpc/client'`
* **isTimelineLoggingEnabled** -- `bool isTimelineLoggingEnabled = false` (Controls logging requests and responses for clients)
* **supportedAlpnProtocols** -- `const supportedAlpnProtocols = ['grpc-exp', 'h2']`
