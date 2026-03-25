# Generated Module Quickstart

## 1. Overview
The `Generated` module provides pre-compiled Dart Protocol Buffer classes for standard Google types. It supplies widely-used utilities for your gRPC APIs, including `Any` for arbitrary message packing, `Duration` for fixed-length time spans, and rich RPC error models like `Status` and standardized error details (e.g., `ErrorInfo`, `BadRequest`).

## 2. Naming Conventions (Protobuf to Dart)
When using Protobuf-generated Dart code, all `snake_case` field names from the `.proto` files are automatically converted to `camelCase` to follow Dart's style guidelines.

| Proto Field Name | Dart Property Name |
|------------------|--------------------|
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

**Note on Keyword Conflicts:** If a field name conflicts with a Dart keyword (e.g., `field`), the generator appends a suffix (e.g., `field_1`). These are the only exceptions where `snake_case` or numerical suffixes may appear in Dart property names.

## 3. Import
Based on the `lib` directory structure, you can import the generated models using the following paths. Always use the `package:grpc-dart/` prefix for imports.

```dart
import 'package:grpc-dart/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc-dart/src/generated/google/protobuf/duration.pb.dart';
import 'package:grpc-dart/src/generated/google/rpc/status.pb.dart';
import 'package:grpc-dart/src/generated/google/rpc/error_details.pb.dart';
```

## 4. Setup
These classes extend `$pb.GeneratedMessage`. While they provide factory constructors, the **Builder Pattern (cascade notation)** is the preferred way to instantiate and configure them. Some types, like `seconds` in `Duration`, require the `fixnum` package for 64-bit integer support.

```dart
import 'package:fixnum/fixnum.dart';
import 'package:grpc-dart/src/generated/google/rpc/error_details.pb.dart';

// Instantiating ErrorInfo using cascades
final errorInfo = ErrorInfo()
  ..reason = 'USER_NOT_FOUND' // The reason of the error. A constant value (e.g., STOCKOUT).
  ..domain = 'my-service.com' // The logical grouping to which the "reason" belongs.
  ..metadata.addAll({         // Additional structured details about this error.
    'userId': '12345',
    'attempt': '3',
  });
```

## 5. Common Operations

### Converting between Protobuf Duration and Dart Duration
The `Duration` class provides convenient `toDart()` and `fromDart()` converters.
```dart
import 'package:grpc-dart/src/generated/google/protobuf/duration.pb.dart' as pb;

// Dart core Duration to Protobuf Duration
final dartDuration = Duration(seconds: 30, milliseconds: 500);
final pbDuration = pb.Duration.fromDart(dartDuration);

// Protobuf Duration back to Dart core Duration
final backToDart = pbDuration.toDart();

// Manual configuration using cascades and fixnum.Int64
final customDuration = pb.Duration()
  ..seconds = Int64(60) // Signed seconds of the span of time.
  ..nanos = 0;          // Signed fractions of a second at nanosecond resolution.
```

### Using `Any` to Pack and Unpack Messages
The `Any` class lets you embed an arbitrary message inside another message, such as attaching debug info to a `Status`.
```dart
import 'package:grpc-dart/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc-dart/src/generated/google/rpc/error_details.pb.dart';

final debugInfo = DebugInfo()
  ..detail = 'Null pointer in user service' // Additional debugging information provided by the server.
  ..stackEntries.addAll(['line 42', 'line 100']); // The stack trace entries indicating where the error occurred.

// Pack into an Any message
final anyMessage = Any.pack(debugInfo);
```

### Constructing Rich Error Details (BadRequest)
Use the `error_details.pb.dart` models to provide structured error metadata. Note that the `field` property in `BadRequest_FieldViolation` is generated as `field_1` in Dart to avoid naming conflicts.
```dart
import 'package:grpc-dart/src/generated/google/rpc/error_details.pb.dart';

final badRequest = BadRequest()
  ..fieldViolations.add(
    BadRequest_FieldViolation()
      ..field_1 = 'email' // A path leading to a field in the request body.
      ..description = 'Must be a valid email address' // A description of why the request element is bad.
  );
```

### Handling Quota Failures
```dart
import 'package:grpc-dart/src/generated/google/rpc/error_details.pb.dart';

final quotaFailure = QuotaFailure()
  ..violations.add(
    QuotaFailure_Violation()
      ..subject = 'clientip:192.168.1.1' // The subject on which the quota check failed.
      ..description = 'Daily API limit exceeded' // A description of how the quota check failed.
  );
```

## 6. Exhaustive Message Reference

### `google/protobuf/any.pb.dart`
*   **`Any`**: Contains an arbitrary serialized protocol buffer message along with a URL that describes the type.
    *   `typeUrl` (String): A URL/resource name that uniquely identifies the type.
    *   `value` (List<int>): Must be a valid serialized protocol buffer.

### `google/protobuf/duration.pb.dart`
*   **`Duration`**: Represents a signed, fixed-length span of time at nanosecond resolution.
    *   `seconds` (Int64): Signed seconds of the span of time.
    *   `nanos` (int): Signed fractions of a second at nanosecond resolution.

### `google/rpc/status.pb.dart`
*   **`Status`**: Defines a logical error model suitable for REST and RPC APIs.
    *   `code` (int): The status code, which should be an enum value of google.rpc.Code.
    *   `message` (String): A developer-facing error message (English).
    *   `details` (Iterable<Any>): A list of messages that carry the error details.

### `google/rpc/error_details.pb.dart`
*   **`RetryInfo`**: Describes when clients can retry a failed request.
    *   `retryDelay` (Duration): Clients should wait at least this long before retrying.
*   **`DebugInfo`**: Describes additional debugging info.
    *   `stackEntries` (Iterable<String>): The stack trace entries indicating where the error occurred.
    *   `detail` (String): Additional debugging information provided by the server.
*   **`QuotaFailure`**: Describes how a quota check failed.
    *   `violations` (Iterable<QuotaFailure_Violation>): Describes all quota violations.
*   **`QuotaFailure_Violation`**: A single quota violation.
    *   `subject` (String): The subject on which the quota check failed.
    *   `description` (String): A description of how the quota check failed.
*   **`ErrorInfo`**: Describes the cause of the error with structured details.
    *   `reason` (String): The reason of the error. Unique constant within a domain.
    *   `domain` (String): The logical grouping to which the reason belongs.
    *   `metadata` (Map<String, String>): Additional structured details about this error.
*   **`PreconditionFailure`**: Describes what preconditions have failed.
    *   `violations` (Iterable<PreconditionFailure_Violation>): Describes all precondition violations.
*   **`PreconditionFailure_Violation`**: A single precondition failure.
    *   `type` (String): The type of PreconditionFailure (e.g., "TOS").
    *   `subject` (String): The subject, relative to the type, that failed.
    *   `description` (String): A description of how the precondition failed.
*   **`BadRequest`**: Describes syntactic violations in a client request.
    *   `fieldViolations` (Iterable<BadRequest_FieldViolation>): Describes all violations.
*   **`BadRequest_FieldViolation`**: A single bad request field.
    *   `field_1` (String): A path leading to a field in the request body. (*Note: mapped from `field` proto keyword.*)
    *   `description` (String): A description of why the request element is bad.
*   **`RequestInfo`**: Metadata about the request clients can attach when filing bugs.
    *   `requestId` (String): An opaque string identifying the request.
    *   `servingData` (String): Any data used to serve this request (e.g., trace).
*   **`ResourceInfo`**: Describes the resource that is being accessed.
    *   `resourceType` (String): A name for the type of resource being accessed.
    *   `resourceName` (String): The name of the resource being accessed.
    *   `owner` (String): The owner of the resource (optional).
    *   `description` (String): Describes what error is encountered when accessing this resource.
*   **`Help`**: Provides links to documentation or out-of-band actions.
    *   `links` (Iterable<Help_Link>): URL(s) pointing to additional information.
*   **`Help_Link`**: A URL link.
    *   `description` (String): Describes what the link offers.
    *   `url` (String): The URL of the link.
*   **`LocalizedMessage`**: A localized error message safe to return to the user.
    *   `locale` (String): The locale used (e.g., "en-US").
    *   `message` (String): The localized error message.

## 7. Related Modules
*   `package:protobuf/protobuf.dart`: The core Dart protobuf library.
*   `package:fixnum/fixnum.dart`: Required for handling 64-bit integers (`Int64`).
