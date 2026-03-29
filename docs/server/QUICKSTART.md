# gRPC Server Module - Quickstart

## 1. Overview
The gRPC Server module provides robust, high-performance HTTP/2-based servers for handling Remote Procedure Calls (RPCs) in Dart. It supports traditional TCP/TLS connections via `Server`, as well as optimized local inter-process communication (IPC) via `LocalGrpcServer` and `NamedPipeServer` (for Windows).

## 2. Import
The server components are accessed through the main package export. For `Int64` support (common in protobuf), also import `package:fixnum/fixnum.dart`.

```dart
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart';
```
*(Internally, these components are located under `lib/src/server/`)*

## 3. Message and Field Naming

### Naming Conventions
Protobuf-generated Dart code converts `snake_case` field names to `camelCase` to align with Dart conventions. **Always use camelCase when accessing message fields or constructing responses in your service handlers.**

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

### PascalCase for Messages and Enums
Message and enum names remain in PascalCase in Dart (e.g., `SendMailRequest`, `MailFrom`).

---

## 4. Setup
To instantiate a server, you provide a list of your `Service` implementations.

### Standard TCP Server
Use `Server.create` to create a server and `serve` to start it on a specific address and port.

```dart
final server = Server.create(
  services: [MyGreeterService()],
  keepAliveOptions: const ServerKeepAliveOptions(
    maxBadPings: 2,
    minIntervalBetweenPingsWithoutData: Duration(minutes: 5),
  ),
);

await server.serve(port: 8080);
print('Server listening on port ${server.port}');
```

### Local IPC Server
For secure, fast local communication (Unix Domain Sockets on macOS/Linux, Named Pipes on Windows), use `LocalGrpcServer`.

```dart
final localServer = LocalGrpcServer(
  'my-local-service', // Service name determines the socket/pipe path
  services: [MyGreeterService()],
);

await localServer.serve();
print('Local server listening at ${localServer.address}');
```

---

## 5. Service Implementation

### Implementing Handlers
When implementing your service, override the methods defined in your generated base class. Use the builder pattern (cascades `..`) for constructing response messages.

```dart
class MyMailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // 1. Accessing snake_case fields via camelCase properties
    final batchId = request.batchId;              // string batch_id = 1;
    final sendAt = request.sendAt;                // int64 send_at = 2; (returns Int64)
    
    // 2. Accessing nested messages and repeated fields
    if (request.mailSettings.sandboxMode) {        // MailSettings mail_settings = 3; bool sandbox_mode = 1;
      print('Processing sandbox batch: $batchId');
    }

    if (request.trackingSettings.clickTracking.enableText) { // bool enable_text = 2;
      print('Text-based click tracking enabled');
    }

    // 3. Handling repeated fields and maps
    final replyToCount = request.replyToList.length; // repeated string reply_to_list = 10;
    request.dynamicTemplateData.forEach((key, value) { // map<string, string> dynamic_template_data = 5;
      print('Template Data: $key = $value');
    });

    // 4. Constructing a response with the builder pattern (cascades)
    return SendMailResponse()
      ..messageId = 'msg-${DateTime.now().millisecondsSinceEpoch}' // string message_id = 1;
      ..batchId = batchId
      ..status = SendStatus.SUCCESS; // Enum access
  }
}
```

---

## 6. Common Operations

### Accessing Call Context
The `ServiceCall` object provides metadata about the connection and the client.

```dart
Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
  // Read incoming metadata (headers) from the client
  final authHeader = call.clientMetadata?['authorization'];
  
  // Send custom headers back to the client immediately
  call.sendHeaders();
  
  // Access client information
  final remoteIP = call.remoteAddress?.address;
  final certificate = call.clientCertificate;
  
  // Check for timeout or cancellation
  if (call.isTimedOut || call.isCanceled) {
    throw GrpcError.cancelled('Client cancelled the call');
  }
  
  return HelloReply()..message = 'Hello, ${request.name}';
}
```

### Using Interceptors
Interceptors can be used for logging, authentication, or global error handling.

```dart
// Function-based interceptor
FutureOr<GrpcError?> authInterceptor(ServiceCall call, ServiceMethod method) async {
  if (call.clientMetadata?['api-key'] != 'secret-key') {
    return GrpcError.unauthenticated('Invalid API key');
  }
  return null; // Proceed to the handler
}

final server = Server.create(
  services: [MyGreeterService()],
  interceptors: [authInterceptor],
);
```

---

## 7. Configuration Reference

- **`ServerKeepAliveOptions`**: 
  - `maxBadPings`: Maximum number of bad pings tolerated before closing the connection (strikes).
  - `minIntervalBetweenPingsWithoutData`: Minimum time between pings when no data is being sent.
- **`maxInboundMessageSize`**: Caps the maximum size of incoming requests (in bytes) to prevent resource exhaustion.
- **`CodecRegistry`**: Used to support specific compression algorithms (e.g., `GzipCodec`).
- **`ServerCredentials`**: Use `ServerTlsCredentials` for production encryption or `ServerLocalCredentials` to restrict access to the loopback interface.

## 8. Graceful Shutdown
Always shut down your server to drain active RPCs and close sockets properly.

```dart
await server.shutdown();
```

## 9. Related Modules
- **`shared`**: Defines `GrpcError`, status codes, and message framing.
- **`http2`**: The underlying transport layer.
- **`auth`**: Utilities for handling JWTs and Google Auth credentials.
