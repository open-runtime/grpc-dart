# gRPC Server Quickstart

The gRPC Server module provides the core infrastructure to host and serve gRPC services in Dart. It handles HTTP/2 transport protocol framing, request multiplexing, bidirectional streaming, request interception, and keepalive management.

## 1. Import

Everything needed to build a gRPC server is available through the main `package:grpc/grpc.dart` export:

```dart
import 'package:grpc/grpc.dart';
```

## 2. Implementing a Service

To create a gRPC server, you first need to implement the service generated from your `.proto` file. The server logic lives within a class that extends the generated base service class (e.g., `MailServiceBase`).

### Handling Field Names (snake_case to camelCase)

Protobuf-generated Dart code converts `snake_case` field names to `camelCase`. **Always use camelCase** for Dart field access. Message and enum names remain `PascalCase` (e.g., `SendMailRequest`, `MailFrom`).

| Proto Field | Dart Field | Description |
| :--- | :--- | :--- |
| `batch_id` | `batchId` | String identifier |
| `send_at` | `sendAt` | Int64 timestamp |
| `mail_settings` | `mailSettings` | Nested message |
| `tracking_settings` | `trackingSettings` | Tracking configuration |
| `click_tracking` | `clickTracking` | Click tracking toggle |
| `open_tracking` | `openTracking` | Open tracking toggle |
| `sandbox_mode` | `sandboxMode` | Boolean flag |
| `dynamic_template_data` | `dynamicTemplateData` | Map field |
| `content_id` | `contentId` | String content ID |
| `custom_args` | `customArgs` | Map of custom arguments |
| `ip_pool_name` | `ipPoolName` | IP pool identifier |
| `reply_to` | `replyTo` | Single reply address |
| `reply_to_list` | `replyToList` | Repeated reply addresses |
| `template_id` | `templateId` | Template identifier |
| `enable_text` | `enableText` | Boolean flag |
| `substitution_tag` | `substitutionTag` | String tag |
| `group_id` | `groupId` | Int32 group ID |
| `groups_to_display` | `groupsToDisplay` | Repeated group IDs |

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart';
import 'src/generated/mail.pbgrpc.dart'; // Assume generated protos

class MailServiceImpl extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // 1. Access fields using camelCase:
    final String batchId = request.batchId; // batch_id
    final Int64 sendAt = request.sendAt;   // send_at
    final MailSettings mailSettings = request.mailSettings; // mail_settings
    
    // 2. Access nested message and its fields:
    final bool isSandbox = request.mailSettings.sandboxMode; // sandbox_mode
    final bool textEnabled = request.mailSettings.enableText; // enable_text

    // 3. Access enum fields:
    final MailFrom sender = request.mailFrom; // mail_from

    // 4. Access map fields:
    final Map<String, String> dynamicData = request.dynamicTemplateData;

    // 5. Access repeated fields:
    final List<String> recipients = request.replyToList;

    print('Processing batch $batchId to be sent at $sendAt');

    // 6. Construct response using camelCase:
    return SendMailResponse()
      ..messageId = 'msg_$batchId'; // message_id
  }
}
```

## 3. Creating and Starting the Server

Instantiate the `Server` class using `Server.create()`, passing in your service implementations.

```dart
import 'package:grpc/grpc.dart';

final server = Server.create(
  services: [MailServiceImpl()],
  keepAliveOptions: ServerKeepAliveOptions(
    maxBadPings: 2,
    minIntervalBetweenPingsWithoutData: Duration(minutes: 5),
  ),
  maxInboundMessageSize: 4 * 1024 * 1024, // 4MB limit
);

Future<void> main() async {
  // Listen on all interfaces on port 50051
  await server.serve(port: 50051);
  print('Server listening on port ${server.port}');
}
```

## 4. Local IPC Servers

For machine-to-machine communication on the same host, use `LocalGrpcServer`. This avoids opening network ports and uses the best available transport:
- **macOS/Linux**: Unix Domain Sockets
- **Windows**: Named Pipes

```dart
final localServer = LocalGrpcServer(
  'my-app-service', // Service name used for the socket/pipe path
  services: [MailServiceImpl()],
);

await localServer.serve();
print('Local server serving at: ${localServer.address}');
```

## 5. Service Context (`ServiceCall`)

The `ServiceCall` object provides access to client metadata and allows you to set response headers and trailers.

```dart
@override
Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
  // Read incoming metadata
  final token = call.clientMetadata?['authorization'];

  // Check deadline
  if (call.isTimedOut) {
    throw GrpcError.deadlineExceeded('Call timed out');
  }

  // Set response headers (must be done before first message)
  call.headers?['x-server-id'] = 'node-1';
  call.sendHeaders(); // Optional: send early

  // Set response trailers
  call.trailers?['x-request-cost'] = '1.25';

  return SendMailResponse()..messageId = 'done';
}
```

## 6. Interceptors

Interceptors allow you to run middleware before a service method is invoked.

### Simple Interceptor
Used for authentication or logging. Return `null` to allow the call, or a `GrpcError` to reject it.

```dart
FutureOr<GrpcError?> authInterceptor(ServiceCall call, ServiceMethod method) {
  if (call.clientMetadata?['authorization'] != 'secret') {
    return GrpcError.unauthenticated('Invalid token');
  }
  return null;
}

final server = Server.create(
  services: [MailServiceImpl()],
  interceptors: [authInterceptor],
);
```

### Server Interceptor
Used for advanced stream modification or global error wrapping.

```dart
class LoggingInterceptor extends ServerInterceptor {
  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    print('Starting RPC: ${method.name}');
    return invoker(call, method, requests);
  }
}
```

## 7. Security (TLS)

Use `ServerTlsCredentials` to configure encryption for production environments.

```dart
final credentials = ServerTlsCredentials(
  certificate: File('server.crt').readAsBytesSync(),
  privateKey: File('server.key').readAsBytesSync(),
);

await server.serve(port: 443, security: credentials);
```

## 8. Graceful Shutdown

Always shut down the server to ensure in-flight RPCs are drained and IPC resources (like socket files) are cleaned up.

```dart
await server.shutdown();
print('Server stopped.');
```
