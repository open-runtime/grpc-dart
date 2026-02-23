# Quickstart

## 1. Overview
The `grpc` module provides the foundational libraries to define and consume gRPC client and server endpoints in Dart. It includes implementations for HTTP/2 channels, gRPC-Web, and Windows Named Pipes. Additionally, it ships with common Protocol Buffers types like `Any`, `Duration`, and the Google RPC error detail messages.

## 2. Import
Use the following imports depending on your use case:

```dart
// Main import for gRPC clients, servers, and channels
import 'package:grpc/grpc.dart';

// Minimal API intended for generated protobuf stubs
import 'package:grpc/service_api.dart';

// Import for Web specific channels
import 'package:grpc/grpc_web.dart';

// Automatic switch between HTTP/2 and Web channels based on the platform
import 'package:grpc/grpc_or_grpcweb.dart';

// Common Google protobuf types (e.g. Duration) and RPC Error Details
import 'package:grpc/protos.dart';
```

## 3. Setup
To get started with gRPC, you'll need to instantiate a server or a client channel.

**Client Channel:**
```dart
import 'package:grpc/grpc.dart';

// HTTP/2 Client Channel
final channel = ClientChannel(
  'localhost',
  port: 50051,
  options: const ChannelOptions(
    credentials: ChannelCredentials.insecure(),
    keepAlive: ClientKeepAliveOptions(
      pingInterval: Duration(seconds: 30),
      timeout: Duration(seconds: 15),
    ),
  ),
);
```

**Server:**
```dart
import 'package:grpc/grpc.dart';

// Server instance
final server = Server.create(
  services: [], // Add your Service implementations here
  interceptors: [],
  keepAliveOptions: ServerKeepAliveOptions(
    maxBadPings: 2,
    minIntervalBetweenPingsWithoutData: Duration(minutes: 5),
  ),
);

// Start serving
await server.serve(port: 50051);
```

## 4. Common Operations

### Protobuf Types and RPC Error Details
The package provides compiled Dart code for common Google Protobuf and RPC types.
This includes EVERY message, enum, and field defined in `any.proto`, `duration.proto`, `status.proto`, and `error_details.proto`.

```dart
import 'package:fixnum/fixnum.dart';
import 'package:grpc/protos.dart';
import 'package:grpc/src/generated/google/protobuf/any.pb.dart';
import 'package:grpc/src/generated/google/rpc/status.pb.dart';

void useProtobufMessages() {
  // --- google/protobuf/duration.proto ---
  // A Duration represents a signed, fixed-length span of time represented
  // as a count of seconds and fractions of seconds at nanosecond resolution.
  final duration = Duration()
    // Signed seconds of the span of time. Must be from -315,576,000,000
    // to +315,576,000,000 inclusive.
    ..seconds = Int64(60)
    // Signed fractions of a second at nanosecond resolution of the span
    // of time. Durations less than one second are represented with a 0
    // `seconds` field and a positive or negative `nanos` field.
    ..nanos = 0;

  // --- google/protobuf/any.proto ---
  // `Any` contains an arbitrary serialized protocol buffer message along with a
  // URL that describes the type of the serialized message.
  final any = Any()
    // A URL/resource name that uniquely identifies the type of the serialized
    // protocol buffer message.
    ..typeUrl = 'type.googleapis.com/google.protobuf.Duration'
    // Must be a valid serialized protocol buffer of the above specified type.
    ..value = duration.writeToBuffer();

  // --- google/rpc/status.proto ---
  // The `Status` type defines a logical error model that is suitable for
  // different programming environments.
  final status = Status()
    // The status code, which should be an enum value of google.rpc.Code.
    ..code = StatusCode.notFound
    // A developer-facing error message, which should be in English.
    ..message = 'Not found'
    // A list of messages that carry the error details.
    ..details.add(any);

  // --- google/rpc/error_details.proto ---
  
  // 1. RetryInfo
  // Describes when the clients can retry a failed request.
  final retryInfo = RetryInfo()
    // Clients should wait at least this long between retrying the same request.
    ..retryDelay = duration;

  // 2. DebugInfo
  // Describes additional debugging info.
  final debugInfo = DebugInfo()
    // The stack trace entries indicating where the error occurred.
    ..stackEntries.addAll(['line 1', 'line 2'])
    // Additional debugging information provided by the server.
    ..detail = 'Debugging detail';

  // 3. QuotaFailure & QuotaFailure_Violation
  // Describes how a quota check failed.
  final quotaFailureViolation = QuotaFailure_Violation()
    // The subject on which the quota check failed.
    ..subject = 'clientip:127.0.0.1'
    // A description of how the quota check failed.
    ..description = 'Daily Limit exceeded';
    
  final quotaFailure = QuotaFailure()
    // Describes all quota violations.
    ..violations.add(quotaFailureViolation);

  // 4. ErrorInfo
  // Describes the cause of the error with structured details.
  final errorInfo = ErrorInfo()
    // The reason of the error. This is a constant value that identifies the
    // proximate cause of the error.
    ..reason = 'API_DISABLED'
    // The logical grouping to which the "reason" belongs.
    ..domain = 'googleapis.com'
    // Additional structured details about this error.
    ..metadata['service'] = 'pubsub.googleapis.com';

  // 5. PreconditionFailure & PreconditionFailure_Violation
  // Describes what preconditions have failed.
  final preconditionFailureViolation = PreconditionFailure_Violation()
    // The type of PreconditionFailure.
    ..type = 'TOS'
    // The subject, relative to the type, that failed.
    ..subject = 'google.com/cloud'
    // A description of how the precondition failed.
    ..description = 'Terms of service not accepted';
    
  final preconditionFailure = PreconditionFailure()
    // Describes all precondition violations.
    ..violations.add(preconditionFailureViolation);

  // 6. BadRequest & BadRequest_FieldViolation
  // Describes violations in a client request.
  // Note: The protobuf field 'field' is renamed to 'field_1' in Dart 
  // to avoid collision with language keywords or base classes.
  final fieldViolation = BadRequest_FieldViolation()
    // A path leading to a field in the request body.
    ..field_1 = 'user_id'
    // A description of why the request element is bad.
    ..description = 'Must not be empty';
    
  final badRequest = BadRequest()
    // Describes all violations in a client request.
    ..fieldViolations.add(fieldViolation);

  // 7. RequestInfo
  // Contains metadata about the request that clients can attach when filing a bug
  // or providing other forms of feedback.
  final requestInfo = RequestInfo()
    // An opaque string that should only be interpreted by the service generating it.
    ..requestId = 'req-12345'
    // Any data that was used to serve this request.
    ..servingData = 'debug-data';

  // 8. ResourceInfo
  // Describes the resource that is being accessed.
  final resourceInfo = ResourceInfo()
    // A name for the type of resource being accessed.
    ..resourceType = 'cloud storage bucket'
    // The name of the resource being accessed.
    ..resourceName = 'my-bucket'
    // The owner of the resource (optional).
    ..owner = 'user:admin@example.com'
    // Describes what error is encountered when accessing this resource.
    ..description = 'Bucket not found';

  // 9. Help & Help_Link
  // Provides links to documentation or for performing an out of band action.
  final helpLink = Help_Link()
    // Describes what the link offers.
    ..description = 'Enable the API here'
    // The URL of the link.
    ..url = 'https://console.cloud.google.com';
    
  final help = Help()
    // URL(s) pointing to additional information on handling the current error.
    ..links.add(helpLink);

  // 10. LocalizedMessage
  // Provides a localized error message that is safe to return to the user
  // which can be attached to an RPC error.
  final localizedMessage = LocalizedMessage()
    // The locale used following the specification defined at
    // http://www.rfc-editor.org/rfc/bcp/bcp47.txt.
    ..locale = 'en-US'
    // The localized error message in the above locale.
    ..message = 'An error occurred';
}
```

### Authentication
You can easily set up credentials using `applicationDefaultCredentialsAuthenticator`:
```dart
import 'package:grpc/grpc.dart';

Future<void> setupAuth() async {
  final authenticator = await applicationDefaultCredentialsAuthenticator([
    'https://www.googleapis.com/auth/cloud-platform',
  ]);

  final channel = ClientChannel(
    'my-service.googleapis.com',
    port: 443,
    options: ChannelOptions(
      credentials: ChannelCredentials.secure(),
    ),
  );

  final callOptions = authenticator.toCallOptions;
  // Use callOptions when making client calls
}
```

### Service Interceptors
You can intercept and modify requests on the server side:

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';

FutureOr<GrpcError?> myInterceptor(ServiceCall call, ServiceMethod method) {
  if (call.clientMetadata?['authorization'] == null) {
    return GrpcError.unauthenticated('Missing auth token');
  }
  return null; // Continue with the request
}

final server = Server.create(
  services: [],
  interceptors: [myInterceptor],
);
```

### Named Pipes (Windows)
For local IPC on Windows, you can use named pipes:
```dart
import 'package:grpc/grpc.dart';

// Client
final channel = NamedPipeClientChannel(
  'my-service-12345', 
  options: const NamedPipeChannelOptions(),
);

// Server
final pipeServer = NamedPipeServer.create(services: []);
await pipeServer.serve(pipeName: 'my-service-12345');
```

## 5. Configuration
- **Application Default Credentials:** The `applicationDefaultCredentialsAuthenticator` will automatically check the `GOOGLE_APPLICATION_CREDENTIALS` environment variable for a path to your service account JSON file.
- **Client Channel Options:** Configure connections using `ChannelOptions` to adjust `connectTimeout`, `idleTimeout`, `keepAlive`, and `backoffStrategy`.
- **Server KeepAlive:** Use `ServerKeepAliveOptions` to configure thresholds for `maxBadPings` and `minIntervalBetweenPingsWithoutData`.

## 6. Related Modules
- **`googleapis_auth`**: Used internally for handling Google service account authentication and JWT signatures.
- **`protobuf`**: The base `GeneratedMessage` classes and serializers come from the `protobuf` package.
