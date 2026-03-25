# gRPC Server API Reference

The **gRPC Server** module provides the core implementation for hosting gRPC services in Dart. It supports standard TCP/IP servers (with optional TLS), local IPC (Unix Domain Sockets and Windows Named Pipes), interceptors, and keepalive management.

## 1. Naming Conventions in Generated Code

Protobuf definitions frequently use `snake_case` for field names. When the Dart code is generated, these are automatically converted to `camelCase` to follow Dart's idiomatic style.

| Proto Field (snake_case) | Dart Field (camelCase) |
| :--- | :--- |
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

Always use the **camelCase** variant when accessing or setting fields in your service implementation or when using the builder pattern.

---

## 2. Core Server Classes

### **Server**
The primary class for hosting gRPC services over network sockets.

*   **Constructors:**
    *   `Server.create({required List<Service> services, ServerKeepAliveOptions keepAliveOptions, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, int? maxInboundMessageSize})` - **Preferred** way to create a server.
*   **Properties:**
    *   `int? port` - The port the server is listening on. `null` if the server is not active.
*   **Methods:**
    *   `Future<void> serve({dynamic address, int? port, ServerCredentials? security, ServerSettings? http2ServerSettings, int backlog = 0, bool v6Only = false, bool shared = false, bool requestClientCertificate = false, bool requireClientCertificate = false})` - Starts listening for RPCs.
    *   `Future<void> shutdown()` - Gracefully shuts down the server, draining active connections.

---

### **LocalGrpcServer**
A specialized server for local-only IPC, automatically selecting the best transport per platform (UDS on macOS/Linux, Named Pipes on Windows).

*   **Constructors:**
    *   `LocalGrpcServer(String serviceName, {required List<Service> services, ...})` - Creates a local server with the given service name (used for the socket/pipe path).
*   **Properties:**
    *   `String serviceName` - The name used for address resolution.
    *   `bool isServing` - Whether the server is active.
    *   `String? address` - The resolved IPC path.
*   **Methods:**
    *   `Future<void> serve()` - Starts the local server.
    *   `Future<void> shutdown()` - Gracefully shuts down the local server.

---

### **NamedPipeServer**
A gRPC server specifically for Windows Named Pipes.

*   **Constructors:**
    *   `NamedPipeServer.create({required List<Service> services, ...})`
*   **Properties:**
    *   `String? pipePath` - The full Windows pipe path (`\\.\pipe\...`).
    *   `bool isRunning` - Whether the server is running.
*   **Methods:**
    *   `Future<void> serve({required String pipeName, int maxInstances, ServerSettings? http2ServerSettings})` - Starts the pipe server.

---

## 3. Service Implementation Classes

### **Service** (Abstract)
Base class for all gRPC service implementations. Your generated service stubs extend this class.

*   **Properties:**
    *   `String $name` - The full name of the service.
*   **Methods:**
    *   `void $onMetadata(ServiceCall call)` - Override to handle metadata for all methods in the service.

---

### **ServiceCall**
Contextual information for an active RPC, providing access to metadata and call lifecycle.

*   **Properties:**
    *   `Map<String, String>? clientMetadata` - Incoming headers from the client.
    *   `Map<String, String>? headers` - Headers to be sent to the client (mutable before sending).
    *   `Map<String, String>? trailers` - Trailers to be sent after response messages.
    *   `DateTime? deadline` - The point in time after which the call is considered expired.
    *   `bool isTimedOut` - `true` if the deadline has passed.
    *   `bool isCanceled` - `true` if the client or server cancelled the call.
    *   `X509Certificate? clientCertificate` - The peer's TLS certificate, if available.
    *   `InternetAddress? remoteAddress` - The client's IP address.
*   **Methods:**
    *   `void sendHeaders()` - Manually sends the headers. Done automatically before the first response.
    *   `void sendTrailers({int? status, String? message})` - Sends trailers and closes the call.

---

## 4. Interceptors and Typedefs

### **Interceptor**
A simple function-based interceptor for filtering calls.

*   **Typedef:** `FutureOr<GrpcError?> Function(ServiceCall call, ServiceMethod method)`
*   Return a `GrpcError` to reject the call, or `null` to allow it.

### **ServerInterceptor** (Abstract)
A class-based interceptor that can wrap the entire request/response stream.

*   **Methods:**
    *   `Stream<R> intercept<Q, R>(ServiceCall call, ServiceMethod<Q, R> method, Stream<Q> requests, ServerStreamingInvoker<Q, R> invoker)`

### **Other Typedefs**
*   **GrpcErrorHandler**: `void Function(GrpcError error, StackTrace? trace)` - Used for global error logging.
*   **ServerStreamingInvoker<Q, R>**: `Stream<R> Function(ServiceCall call, ServiceMethod<Q, R> method, Stream<Q> requests)`

---

## 5. Security and KeepAlive

### **ServerCredentials**
Base class for server authentication.
*   `ServerLocalCredentials`: Restricts connections to the loopback address.
*   `ServerTlsCredentials`: Configures TLS using a certificate chain and private key.

### **ServerKeepAliveOptions**
*   `int? maxBadPings`: Maximum strikes before closing a connection.
*   `Duration minIntervalBetweenPingsWithoutData`: Threshold for ping-flood protection.

---

## 6. Usage Examples

### Implementing a Service with camelCase Fields

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
// import 'src/generated/mail.pbgrpc.dart';

class MailServiceImpl extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // 1. Access snake_case proto fields using camelCase Dart fields
    final String batchId = request.batchId;           // from batch_id
    final Int64 sendAt = request.sendAt;              // from send_at
    final bool sandboxMode = request.mailSettings.sandboxMode; // from sandbox_mode

    // 2. Perform business logic...
    print('Sending batch: $batchId');

    // 3. Construct response using builder pattern
    return SendMailResponse()
      ..messageId = 'msg_${batchId}';
  }
}
```

### Constructing Complex Messages

Use the cascade operator (`..`) for clean construction of nested messages.

```dart
final request = SendMailRequest()
  ..batchId = 'TXN-2026'
  ..sendAt = Int64(1774396800)
  ..mailSettings = (MailSettings()
    ..sandboxMode = true
    ..enableText = true)
  ..trackingSettings = (TrackingSettings()
    ..clickTracking = (ClickTracking()..enable = true)
    ..openTracking = (OpenTracking()..substitutionTag = '[open]'))
  ..dynamicTemplateData.addAll({'name': 'Valued Customer'})
  ..replyToList.addAll(['support@example.com', 'billing@example.com']);
```

### Starting a Secure Server

```dart
void main() async {
  final credentials = ServerTlsCredentials(
    certificate: await File('server.crt').readAsBytes(),
    privateKey: await File('server.key').readAsBytes(),
  );

  final server = Server.create(
    services: [MailServiceImpl()],
    interceptors: [authInterceptor],
  );

  await server.serve(port: 443, security: credentials);
}
```
