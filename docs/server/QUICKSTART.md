# gRPC Server QUICKSTART

## 1. Overview
The gRPC Server module provides robust, high-performance implementations for serving gRPC services in Dart. It supports standard TCP/TLS sockets, cross-platform local IPC (Unix Domain Sockets on macOS/Linux and Named Pipes on Windows), and built-in handling for interceptors, keep-alive policies, TLS credentials, and graceful timeouts/shutdowns.

## 2. Import
The server classes are exported through the main package entry point.

```dart
import 'package:grpc/grpc.dart';

// For Int64 support in protobuf fields:
import 'package:fixnum/fixnum.dart';
```

## 3. Setup
The standard `Server` listens on TCP sockets. Instantiate it using `Server.create()`, passing in your generated service implementations.

```dart
import 'dart:io';
import 'package:grpc/grpc.dart';

// Assuming you have a generated Service implementation (e.g. MyServiceImpl)
final server = Server.create(
  services: [MyServiceImpl()],
  keepAliveOptions: const ServerKeepAliveOptions(
    maxBadPings: 2,
    minIntervalBetweenPingsWithoutData: Duration(minutes: 5),
  ),
);

Future<void> main() async {
  await server.serve(
    port: 50051,
    address: InternetAddress.anyIPv4,
  );
  print('Server listening on port ${server.port}...');
}
```

## 4. Message and Field Naming

### Naming Conventions
Protobuf-generated Dart code converts `snake_case` field names to `camelCase` to align with Dart conventions. **Always use camelCase when accessing message fields in your service implementation.**

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

### Implementing a Service (Example)
The following example demonstrates implementing a `MailService` that processes a complex `SendMailRequest`. Note the use of `camelCase` for all field access and the builder pattern for constructing the response.

```dart
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart';
// Assuming generated files from mail.proto
import 'src/generated/mail.pbgrpc.dart';

class MailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // 1. Access request fields using camelCase
    final String batchId = request.batchId; // from batch_id
    final Int64 sendAt = request.sendAt;    // from send_at
    
    if (request.mailSettings.sandboxMode) { // from mail_settings.sandbox_mode
      print('Processing in sandbox mode for batch $batchId');
    }

    // Access nested fields
    final bool clickTrackingEnabled = request.trackingSettings.clickTracking.enable;
    final String? subTag = request.trackingSettings.openTracking.substitutionTag;

    // Handle repeated fields and maps
    request.replyToList.forEach((email) => print('Reply-to: $email'));
    request.dynamicTemplateData.forEach((key, value) => print('$key: $value'));

    // 2. Build and return the response using camelCase
    return SendMailResponse()
      ..messageId = 'msg-${DateTime.now().millisecondsSinceEpoch}'
      ..batchId = batchId
      ..status = SendStatus.SUCCESS; // Enum access
  }
}
```

## 5. Common Operations

### Cross-Platform Local IPC
For secure, local-only communication, `LocalGrpcServer` automatically selects Unix Domain Sockets (macOS/Linux) or Named Pipes (Windows).

```dart
final localServer = LocalGrpcServer(
  'my-local-service', 
  services: [MailService()],
);

await localServer.serve();
print('Serving locally on: ${localServer.address}');

await localServer.shutdown();
```

### Service Call Context
The `ServiceCall` object provides access to call-specific metadata and lifecycle state.

```dart
@override
Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
  // Check if client has canceled the call
  if (call.isCanceled) {
    throw GrpcError.cancelled('Client canceled the request');
  }

  // Check deadline
  if (call.deadline != null && call.isTimedOut) {
    throw GrpcError.deadlineExceeded('Call timed out');
  }

  // Access metadata (headers) sent by the client
  final auth = call.clientMetadata?['authorization'];

  // Send custom headers back to the client
  call.headers?['x-server-id'] = 'node-01';
  call.sendHeaders(); // Optional: headers are sent automatically with first response

  // Set trailers (sent after all responses)
  call.trailers?['x-processing-time'] = '45ms';

  return SendMailResponse()..status = SendStatus.SUCCESS;
}
```

### Request Interceptors
Interceptors can be used for authentication, logging, or rate limiting. They are executed before the service method.

```dart
FutureOr<GrpcError?> authInterceptor(ServiceCall call, ServiceMethod method) {
  final token = call.clientMetadata?['authorization'];
  if (token != 'Bearer my-secret-token') {
    return GrpcError.unauthenticated('Invalid token');
  }
  return null; // Proceed to service method
}

final server = Server.create(
  services: [MailService()],
  interceptors: [authInterceptor],
);
```

### Advanced: Streaming Interceptors
For more control over the request/response streams, implement `ServerInterceptor`.

```dart
class LoggingInterceptor extends ServerInterceptor {
  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    print('Intercepting RPC: ${method.name}');
    return invoker(call, method, requests);
  }
}
```

## 6. Configuration Reference
- **`ServerKeepAliveOptions`**: Controls HTTP/2 keep-alive behavior (e.g., `maxBadPings`, `minIntervalBetweenPingsWithoutData`).
- **`ServerCredentials`**: Define TLS security context using `ServerTlsCredentials` or restrict clients to localhost using `ServerLocalCredentials`.
- **`CodecRegistry`**: Automatically compress/decompress streams (e.g., gzip).
- **`GrpcErrorHandler`**: Intercept global errors and add metadata/logging before failing the stream.
- **`maxInboundMessageSize`**: Limits the size of an incoming payload protecting the server from OOM.

## 7. Related Modules
- **Client**: Module for connecting to gRPC services via TCP, Local IPC, or Web.
- **Shared**: Status definitions (`GrpcError`), Stream utilities, and Codec Registry.
- **HTTP/2 Transport**: Low-level networking transport for HTTP/2 framing.