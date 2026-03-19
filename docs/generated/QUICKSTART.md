# Generated Module Quickstart

## 1. Overview
The Generated module provides the generated Dart classes for standard Google Protocol Buffer well-known types (`Any`, `Duration`) and Google RPC error models (`Status`, `ErrorInfo`, `BadRequest`, etc.). These generated message classes allow developers to easily construct, serialize, deserialize, and introspect rich standard gRPC error payloads, debugging metadata, and generic messages across different APIs.

## 2. Import
To use these generated classes, import the corresponding `.pb.dart` files from the `lib/src/generated/` directory. You will likely also need the `Int64` type from the `fixnum` package:

```dart
import 'package:fixnum/fixnum.dart';
import 'package:grpc/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc/src/generated/google/protobuf/duration.pb.dart';
import 'package:grpc/src/generated/google/rpc/error_details.pb.dart';
import 'package:grpc/src/generated/google/rpc/status.pb.dart';
```

## 3. Setup
You can directly instantiate any of the generated message classes using their named constructors or the cascade builder pattern. They are regular Dart classes inheriting from `$pb.GeneratedMessage`.

```dart
// Instantiate a protobuf Duration using the cascade builder pattern
final duration = Duration()
  // Signed seconds of the span of time. Must be from -315,576,000,000
  // to +315,576,000,000 inclusive.
  ..seconds = Int64(60)
  // Signed fractions of a second at nanosecond resolution of the span
  // of time.
  ..nanos = 0;

// Instantiate a Status message using the cascade builder pattern
final status = Status()
  // The status code, which should be an enum value of google.rpc.Code.
  ..code = 3 // INVALID_ARGUMENT
  // A developer-facing error message, which should be in English.
  ..message = 'Invalid request payload'
  // A list of messages that carry the error details.
  ..details.addAll([]); // List of Any
```

## 4. Common Operations

The following examples exhaustively cover EVERY message and field generated in this module. *(Note: There are no explicit Enums or Services defined in these specific proto files, only Messages).*

### Using `google.protobuf.Duration`
The `Duration` message represents a signed, fixed-length span of time. It provides helpful `toDart()` and `fromDart()` extension methods.

```dart
final duration = Duration()
  // Signed seconds of the span of time. Must be from -315,576,000,000
  // to +315,576,000,000 inclusive.
  ..seconds = Int64(3600)
  // Signed fractions of a second at nanosecond resolution of the span
  // of time.
  ..nanos = 500000000;

// Convert to/from standard dart:core Duration
final dartDuration = duration.toDart();
final protoDuration = Duration.fromDart(dartDuration);
```

### Using `google.protobuf.Any`
The `Any` message contains an arbitrary serialized protocol buffer message along with a URL that describes its type.

```dart
final anyMessage = Any()
  // A URL/resource name that uniquely identifies the type of the serialized
  // protocol buffer message.
  ..typeUrl = 'type.googleapis.com/google.protobuf.Duration'
  // Must be a valid serialized protocol buffer of the above specified type.
  ..value = duration.writeToBuffer();

// Or conveniently pack it using the static helper method:
final packedAny = Any.pack(duration);
```

### Using `google.rpc.Status`
The `Status` message defines a logical error model suitable for REST and RPC APIs.

```dart
final errorStatus = Status()
  // The status code, which should be an enum value of google.rpc.Code.
  ..code = 7 // PERMISSION_DENIED
  // A developer-facing error message, which should be in English.
  ..message = 'User lacks required permissions.'
  // A list of messages that carry the error details.
  ..details.add(packedAny);
```

### Using `google.rpc.error_details` (Rich Error Models)
The `error_details.proto` defines a standard set of rich error message payloads. Below is a complete guide to instantiating every single one, covering all their respective fields.

**RetryInfo**
Describes when the clients can retry a failed request.
```dart
final retryInfo = RetryInfo()
  // Clients should wait at least this long between retrying the same request.
  ..retryDelay = (Duration()
    ..seconds = Int64(5)
    ..nanos = 0);
```

**DebugInfo**
Describes additional debugging info.
```dart
final debugInfo = DebugInfo()
  // The stack trace entries indicating where the error occurred.
  ..stackEntries.addAll(['package:my_app/main.dart:10', 'package:grpc/src/server.dart:45'])
  // Additional debugging information provided by the server.
  ..detail = 'Null pointer exception encountered in the main handler.';
```

**QuotaFailure & QuotaFailure_Violation**
Describes how a quota check failed.
```dart
final quotaViolation = QuotaFailure_Violation()
  // The subject on which the quota check failed.
  // For example, "clientip:<ip address of client>"
  ..subject = 'clientip:192.168.1.1'
  // A description of how the quota check failed.
  ..description = 'Daily Limit for read operations exceeded';

final quotaFailure = QuotaFailure()
  // Describes all quota violations.
  ..violations.add(quotaViolation);
```

**ErrorInfo**
Describes the cause of the error with structured details.
```dart
final errorInfo = ErrorInfo()
  // The reason of the error. This is a constant value that identifies the
  // proximate cause of the error.
  ..reason = 'API_DISABLED'
  // The logical grouping to which the "reason" belongs.
  ..domain = 'googleapis.com'
  // Additional structured details about this error.
  ..metadata.addAll({
    'resource': 'projects/123',
    'service': 'pubsub.googleapis.com',
  });
```

**PreconditionFailure & PreconditionFailure_Violation**
Describes what preconditions have failed.
```dart
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
```

**BadRequest & BadRequest_FieldViolation**
Describes violations in a client request. *Note: The protobuf field name `field` is generated as `field_1` in Dart to avoid naming conflicts with Dart keywords.*
```dart
final fieldViolation = BadRequest_FieldViolation()
  // A path leading to a field in the request body.
  ..field_1 = 'user.password'
  // A description of why the request element is bad.
  ..description = 'Password must be at least 8 characters long.';

final badRequest = BadRequest()
  // Describes all violations in a client request.
  ..fieldViolations.add(fieldViolation);
```

**RequestInfo**
Contains metadata about the request that clients can attach when filing a bug.
```dart
final requestInfo = RequestInfo()
  // An opaque string that should only be interpreted by the service generating it.
  ..requestId = 'req-987654321'
  // Any data that was used to serve this request.
  ..servingData = 'base64_encrypted_stack_trace_data';
```

**ResourceInfo**
Describes the resource that is being accessed.
```dart
final resourceInfo = ResourceInfo()
  // A name for the type of resource being accessed, e.g. "sql table" or the type URL.
  ..resourceType = 'type.googleapis.com/google.pubsub.v1.Topic'
  // The name of the resource being accessed.
  ..resourceName = 'projects/my-project/topics/my-topic'
  // The owner of the resource (optional).
  ..owner = 'user:admin@example.com'
  // Describes what error is encountered when accessing this resource.
  ..description = 'Topic does not exist or was deleted.';
```

**Help & Help_Link**
Provides links to documentation or for performing an out-of-band action.
```dart
final helpLink = Help_Link()
  // Describes what the link offers.
  ..description = 'Google Cloud Console - Quotas'
  // The URL of the link.
  ..url = 'https://console.cloud.google.com/project/quotas';

final help = Help()
  // URL(s) pointing to additional information on handling the current error.
  ..links.add(helpLink);
```

**LocalizedMessage**
Provides a localized error message that is safe to return to the user.
```dart
final localizedMessage = LocalizedMessage()
  // The locale used following the specification defined at
  // http://www.rfc-editor.org/rfc/bcp/bcp47.txt.
  ..locale = 'en-US'
  // The localized error message in the above locale.
  ..message = 'You do not have permission to access this resource.';
```

## 5. Configuration
The Generated module does not require explicit configuration files or environment variables. All serialization and deserialization rely inherently on the standard implementations provided by the `protobuf` package.

Ensure your `pubspec.yaml` includes:
- `protobuf` (Required for base `$pb.GeneratedMessage` and extensions).
- `fixnum` (Required for `$fixnum.Int64` support for `int64` proto fields like `Duration.seconds`).

## 6. Related Modules
- `package:protobuf/protobuf.dart`: The core Dart protobuf library containing serializers, deserializers, and base classes.
- `package:fixnum/fixnum.dart`: The library providing the 64-bit integer (`Int64`) implementation necessary for many proto-generated types.
