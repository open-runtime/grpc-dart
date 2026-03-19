# Generated Protocol Buffers API Reference

This document provides a comprehensive API reference for the generated protobuf models in `lib/src/generated/`.

These classes are typically used to represent gRPC error details and well-known types. When creating instances, the Dart builder pattern (cascade `..`) is highly recommended. Note that Protobuf-generated Dart code converts snake_case field names to camelCase (e.g., `type_url` becomes `typeUrl`).

## 1. Classes

### Any (`google.protobuf.Any`)
`Any` contains an arbitrary serialized protocol buffer message along with a URL that describes the type of the serialized message.

**Fields:**
- `String typeUrl` - A URL/resource name that uniquely identifies the type.
- `List<int> value` - Must be a valid serialized protocol buffer of the above specified type.

**Example:**
```dart
import 'package:grpc/src/generated/google/protobuf/any.pb.dart';

// Pack and unpack a message using Any
final anyMessage = Any()
  // The typeUrl will be used to resolve the type of the serialized message.
  ..typeUrl = 'type.googleapis.com/google.rpc.ErrorInfo'
  ..value = <int>[1, 2, 3]; // Serialized bytes of the embedded message
```

### BadRequest (`google.rpc.BadRequest`)
Describes violations in a client request. This error type focuses on the syntactic aspects of the request.

**Fields:**
- `PbList<BadRequest_FieldViolation> fieldViolations` - Describes all violations in a client request.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final badRequest = BadRequest()
  ..fieldViolations.add(
    BadRequest_FieldViolation()
      // A path leading to a field in the request body. Note: mapped from `field` in protobuf.
      ..field_1 = 'username'
      // A description of why the request element is bad.
      ..description = 'Username must be at least 5 characters long.'
  );
```

### BadRequest_FieldViolation
A message type used to describe a single bad request field.

**Fields:**
- `String field_1` - A path leading to a field in the request body. Note: mapped from `field` in protobuf.
- `String description` - A description of why the request element is bad.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final fieldViolation = BadRequest_FieldViolation()
  ..field_1 = 'password'
  ..description = 'Password is too weak.';
```

### DebugInfo (`google.rpc.DebugInfo`)
Describes additional debugging info.

**Fields:**
- `PbList<String> stackEntries` - The stack trace entries indicating where the error occurred.
- `String detail` - Additional debugging information provided by the server.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final debugInfo = DebugInfo()
  // The stack trace entries indicating where the error occurred.
  ..stackEntries.addAll(['main.dart:10', 'service.dart:55'])
  // Additional debugging information provided by the server.
  ..detail = 'Null pointer exception encountered';
```

### Duration (`google.protobuf.Duration`)
A Duration represents a signed, fixed-length span of time represented as a count of seconds and fractions of seconds at nanosecond resolution.

**Fields:**
- `Int64 seconds` - Signed seconds of the span of time.
- `int nanos` - Signed fractions of a second at nanosecond resolution of the span of time.

**Example:**
```dart
import 'package:fixnum/fixnum.dart';
import 'package:grpc/src/generated/google/protobuf/duration.pb.dart' as pb_duration;
import 'dart:core' as core;

final duration = pb_duration.Duration()
  // Signed seconds of the span of time.
  ..seconds = Int64(60)
  // Signed fractions of a second at nanosecond resolution.
  ..nanos = 500000000;

// Or construct from a Dart core Duration
final coreDuration = core.Duration(seconds: 60, milliseconds: 500);
final pbDuration = pb_duration.Duration.fromDart(coreDuration);
```

### ErrorInfo (`google.rpc.ErrorInfo`)
Describes the cause of the error with structured details.

**Fields:**
- `String reason` - The reason of the error.
- `String domain` - The logical grouping to which the "reason" belongs.
- `PbMap<String, String> metadata` - Additional structured details about this error.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final errorInfo = ErrorInfo()
  // The reason of the error. This is a constant value.
  ..reason = 'USER_NOT_FOUND'
  // The logical grouping to which the "reason" belongs (e.g., service name).
  ..domain = 'accounts.myapi.com'
  // Additional structured details about this error.
  ..metadata.addAll({'userId': '12345', 'region': 'us-east'});
```

### Help (`google.rpc.Help`)
Provides links to documentation or for performing an out of band action.

**Fields:**
- `PbList<Help_Link> links` - URL(s) pointing to additional information on handling the current error.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final help = Help()
  ..links.add(
    Help_Link()
      ..description = 'API Documentation'
      ..url = 'https://docs.myapi.com/errors/user_not_found'
  );
```

### Help_Link
Describes a URL link.

**Fields:**
- `String description` - Describes what the link offers.
- `String url` - The URL of the link.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final helpLink = Help_Link()
  ..description = 'Troubleshooting Guide'
  ..url = 'https://example.com/troubleshoot';
```

### LocalizedMessage (`google.rpc.LocalizedMessage`)
Provides a localized error message that is safe to return to the user which can be attached to an RPC error.

**Fields:**
- `String locale` - The locale used following the specification defined at BCP47.
- `String message` - The localized error message in the above locale.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final localizedMsg = LocalizedMessage()
  // The locale used following the specification defined at BCP47.
  ..locale = 'en-US'
  // The localized error message in the above locale.
  ..message = 'The requested resource was not found.';
```

### PreconditionFailure (`google.rpc.PreconditionFailure`)
Describes what preconditions have failed.

**Fields:**
- `PbList<PreconditionFailure_Violation> violations` - Describes all precondition violations.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final preconditionFailure = PreconditionFailure()
  ..violations.add(
    PreconditionFailure_Violation()
      // The type of PreconditionFailure.
      ..type = 'TOS_ACCEPTED'
      // The subject, relative to the type, that failed.
      ..subject = 'user_123'
      // A description of how the precondition failed.
      ..description = 'User must accept the latest Terms of Service.'
  );
```

### PreconditionFailure_Violation
A message type used to describe a single precondition failure.

**Fields:**
- `String type` - The type of PreconditionFailure.
- `String subject` - The subject, relative to the type, that failed.
- `String description` - A description of how the precondition failed.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final preconditionViolation = PreconditionFailure_Violation()
  ..type = 'PAYMENT_REQUIRED'
  ..subject = 'account_balance'
  ..description = 'Account balance is negative.';
```

### QuotaFailure (`google.rpc.QuotaFailure`)
Describes how a quota check failed.

**Fields:**
- `PbList<QuotaFailure_Violation> violations` - Describes all quota violations.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final quotaFailure = QuotaFailure()
  ..violations.add(
    QuotaFailure_Violation()
      // The subject on which the quota check failed.
      ..subject = 'client_ip:192.168.1.1'
      // A description of how the quota check failed.
      ..description = 'Rate limit exceeded. Try again in 60 seconds.'
  );
```

### QuotaFailure_Violation
A message type used to describe a single quota violation.

**Fields:**
- `String subject` - The subject on which the quota check failed.
- `String description` - A description of how the quota check failed.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final quotaViolation = QuotaFailure_Violation()
  ..subject = 'project:12345'
  ..description = 'Daily API limit reached.';
```

### RequestInfo (`google.rpc.RequestInfo`)
Contains metadata about the request that clients can attach when filing a bug or providing other forms of feedback.

**Fields:**
- `String requestId` - An opaque string that should only be interpreted by the service generating it.
- `String servingData` - Any data that was used to serve this request.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final requestInfo = RequestInfo()
  // An opaque string identifying the request.
  ..requestId = 'req_987654321'
  // Any data that was used to serve this request.
  ..servingData = 'server_node_alpha';
```

### ResourceInfo (`google.rpc.ResourceInfo`)
Describes the resource that is being accessed.

**Fields:**
- `String resourceType` - A name for the type of resource being accessed.
- `String resourceName` - The name of the resource being accessed.
- `String owner` - The owner of the resource (optional).
- `String description` - Describes what error is encountered when accessing this resource.

**Example:**
```dart
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final resourceInfo = ResourceInfo()
  ..resourceType = 'UserDocument'
  ..resourceName = 'projects/my-project/documents/123'
  ..owner = 'user_999'
  ..description = 'Insufficient permissions to read the document.';
```

### RetryInfo (`google.rpc.RetryInfo`)
Describes when the clients can retry a failed request.

**Fields:**
- `Duration retryDelay` - Clients should wait at least this long between retrying the same request.

**Example:**
```dart
import 'package:fixnum/fixnum.dart';
import 'package:grpc/src/generated/google/protobuf/duration.pb.dart' as pb_duration;
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final retryInfo = RetryInfo()
  // Clients should wait until `retryDelay` has passed before retrying.
  ..retryDelay = (pb_duration.Duration()
    ..seconds = Int64(30)
    ..nanos = 0);
```

### Status (`google.rpc.Status`)
The `Status` type defines a logical error model that is suitable for different programming environments, including REST APIs and RPC APIs.

**Fields:**
- `int code` - The status code.
- `String message` - A developer-facing error message.
- `PbList<Any> details` - A list of messages that carry the error details.

**Example:**
```dart
import 'package:grpc/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc/src/generated/google/rpc/status.pb.dart';
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';

final errorInfo = ErrorInfo()
  ..reason = 'UNAUTHENTICATED'
  ..domain = 'myapi.com';

final status = Status()
  // The status code.
  ..code = 16 // UNAUTHENTICATED
  // A developer-facing error message.
  ..message = 'Invalid authentication token.'
  // A list of messages that carry the error details.
  ..details.add(Any.pack(errorInfo));
```

## 2. Enums

None found in the provided generated code.

## 3. Extensions

None found in the provided generated code.

## 4. Top-Level Functions

None found in the provided generated code.
