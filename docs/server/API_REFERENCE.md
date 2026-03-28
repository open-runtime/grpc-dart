# gRPC Server API Reference

This document provides a comprehensive API reference for the **gRPC Server** module. It covers the core classes, server implementations, and configuration options required for building gRPC servers in Dart.

## 0. Naming Conventions (Protobuf to Dart)

When implementing a gRPC service in Dart, all `snake_case` field names from the `.proto` files are automatically converted to `camelCase` in the generated Dart messages.

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

### Server Implementation Example
Always use camelCase when accessing fields on the request object or constructing the response:

```dart
import 'package:grpc/grpc.dart';

class MyMailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // Accessing request fields (snake_case in proto becomes camelCase in Dart)
    final batchId = request.batchId;             // string batch_id = 1;
    final sendAt = request.sendAt;               // int64 send_at = 2;
    
    if (request.mailSettings.sandboxMode) {      // sandbox_mode
      print('Processing sandbox mail for $batchId');
    }

    // Constructing response using the builder pattern
    return SendMailResponse()
      ..messageId = 'msg-123'                    // string message_id = 1;
      ..status = 'ACCEPTED';                     // string status = 2;
  }
}
```

---

## 1. Server Implementations

### Server
The standard gRPC server that listens for incoming RPCs via TCP or TLS.

- **Constructors:**
  - `Server.create({required List<Service> services, ServerKeepAliveOptions keepAliveOptions, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, int? maxInboundMessageSize})`
- **Methods:**
  - `Future<void> serve({dynamic address, int? port, ServerCredentials? security, ServerSettings? http2ServerSettings, int backlog = 0, bool v6Only = false, bool shared = false, bool requestClientCertificate = false, bool requireClientCertificate = false})` - Starts the server.
  - `Future<void> shutdown()` - Gracefully shuts down active connections and sockets.
- **Properties:**
  - `int? port` - The port the server is listening on (available after `serve`).

### LocalGrpcServer
A high-performance, local-only gRPC server that automatically selects the best IPC transport for the platform (Unix domain sockets on macOS/Linux, Named Pipes on Windows).

- **Constructors:**
  - `LocalGrpcServer(String serviceName, {required List<Service> services, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, ServerKeepAliveOptions keepAliveOptions, int? maxInboundMessageSize})`
- **Methods:**
  - `Future<void> serve()` - Starts listening on the appropriate IPC transport.
  - `Future<void> shutdown()` - Gracefully shuts down and cleans up IPC resources (e.g., socket files).
- **Properties:**
  - `String serviceName` - The name used for address resolution.
  - `String? address` - The resolved IPC address (socket path or pipe path).

### NamedPipeServer
A specialized gRPC server for Windows Named Pipes. Typically used via `LocalGrpcServer` on Windows but can be used directly.

- **Constructors:**
  - `NamedPipeServer.create({required List<Service> services, ServerKeepAliveOptions keepAliveOptions, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, int? maxInboundMessageSize})`
- **Methods:**
  - `Future<void> serve({required String pipeName, int maxInstances = 255, ServerSettings? http2ServerSettings})` - Starts the named pipe server.
  - `Future<void> shutdown()` - Gracefully shuts down the server.

---

## 2. Service & Method Definitions

### Service
The base class for all gRPC service implementations. Typically, you extend a generated `ServiceBase` class.

- **Methods:**
  - `$addMethod(ServiceMethod method)` - Registers a method in the service.
  - `$onMetadata(ServiceCall context)` - Override to handle incoming metadata before method execution.
- **Properties:**
  - `String get $name` - The name of the service.

### ServiceCall
The server-side context for an active gRPC call. Provides access to metadata and control over headers/trailers.

- **Properties:**
  - `Map<String, String>? clientMetadata` - Custom metadata sent by the client.
  - `Map<String, String>? headers` - Custom metadata to be sent in the response headers.
  - `Map<String, String>? trailers` - Custom metadata to be sent in the response trailers.
  - `DateTime? deadline` - The deadline for the call.
  - `bool isTimedOut` - Whether the deadline has been exceeded.
  - `bool isCanceled` - Whether the client has canceled the call.
  - `X509Certificate? clientCertificate` - The client certificate (for MTLS).
  - `InternetAddress? remoteAddress` - The IP address of the client.
- **Methods:**
  - `void sendHeaders()` - Manually sends response headers.
  - `void sendTrailers({int? status, String? message})` - Manually sends trailers and ends the call.

### ServiceMethod<Q, R>
Represents a single RPC method within a service.

- **Properties:**
  - `String name` - The name of the method.
  - `bool streamingRequest` - Whether the method accepts a stream of requests.
  - `bool streamingResponse` - Whether the method returns a stream of responses.

---

## 3. Middleware & Interceptors

### Interceptor (Typedef)
A simple functional interceptor called before a service method is invoked.

```dart
typedef Interceptor = FutureOr<GrpcError?> Function(ServiceCall call, ServiceMethod method);
```

### ServerInterceptor
An interceptor class that allows wrapping the entire RPC execution, including the request and response streams.

```dart
class MyServerInterceptor extends ServerInterceptor {
  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    print('Intercepting: ${method.name}');
    return invoker(call, method, requests);
  }
}
```

---

## 4. Security & Configuration

### ServerCredentials
- `ServerTlsCredentials({List<int>? certificate, String? certificatePassword, List<int>? privateKey, String? privateKeyPassword})` - Standard TLS credentials.
- `ServerLocalCredentials()` - Restricts connections to the local loopback address.

### ServerKeepAliveOptions
Configuration for monitoring connection health.

- **Fields:**
  - `int? maxBadPings` - Max number of bad pings allowed before closing the connection.
  - `Duration minIntervalBetweenPingsWithoutData` - Minimum interval expected between pings when no data is sent.

### GrpcErrorHandler (Typedef)
Global error handler for catching unhandled exceptions in service methods.

```dart
typedef GrpcErrorHandler = void Function(GrpcError error, StackTrace? trace);
```

---

## 5. Advanced Lifecycle Management

### ConnectionServer
A base class for servers that manage multiple `ServerTransportConnection`s.

- **Methods:**
  - `Future<void> serveConnection({required ServerTransportConnection connection, X509Certificate? clientCertificate, InternetAddress? remoteAddress})`
  - `Service? lookupService(String service)`

### ServerHandler
Manages the lifecycle of a single gRPC call on the server.

- **Properties:**
  - `Future<void> onCanceled` - Completes when the call is canceled.
  - `Future<void> onTerminated` - Completes when the call terminates.
- **Methods:**
  - `void cancel()` - Forcefully cancels the call.
