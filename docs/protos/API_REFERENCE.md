# Protobuf Integration API Reference

This document provides a comprehensive reference for the Protobuf-generated Dart classes used in the **Protobuf Integration** module. These classes represent standard Google RPC and Protobuf well-known types.

## Import Paths

To use these classes in your project, use the following imports:

```dart
// For RetryInfo, BadRequest, ErrorInfo, etc.
import 'package:grpc-dart/protos.dart'; 

// For Status and Any (not exported in protos.dart)
import 'package:grpc-dart/src/generated/google/rpc/status.pb.dart';
import 'package:grpc-dart/src/generated/google/protobuf/any.pb.dart';
```

---

## 1. Classes

### google.protobuf

#### **Any**
`Any` contains an arbitrary serialized protocol buffer message along with a URL that describes the type of the serialized message.

**Fields:**
- `String typeUrl` - A URL/resource name that uniquely identifies the type of the serialized protocol buffer message (e.g., `type.googleapis.com/google.profile.Person`).
- `List<int> value` - The serialized protocol buffer message as bytes.

**Constructors:**
- `Any({String? typeUrl, List<int>? value})` - Default constructor.
- `Any.fromBuffer(List<int> data, [ExtensionRegistry registry])` - Deserializes from binary format.
- `Any.fromJson(String json, [ExtensionRegistry registry])` - Deserializes from JSON format.

**Methods:**
- `static Any pack(GeneratedMessage message, {String typeUrlPrefix = 'type.googleapis.com'})` - Creates a new `Any` encoding the given `message`.
- `bool canUnpackInto(GeneratedMessage message)` - Returns `true` if this `Any` can be unpacked into the given message type.
- `void unpackInto(GeneratedMessage message)` - Unpacks the serialized message into the provided `message` instance.
- `bool hasTypeUrl()` / `void clearTypeUrl()` - Checks or clears the `typeUrl` field.
- `bool hasValue()` / `void clearValue()` - Checks or clears the `value` field.
- `Any clone()` - Creates a deep copy of the message.

**Usage Example:**
```dart
import 'package:grpc-dart/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc-dart/protos.dart';

// Packing a message into Any
final badRequest = BadRequest()
  ..fieldViolations.add(BadRequest_FieldViolation()
    ..field_1 = 'email'
    ..description = 'Invalid email format');

final any = Any.pack(badRequest);

// Unpacking from Any
if (any.canUnpackInto(BadRequest())) {
  final unpacked = BadRequest();
  any.unpackInto(unpacked);
  print(unpacked.fieldViolations.first.description);
}
```

#### **Duration**
A `Duration` represents a signed, fixed-length span of time represented as a count of seconds and fractions of seconds at nanosecond resolution.

**Fields:**
- `Int64 seconds` - Signed seconds of the span of time. Range is approximately +-10,000 years.
- `int nanos` - Signed fractions of a second at nanosecond resolution. Must be of the same sign as the `seconds` field.

**Constructors:**
- `Duration({Int64? seconds, int? nanos})`
- `Duration.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `Duration.fromJson(String json, [ExtensionRegistry registry])`

**Methods:**
- `core.Duration toDart()` - Converts this proto `Duration` to a standard Dart `core.Duration`.
- `static Duration fromDart(core.Duration duration)` - Creates a proto `Duration` from a standard Dart `core.Duration`.
- `bool hasSeconds()` / `void clearSeconds()` - Checks or clears the `seconds` field.
- `bool hasNanos()` / `void clearNanos()` - Checks or clears the `nanos` field.

**Usage Example:**
```dart
import 'package:grpc-dart/protos.dart';
import 'package:fixnum/fixnum.dart';

// Create using cascade notation
final duration = Duration()
  ..seconds = Int64(30)
  ..nanos = 500000;

// Convert to/from Dart core.Duration
final dartDuration = duration.toDart();
final protoDuration = Duration.fromDart(Duration(minutes: 5));
```

---

### google.rpc

#### **Status**
The `Status` type defines a logical error model suitable for both REST and gRPC APIs.

**Fields:**
- `int code` - The status code, which should be an enum value of `google.rpc.Code` (represented as an integer).
- `String message` - A developer-facing error message, which should be in English.
- `PbList<Any> details` - A list of messages that carry the error details (e.g., `BadRequest`, `RetryInfo`).

**Constructors:**
- `Status({int? code, String? message, Iterable<Any>? details})`
- `Status.fromBuffer(List<int> data, [ExtensionRegistry registry])`
- `Status.fromJson(String json, [ExtensionRegistry registry])`

**Usage Example:**
```dart
import 'package:grpc-dart/src/generated/google/rpc/status.pb.dart';
import 'package:grpc-dart/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc-dart/protos.dart';

final status = Status()
  ..code = 3 // INVALID_ARGUMENT
  ..message = 'The request parameters are invalid.'
  ..details.add(Any.pack(BadRequest()
    ..fieldViolations.add(BadRequest_FieldViolation()
      ..field_1 = 'username'
      ..description = 'Username is already taken')));
```

#### **RetryInfo**
Describes when the clients can retry a failed request.

**Fields:**
- `Duration retryDelay` - Clients should wait at least this long since receiving the error response before retrying.

**Usage Example:**
```dart
final retryInfo = RetryInfo()
  ..retryDelay = (Duration()..seconds = Int64(5));
```

#### **DebugInfo**
Describes additional debugging info, typically for non-production environments.

**Fields:**
- `PbList<String> stackEntries` - The stack trace entries indicating where the error occurred.
- `String detail` - Additional debugging information provided by the server.

#### **QuotaFailure**
Describes how a quota check failed.

**Fields:**
- `PbList<QuotaFailure_Violation> violations` - Describes all quota violations.

#### **QuotaFailure_Violation**
**Fields:**
- `String subject` - The subject on which the quota check failed (e.g., "clientip:<ip address>" or "project:<id>").
- `String description` - A description of how the quota check failed.

#### **ErrorInfo**
Describes the cause of the error with structured details.

**Fields:**
- `String reason` - The reason of the error. A constant value identifying the cause (e.g., "API_DISABLED").
- `String domain` - The logical grouping to which the "reason" belongs (e.g., "googleapis.com").
- `PbMap<String, String> metadata` - Additional structured details about this error.

#### **PreconditionFailure**
Describes what preconditions have failed (e.g., Terms of Service not accepted).

**Fields:**
- `PbList<PreconditionFailure_Violation> violations` - Describes all precondition violations.

#### **PreconditionFailure_Violation**
**Fields:**
- `String type` - The type of PreconditionFailure (e.g., "TOS").
- `String subject` - The subject that failed (e.g., "google.com/cloud").
- `String description` - A description of how the precondition failed.

#### **BadRequest**
Describes violations in a client request. Focuses on the syntactic aspects of the request.

**Fields:**
- `PbList<BadRequest_FieldViolation> fieldViolations` - Describes all violations in a client request.

#### **BadRequest_FieldViolation**
**Fields:**
- `String field_1` - A path leading to a field in the request body (e.g., "field_violations.field").
- `String description` - A description of why the request element is bad.

#### **RequestInfo**
Contains metadata about the request for bug filing or feedback.

**Fields:**
- `String requestId` - An opaque string identifying the request in the service logs.
- `String servingData` - Any data used to serve this request (e.g., encrypted stack trace).

#### **ResourceInfo**
Describes the resource that is being accessed.

**Fields:**
- `String resourceType` - A name for the type of resource (e.g., "sql table").
- `String resourceName` - The name of the resource being accessed.
- `String owner` - The owner of the resource (optional).
- `String description` - Error encountered when accessing this resource.

#### **Help**
Provides links to documentation or for performing an out-of-band action.

**Fields:**
- `PbList<Help_Link> links` - URL(s) pointing to additional information.

#### **Help_Link**
**Fields:**
- `String description` - Describes what the link offers.
- `String url` - The URL of the link.

#### **LocalizedMessage**
Provides a localized error message safe to return to the user.

**Fields:**
- `String locale` - The locale following BCP-47 (e.g., "en-US", "fr-CH").
- `String message` - The localized error message.

---

## 2. Common Message Methods

Every Protobuf message class (including those listed above) inherits from `GeneratedMessage` and provides the following standard methods:

- `T clone()` - Creates a deep copy of the message.
- `T copyWith(void Function(T) updates)` - Returns a copy of the message with the provided updates applied.
- `List<int> writeToBuffer()` - Serializes the message to binary format.
- `String writeToJson()` - Serializes the message to JSON string format.
- `void mergeFromBuffer(List<int> data)` - Merges data from a binary buffer into the current instance.
- `void mergeFromJson(String json)` - Merges data from a JSON string into the current instance.
- `bool hasField(int tagNumber)` - Checks if a field with the given tag number is set.
- `void clearField(int tagNumber)` - Clears the field with the given tag number.
- `void clear()` - Clears all fields in the message.

## 3. Enums
No public enums are defined in the provided Protobuf modules. Status codes are typically handled via the `StatusCode` enum in `package:grpc/grpc.dart`.

## 4. Extensions
No public extensions are defined in the provided Protobuf modules.
