# Generated API Reference

This module contains the generated Dart models for common Google Protocol Buffer types and RPC error details.

## 1. Classes

### Any
`Any` contains an arbitrary serialized protocol buffer message along with a URL that describes the type of the serialized message.

**Fields:**
- `String typeUrl` - A URL/resource name that uniquely identifies the type of the serialized protocol buffer message.
- `List<int> value` - Must be a valid serialized protocol buffer of the above specified type.

**Constructors:**
- `factory Any({String? typeUrl, List<int>? value})`
- `factory Any.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory Any.fromJson(String json, [ExtensionRegistry registry])`

**Methods:**
- `static Any pack(GeneratedMessage message, {String typeUrlPrefix = 'type.googleapis.com'})` - Creates a new `Any` encoding `message`.
- `bool hasTypeUrl()` - Returns whether the `typeUrl` field has been set.
- `void clearTypeUrl()` - Clears the `typeUrl` field.
- `bool hasValue()` - Returns whether the `value` field has been set.
- `void clearValue()` - Clears the `value` field.

**Example:**
```dart
import 'package:grpc-dart/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc-dart/protos.dart';

// Pack a message into Any
final any = Any.pack(RetryInfo()..retryDelay = (Duration()..seconds = Int64(5)));

// Unpack a message from Any manually
if (any.typeUrl == 'type.googleapis.com/google.rpc.RetryInfo') {
  final retryInfo = RetryInfo.fromBuffer(any.value);
  print(retryInfo.retryDelay.seconds);
}
```

### Duration
A Duration represents a signed, fixed-length span of time represented as a count of seconds and fractions of seconds at nanosecond resolution.

**Fields:**
- `Int64 seconds` - Signed seconds of the span of time. Must be from -315,576,000,000 to +315,576,000,000 inclusive.
- `int nanos` - Signed fractions of a second at nanosecond resolution of the span of time. Must be from -999,999,999 to +999,999,999 inclusive.

**Constructors:**
- `factory Duration({Int64? seconds, int? nanos})`
- `factory Duration.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory Duration.fromJson(String json, [ExtensionRegistry registry])`

**Methods:**
- `core.Duration toDart()` - Converts the `Duration` to `dart:core` `Duration`. This is a lossy conversion.
- `static Duration fromDart(core.Duration duration)` - Creates a new instance from `dart:core` `Duration`.
- `bool hasSeconds()`
- `void clearSeconds()`
- `bool hasNanos()`
- `void clearNanos()`

**Example:**
```dart
import 'package:grpc-dart/protos.dart';
import 'package:fixnum/fixnum.dart';

// Creating a Duration using cascade notation
final duration = Duration()
  ..seconds = Int64(30) // Signed seconds of the span of time
  ..nanos = 500;        // Nanoseconds at nanosecond resolution

// Converting to/from Dart core Duration
final dartDuration = duration.toDart();
final protoDuration = Duration.fromDart(Duration(seconds: 45));
```

### RetryInfo
Describes when the clients can retry a failed request.

**Fields:**
- `Duration retryDelay` - Clients should wait at least this long between retrying the same request.

**Constructors:**
- `factory RetryInfo({Duration? retryDelay})`
- `factory RetryInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory RetryInfo.fromJson(String json, [ExtensionRegistry registry])`

**Methods:**
- `bool hasRetryDelay()`
- `void clearRetryDelay()`
- `Duration ensureRetryDelay()`

**Example:**
```dart
import 'package:grpc-dart/protos.dart';
import 'package:fixnum/fixnum.dart';

final retryInfo = RetryInfo()
  ..retryDelay = (Duration()..seconds = Int64(10));
```

### DebugInfo
Describes additional debugging info.

**Fields:**
- `PbList<String> stackEntries` - The stack trace entries indicating where the error occurred.
- `String detail` - Additional debugging information provided by the server.

**Constructors:**
- `factory DebugInfo({Iterable<String>? stackEntries, String? detail})`
- `factory DebugInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory DebugInfo.fromJson(String json, [ExtensionRegistry registry])`

**Methods:**
- `bool hasDetail()`
- `void clearDetail()`

**Example:**
```dart
import 'package:grpc-dart/protos.dart';

final debugInfo = DebugInfo()
  ..stackEntries.addAll(['at Service.method (service.dart:10)', 'at Handler.handle (handler.dart:5)'])
  ..detail = 'Internal database connection timeout';
```

### QuotaFailure
Describes how a quota check failed.

**Fields:**
- `PbList<QuotaFailure_Violation> violations` - Describes all quota violations.

**Constructors:**
- `factory QuotaFailure({Iterable<QuotaFailure_Violation>? violations})`
- `factory QuotaFailure.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory QuotaFailure.fromJson(String json, [ExtensionRegistry registry])`

**Example:**
```dart
import 'package:grpc-dart/protos.dart';

final quotaFailure = QuotaFailure()
  ..violations.add(QuotaFailure_Violation()
    ..subject = 'clientip:127.0.0.1'
    ..description = 'Daily limit for read operations exceeded');
```

### QuotaFailure_Violation
A message type used to describe a single quota violation.

**Fields:**
- `String subject` - The subject on which the quota check failed.
- `String description` - A description of how the quota check failed.

**Constructors:**
- `factory QuotaFailure_Violation({String? subject, String? description})`
- `factory QuotaFailure_Violation.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory QuotaFailure_Violation.fromJson(String json, [ExtensionRegistry registry])`

### ErrorInfo
Describes the cause of the error with structured details.

**Fields:**
- `String reason` - The reason of the error. A constant value that identifies the proximate cause of the error.
- `String domain` - The logical grouping to which the "reason" belongs.
- `PbMap<String, String> metadata` - Additional structured details about this error.

**Constructors:**
- `factory ErrorInfo({String? reason, String? domain, Iterable<MapEntry<String, String>>? metadata})`
- `factory ErrorInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory ErrorInfo.fromJson(String json, [ExtensionRegistry registry])`

**Example:**
```dart
import 'package:grpc-dart/protos.dart';

final errorInfo = ErrorInfo()
  ..reason = 'API_DISABLED'
  ..domain = 'googleapis.com'
  ..metadata.addAll({
    'resource': 'projects/123',
    'service': 'pubsub.googleapis.com',
  });
```

### PreconditionFailure
Describes what preconditions have failed.

**Fields:**
- `PbList<PreconditionFailure_Violation> violations` - Describes all precondition violations.

**Constructors:**
- `factory PreconditionFailure({Iterable<PreconditionFailure_Violation>? violations})`
- `factory PreconditionFailure.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory PreconditionFailure.fromJson(String json, [ExtensionRegistry registry])`

### PreconditionFailure_Violation
A message type used to describe a single precondition failure.

**Fields:**
- `String type` - The type of PreconditionFailure (e.g., 'TOS' for Terms of Service).
- `String subject` - The subject, relative to the type, that failed.
- `String description` - A description of how the precondition failed.

**Constructors:**
- `factory PreconditionFailure_Violation({String? type, String? subject, String? description})`
- `factory PreconditionFailure_Violation.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory PreconditionFailure_Violation.fromJson(String json, [ExtensionRegistry registry])`

### BadRequest
Describes violations in a client request. This error type focuses on the syntactic aspects of the request.

**Fields:**
- `PbList<BadRequest_FieldViolation> fieldViolations` - Describes all violations in a client request.

**Constructors:**
- `factory BadRequest({Iterable<BadRequest_FieldViolation>? fieldViolations})`
- `factory BadRequest.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory BadRequest.fromJson(String json, [ExtensionRegistry registry])`

**Example:**
```dart
import 'package:grpc-dart/protos.dart';

final badRequest = BadRequest()
  ..fieldViolations.add(BadRequest_FieldViolation()
    ..field_1 = 'user.email'
    ..description = 'Invalid email format');
```

### BadRequest_FieldViolation
A message type used to describe a single bad request field.

**Fields:**
- `String field_1` - A path leading to a field in the request body. Generated as `field_1` to avoid conflict with the Dart `field` keyword.
- `String description` - A description of why the request element is bad.

**Constructors:**
- `factory BadRequest_FieldViolation({String? field_1, String? description})`
- `factory BadRequest_FieldViolation.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory BadRequest_FieldViolation.fromJson(String json, [ExtensionRegistry registry])`

**Methods:**
- `bool hasField_1()`
- `void clearField_1()`
- `bool hasDescription()`
- `void clearDescription()`

### RequestInfo
Contains metadata about the request that clients can attach when filing a bug or providing other forms of feedback.

**Fields:**
- `String requestId` - An opaque string that should only be interpreted by the service generating it.
- `String servingData` - Any data that was used to serve this request (e.g., an encrypted stack trace).

**Constructors:**
- `factory RequestInfo({String? requestId, String? servingData})`
- `factory RequestInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory RequestInfo.fromJson(String json, [ExtensionRegistry registry])`

### ResourceInfo
Describes the resource that is being accessed.

**Fields:**
- `String resourceType` - A name for the type of resource being accessed (e.g., 'sql table').
- `String resourceName` - The name of the resource being accessed.
- `String owner` - The owner of the resource (optional).
- `String description` - Describes what error is encountered when accessing this resource.

**Constructors:**
- `factory ResourceInfo({String? resourceType, String? resourceName, String? owner, String? description})`
- `factory ResourceInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory ResourceInfo.fromJson(String json, [ExtensionRegistry registry])`

### Help
Provides links to documentation or for performing an out of band action.

**Fields:**
- `PbList<Help_Link> links` - URL(s) pointing to additional information on handling the current error.

**Constructors:**
- `factory Help({Iterable<Help_Link>? links})`
- `factory Help.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory Help.fromJson(String json, [ExtensionRegistry registry])`

### Help_Link
Describes a URL link.

**Fields:**
- `String description` - Describes what the link offers.
- `String url` - The URL of the link.

**Constructors:**
- `factory Help_Link({String? description, String? url})`
- `factory Help_Link.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory Help_Link.fromJson(String json, [ExtensionRegistry registry])`

### LocalizedMessage
Provides a localized error message that is safe to return to the user which can be attached to an RPC error.

**Fields:**
- `String locale` - The locale used (e.g., 'en-US', 'fr-CH').
- `String message` - The localized error message in the above locale.

**Constructors:**
- `factory LocalizedMessage({String? locale, String? message})`
- `factory LocalizedMessage.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory LocalizedMessage.fromJson(String json, [ExtensionRegistry registry])`

### Status
The `Status` type defines a logical error model that is suitable for different programming environments, including REST APIs and RPC APIs.

**Fields:**
- `int code` - The status code, which should be an enum value of `google.rpc.Code`.
- `String message` - A developer-facing error message, which should be in English.
- `PbList<Any> details` - A list of messages that carry the error details.

**Constructors:**
- `factory Status({int? code, String? message, Iterable<Any>? details})`
- `factory Status.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `factory Status.fromJson(String json, [ExtensionRegistry registry])`

**Example:**
```dart
import 'package:grpc-dart/src/generated/google/rpc/status.pb.dart';
import 'package:grpc-dart/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc-dart/protos.dart';

final status = Status()
  ..code = 3 // INVALID_ARGUMENT
  ..message = 'Invalid email address'
  ..details.add(Any.pack(BadRequest()..fieldViolations.add(
    BadRequest_FieldViolation()
      ..field_1 = 'email'
      ..description = 'The email address is malformed.'
  )));
```

## 2. Enums
No public enums are defined in this module.

## 3. Extensions
No public extensions are defined in this module.

## 4. Top-Level Functions
No public top-level functions are defined in this module.
