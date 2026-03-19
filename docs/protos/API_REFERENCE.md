# Protobuf Integration API Reference

This document provides a comprehensive API reference for the generated Dart classes from the `google.protobuf` and `google.rpc` packages used in the Protobuf Integration module. All message types follow the Dart builder pattern using cascade notation (`..`) for initialization.

## 1. Classes

### Google Protobuf Types

#### `Any`
`Any` contains an arbitrary serialized protocol buffer message along with a URL that describes the type of the serialized message. Protobuf library provides support to pack/unpack Any values.

**Constructors:**
* `factory Any({String? typeUrl, List<int>? value})` -- Creates a new `Any` instance.
* `factory Any.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates an `Any` from a serialized buffer.
* `factory Any.fromJson(String json, [ExtensionRegistry registry])` -- Creates an `Any` from a JSON string.

**Fields:**
* `String typeUrl` -- A URL/resource name that uniquely identifies the type of the serialized protocol buffer message.
* `List<int> value` -- Must be a valid serialized protocol buffer of the specified type.

**Methods:**
* `static Any pack(GeneratedMessage message, {String typeUrlPrefix = 'type.googleapis.com'})` -- Creates a new `Any` encoding the provided `message`.
* `Any clone()` -- Returns a deep copy of the message.
* `Any copyWith(void Function(Any) updates)` -- Returns a deep copy and applies `updates`.
* `void clearTypeUrl()` -- Clears the `typeUrl` field.
* `bool hasTypeUrl()` -- Returns true if `typeUrl` is set.
* `void clearValue()` -- Clears the `value` field.
* `bool hasValue()` -- Returns true if `value` is set.

**Example:**
```dart
import 'package:grpc/grpc.dart';
import 'src/protos/google/protobuf/any.pb.dart';

// Pack and unpack a message
final anyMessage = Any()
  // A URL/resource name that uniquely identifies the type of the serialized protocol buffer message.
  ..typeUrl = 'type.googleapis.com/google.profile.Person'
  // Must be a valid serialized protocol buffer of the above specified type.
  ..value = [/* serialized bytes */];
```

#### `Duration`
A `Duration` represents a signed, fixed-length span of time represented as a count of seconds and fractions of seconds at nanosecond resolution. It is independent of any calendar and concepts like "day" or "month".

**Constructors:**
* `factory Duration({Int64? seconds, int? nanos})` -- Creates a new `Duration`.
* `factory Duration.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `Duration` from a serialized buffer.
* `factory Duration.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `Duration` from a JSON string.

**Fields:**
* `Int64 seconds` -- Signed seconds of the span of time. Must be from -315,576,000,000 to +315,576,000,000 inclusive.
* `int nanos` -- Signed fractions of a second at nanosecond resolution of the span of time.

**Methods:**
* `core.Duration toDart()` -- Converts the protobuf `Duration` to Dart's built-in `core.Duration` (lossy conversion).
* `static Duration fromDart(core.Duration duration)` -- Creates a new protobuf `Duration` instance from Dart's built-in `core.Duration`.
* `Duration clone()` -- Returns a deep copy of the message.
* `Duration copyWith(void Function(Duration) updates)` -- Returns a deep copy and applies `updates`.
* `void clearSeconds()` -- Clears the `seconds` field.
* `bool hasSeconds()` -- Returns true if `seconds` is set.
* `void clearNanos()` -- Clears the `nanos` field.
* `bool hasNanos()` -- Returns true if `nanos` is set.

**Example:**
```dart
import 'package:fixnum/fixnum.dart';
import 'src/protos/google/protobuf/duration.pb.dart';

final duration = Duration()
  // Signed seconds of the span of time. Must be from -315,576,000,000 to +315,576,000,000 inclusive.
  ..seconds = Int64(3)
  // Signed fractions of a second at nanosecond resolution of the span of time.
  ..nanos = 1000000000;
```

### Google RPC Types

#### `Status`
The `Status` type defines a logical error model that is suitable for different programming environments, including REST APIs and RPC APIs.

**Constructors:**
* `factory Status({int? code, String? message, Iterable<Any>? details})` -- Creates a new `Status` instance.
* `factory Status.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `Status` from a serialized buffer.
* `factory Status.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `Status` from a JSON string.

**Fields:**
* `int code` -- The status code, which should be an enum value of `google.rpc.Code`.
* `String message` -- A developer-facing error message, which should be in English.
* `List<Any> details` -- A list of messages that carry the error details.

**Methods:**
* `Status clone()` -- Returns a deep copy of the message.
* `Status copyWith(void Function(Status) updates)` -- Returns a deep copy and applies `updates`.
* `void clearCode()` -- Clears the `code` field.
* `bool hasCode()` -- Returns true if `code` is set.
* `void clearMessage()` -- Clears the `message` field.
* `bool hasMessage()` -- Returns true if `message` is set.

**Example:**
```dart
import 'src/protos/google/rpc/status.pb.dart';
import 'src/protos/google/protobuf/any.pb.dart';

final status = Status()
  // The status code, which should be an enum value of google.rpc.Code.
  ..code = 5
  // A developer-facing error message, which should be in English.
  ..message = 'Not found'
  // A list of messages that carry the error details.
  ..details.add(Any()..typeUrl = 'type.googleapis.com/google.rpc.ErrorInfo');
```

#### `RetryInfo`
Describes when the clients can retry a failed request. Clients should wait until `retryDelay` amount of time has passed since receiving the error response before retrying.

**Constructors:**
* `factory RetryInfo({Duration? retryDelay})` -- Creates a new `RetryInfo` instance.
* `factory RetryInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `RetryInfo` from a serialized buffer.
* `factory RetryInfo.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `RetryInfo` from a JSON string.

**Fields:**
* `Duration retryDelay` -- Clients should wait at least this long between retrying the same request.

**Methods:**
* `RetryInfo clone()` -- Returns a deep copy of the message.
* `RetryInfo copyWith(void Function(RetryInfo) updates)` -- Returns a deep copy and applies `updates`.
* `void clearRetryDelay()` -- Clears the `retryDelay` field.
* `bool hasRetryDelay()` -- Returns true if `retryDelay` is set.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';
import 'src/protos/google/protobuf/duration.pb.dart';
import 'package:fixnum/fixnum.dart';

final retryInfo = RetryInfo()
  // Clients should wait at least this long between retrying the same request.
  ..retryDelay = (Duration()..seconds = Int64(5));
```

#### `DebugInfo`
Describes additional debugging info.

**Constructors:**
* `factory DebugInfo({Iterable<String>? stackEntries, String? detail})` -- Creates a new `DebugInfo` instance.
* `factory DebugInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `DebugInfo` from a serialized buffer.
* `factory DebugInfo.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `DebugInfo` from a JSON string.

**Fields:**
* `List<String> stackEntries` -- The stack trace entries indicating where the error occurred.
* `String detail` -- Additional debugging information provided by the server.

**Methods:**
* `DebugInfo clone()` -- Returns a deep copy of the message.
* `DebugInfo copyWith(void Function(DebugInfo) updates)` -- Returns a deep copy and applies `updates`.
* `void clearDetail()` -- Clears the `detail` field.
* `bool hasDetail()` -- Returns true if `detail` is set.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';

final debugInfo = DebugInfo()
  // The stack trace entries indicating where the error occurred.
  ..stackEntries.addAll(['main.dart:10', 'helper.dart:25'])
  // Additional debugging information provided by the server.
  ..detail = 'Null pointer exception encountered';
```

#### `QuotaFailure`
Describes how a quota check failed.

**Constructors:**
* `factory QuotaFailure({Iterable<QuotaFailure_Violation>? violations})` -- Creates a new `QuotaFailure` instance.
* `factory QuotaFailure.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `QuotaFailure` from a serialized buffer.
* `factory QuotaFailure.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `QuotaFailure` from a JSON string.

**Fields:**
* `List<QuotaFailure_Violation> violations` -- Describes all quota violations.

**Methods:**
* `QuotaFailure clone()` -- Returns a deep copy of the message.
* `QuotaFailure copyWith(void Function(QuotaFailure) updates)` -- Returns a deep copy and applies `updates`.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';

final quotaFailure = QuotaFailure()
  // Describes all quota violations.
  ..violations.add(
    QuotaFailure_Violation()
      // The subject on which the quota check failed.
      ..subject = 'clientip:127.0.0.1'
      // A description of how the quota check failed.
      ..description = 'Daily Limit for read operations exceeded'
  );
```

#### `QuotaFailure_Violation`
A message type used to describe a single quota violation.

**Constructors:**
* `factory QuotaFailure_Violation({String? subject, String? description})` -- Creates a new `QuotaFailure_Violation` instance.
* `factory QuotaFailure_Violation.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates from a serialized buffer.
* `factory QuotaFailure_Violation.fromJson(String json, [ExtensionRegistry registry])` -- Creates from a JSON string.

**Fields:**
* `String subject` -- The subject on which the quota check failed.
* `String description` -- A description of how the quota check failed.

**Methods:**
* `QuotaFailure_Violation clone()` -- Returns a deep copy of the message.
* `QuotaFailure_Violation copyWith(void Function(QuotaFailure_Violation) updates)` -- Returns a deep copy and applies `updates`.
* `void clearSubject()` -- Clears the `subject` field.
* `bool hasSubject()` -- Returns true if `subject` is set.
* `void clearDescription()` -- Clears the `description` field.
* `bool hasDescription()` -- Returns true if `description` is set.

#### `ErrorInfo`
Describes the cause of the error with structured details.

**Constructors:**
* `factory ErrorInfo({String? reason, String? domain})` -- Creates a new `ErrorInfo` instance.
* `factory ErrorInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates an `ErrorInfo` from a serialized buffer.
* `factory ErrorInfo.fromJson(String json, [ExtensionRegistry registry])` -- Creates an `ErrorInfo` from a JSON string.

**Fields:**
* `String reason` -- The reason of the error.
* `String domain` -- The logical grouping to which the "reason" belongs.
* `Map<String, String> metadata` -- Additional structured details about this error.

**Methods:**
* `ErrorInfo clone()` -- Returns a deep copy of the message.
* `ErrorInfo copyWith(void Function(ErrorInfo) updates)` -- Returns a deep copy and applies `updates`.
* `void clearReason()` -- Clears the `reason` field.
* `bool hasReason()` -- Returns true if `reason` is set.
* `void clearDomain()` -- Clears the `domain` field.
* `bool hasDomain()` -- Returns true if `domain` is set.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';

final errorInfo = ErrorInfo()
  // The reason of the error. This is a constant value that identifies the proximate cause.
  ..reason = 'API_DISABLED'
  // The logical grouping to which the "reason" belongs.
  ..domain = 'googleapis.com'
  // Additional structured details about this error.
  ..metadata.addAll({
    'resource': 'projects/123',
    'service': 'pubsub.googleapis.com'
  });
```

#### `PreconditionFailure`
Describes what preconditions have failed.

**Constructors:**
* `factory PreconditionFailure({Iterable<PreconditionFailure_Violation>? violations})` -- Creates a new `PreconditionFailure` instance.
* `factory PreconditionFailure.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates from a serialized buffer.
* `factory PreconditionFailure.fromJson(String json, [ExtensionRegistry registry])` -- Creates from a JSON string.

**Fields:**
* `List<PreconditionFailure_Violation> violations` -- Describes all precondition violations.

**Methods:**
* `PreconditionFailure clone()` -- Returns a deep copy of the message.
* `PreconditionFailure copyWith(void Function(PreconditionFailure) updates)` -- Returns a deep copy and applies `updates`.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';

final preconditionFailure = PreconditionFailure()
  // Describes all precondition violations.
  ..violations.add(
    PreconditionFailure_Violation()
      // The type of PreconditionFailure.
      ..type = 'TOS'
      // The subject, relative to the type, that failed.
      ..subject = 'google.com/cloud'
      // A description of how the precondition failed.
      ..description = 'Terms of service not accepted'
  );
```

#### `PreconditionFailure_Violation`
A message type used to describe a single precondition failure.

**Constructors:**
* `factory PreconditionFailure_Violation({String? type, String? subject, String? description})` -- Creates a new `PreconditionFailure_Violation` instance.
* `factory PreconditionFailure_Violation.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates from a serialized buffer.
* `factory PreconditionFailure_Violation.fromJson(String json, [ExtensionRegistry registry])` -- Creates from a JSON string.

**Fields:**
* `String type` -- The type of PreconditionFailure.
* `String subject` -- The subject, relative to the type, that failed.
* `String description` -- A description of how the precondition failed.

**Methods:**
* `PreconditionFailure_Violation clone()` -- Returns a deep copy of the message.
* `PreconditionFailure_Violation copyWith(void Function(PreconditionFailure_Violation) updates)` -- Returns a deep copy and applies `updates`.
* `void clearType()` -- Clears the `type` field.
* `bool hasType()` -- Returns true if `type` is set.
* `void clearSubject()` -- Clears the `subject` field.
* `bool hasSubject()` -- Returns true if `subject` is set.
* `void clearDescription()` -- Clears the `description` field.
* `bool hasDescription()` -- Returns true if `description` is set.

#### `BadRequest`
Describes violations in a client request. This error type focuses on the syntactic aspects of the request.

**Constructors:**
* `factory BadRequest({Iterable<BadRequest_FieldViolation>? fieldViolations})` -- Creates a new `BadRequest` instance.
* `factory BadRequest.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `BadRequest` from a serialized buffer.
* `factory BadRequest.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `BadRequest` from a JSON string.

**Fields:**
* `List<BadRequest_FieldViolation> fieldViolations` -- Describes all violations in a client request.

**Methods:**
* `BadRequest clone()` -- Returns a deep copy of the message.
* `BadRequest copyWith(void Function(BadRequest) updates)` -- Returns a deep copy and applies `updates`.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';

final badRequest = BadRequest()
  // Describes all violations in a client request.
  ..fieldViolations.add(
    BadRequest_FieldViolation()
      // A path leading to a field in the request body.
      ..field_1 = 'field_violations.field'
      // A description of why the request element is bad.
      ..description = 'Field is required'
  );
```

#### `BadRequest_FieldViolation`
A message type used to describe a single bad request field.

**Constructors:**
* `factory BadRequest_FieldViolation({String? field_1, String? description})` -- Creates a new `BadRequest_FieldViolation` instance.
* `factory BadRequest_FieldViolation.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates from a serialized buffer.
* `factory BadRequest_FieldViolation.fromJson(String json, [ExtensionRegistry registry])` -- Creates from a JSON string.

**Fields:**
* `String field_1` -- A path leading to a field in the request body. *(Note: Mapped to `field_1` in Dart due to `field` being a reserved word)*.
* `String description` -- A description of why the request element is bad.

**Methods:**
* `BadRequest_FieldViolation clone()` -- Returns a deep copy of the message.
* `BadRequest_FieldViolation copyWith(void Function(BadRequest_FieldViolation) updates)` -- Returns a deep copy and applies `updates`.
* `void clearField_1()` -- Clears the `field_1` field.
* `bool hasField_1()` -- Returns true if `field_1` is set.
* `void clearDescription()` -- Clears the `description` field.
* `bool hasDescription()` -- Returns true if `description` is set.

#### `RequestInfo`
Contains metadata about the request that clients can attach when filing a bug or providing other forms of feedback.

**Constructors:**
* `factory RequestInfo({String? requestId, String? servingData})` -- Creates a new `RequestInfo` instance.
* `factory RequestInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `RequestInfo` from a serialized buffer.
* `factory RequestInfo.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `RequestInfo` from a JSON string.

**Fields:**
* `String requestId` -- An opaque string that should only be interpreted by the service generating it.
* `String servingData` -- Any data that was used to serve this request.

**Methods:**
* `RequestInfo clone()` -- Returns a deep copy of the message.
* `RequestInfo copyWith(void Function(RequestInfo) updates)` -- Returns a deep copy and applies `updates`.
* `void clearRequestId()` -- Clears the `requestId` field.
* `bool hasRequestId()` -- Returns true if `requestId` is set.
* `void clearServingData()` -- Clears the `servingData` field.
* `bool hasServingData()` -- Returns true if `servingData` is set.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';

final requestInfo = RequestInfo()
  // An opaque string that should only be interpreted by the service generating it.
  ..requestId = 'req-12345'
  // Any data that was used to serve this request.
  ..servingData = 'encrypted-stack-trace';
```

#### `ResourceInfo`
Describes the resource that is being accessed.

**Constructors:**
* `factory ResourceInfo({String? resourceType, String? resourceName, String? owner, String? description})` -- Creates a new `ResourceInfo` instance.
* `factory ResourceInfo.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `ResourceInfo` from a serialized buffer.
* `factory ResourceInfo.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `ResourceInfo` from a JSON string.

**Fields:**
* `String resourceType` -- A name for the type of resource being accessed.
* `String resourceName` -- The name of the resource being accessed.
* `String owner` -- The owner of the resource (optional).
* `String description` -- Describes what error is encountered when accessing this resource.

**Methods:**
* `ResourceInfo clone()` -- Returns a deep copy of the message.
* `ResourceInfo copyWith(void Function(ResourceInfo) updates)` -- Returns a deep copy and applies `updates`.
* `void clearResourceType()` -- Clears the `resourceType` field.
* `bool hasResourceType()` -- Returns true if `resourceType` is set.
* `void clearResourceName()` -- Clears the `resourceName` field.
* `bool hasResourceName()` -- Returns true if `resourceName` is set.
* `void clearOwner()` -- Clears the `owner` field.
* `bool hasOwner()` -- Returns true if `owner` is set.
* `void clearDescription()` -- Clears the `description` field.
* `bool hasDescription()` -- Returns true if `description` is set.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';

final resourceInfo = ResourceInfo()
  // A name for the type of resource being accessed.
  ..resourceType = 'sql table'
  // The name of the resource being accessed.
  ..resourceName = 'users'
  // The owner of the resource (optional).
  ..owner = 'project:12345'
  // Describes what error is encountered when accessing this resource.
  ..description = 'Requires writer permission on the developer console project';
```

#### `Help`
Provides links to documentation or for performing an out of band action.

**Constructors:**
* `factory Help({Iterable<Help_Link>? links})` -- Creates a new `Help` instance.
* `factory Help.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `Help` from a serialized buffer.
* `factory Help.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `Help` from a JSON string.

**Fields:**
* `List<Help_Link> links` -- URL(s) pointing to additional information on handling the current error.

**Methods:**
* `Help clone()` -- Returns a deep copy of the message.
* `Help copyWith(void Function(Help) updates)` -- Returns a deep copy and applies `updates`.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';

final help = Help()
  // URL(s) pointing to additional information on handling the current error.
  ..links.add(
    Help_Link()
      // Describes what the link offers.
      ..description = 'Enable the service'
      // The URL of the link.
      ..url = 'https://console.cloud.google.com'
  );
```

#### `Help_Link`
Describes a URL link.

**Constructors:**
* `factory Help_Link({String? description, String? url})` -- Creates a new `Help_Link` instance.
* `factory Help_Link.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates from a serialized buffer.
* `factory Help_Link.fromJson(String json, [ExtensionRegistry registry])` -- Creates from a JSON string.

**Fields:**
* `String description` -- Describes what the link offers.
* `String url` -- The URL of the link.

**Methods:**
* `Help_Link clone()` -- Returns a deep copy of the message.
* `Help_Link copyWith(void Function(Help_Link) updates)` -- Returns a deep copy and applies `updates`.
* `void clearDescription()` -- Clears the `description` field.
* `bool hasDescription()` -- Returns true if `description` is set.
* `void clearUrl()` -- Clears the `url` field.
* `bool hasUrl()` -- Returns true if `url` is set.

#### `LocalizedMessage`
Provides a localized error message that is safe to return to the user which can be attached to an RPC error.

**Constructors:**
* `factory LocalizedMessage({String? locale, String? message})` -- Creates a new `LocalizedMessage` instance.
* `factory LocalizedMessage.fromBuffer(List<int> data, [ExtensionRegistry registry])` -- Creates a `LocalizedMessage` from a serialized buffer.
* `factory LocalizedMessage.fromJson(String json, [ExtensionRegistry registry])` -- Creates a `LocalizedMessage` from a JSON string.

**Fields:**
* `String locale` -- The locale used following the specification defined at `http://www.rfc-editor.org/rfc/bcp/bcp47.txt`.
* `String message` -- The localized error message in the above locale.

**Methods:**
* `LocalizedMessage clone()` -- Returns a deep copy of the message.
* `LocalizedMessage copyWith(void Function(LocalizedMessage) updates)` -- Returns a deep copy and applies `updates`.
* `void clearLocale()` -- Clears the `locale` field.
* `bool hasLocale()` -- Returns true if `locale` is set.
* `void clearMessage()` -- Clears the `message` field.
* `bool hasMessage()` -- Returns true if `message` is set.

**Example:**
```dart
import 'src/protos/google/rpc/error_details.pb.dart';

final localizedMessage = LocalizedMessage()
  // The locale used following the specification defined at http://www.rfc-editor.org/rfc/bcp/bcp47.txt.
  ..locale = 'en-US'
  // The localized error message in the above locale.
  ..message = 'Invalid password';
```

## 2. Enums
*(No public enums are defined in this module)*

## 3. Extensions
*(No public extensions are defined in this module)*

## 4. Top-Level Functions
*(No top-level functions are defined in this module)*
