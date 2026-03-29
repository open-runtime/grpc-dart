# gRPC Server API Reference

This document provides a comprehensive API reference for the **gRPC Server** module. It covers the core classes, service definitions, interceptors, and configuration options required for building gRPC servers in Dart.

## 0. Naming Conventions (Protobuf to Dart)

When implementing gRPC services in Dart, it is important to remember that Protobuf-generated code converts `snake_case` field names from `.proto` files into `camelCase` for the Dart API.

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

### Service Implementation Example
When accessing request fields in your service implementation, always use the `camelCase` version. Use the builder pattern (cascades) to construct response messages.

```dart
import 'package:grpc/grpc.dart';

class MailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // Correct: use camelCase for Protobuf fields
    final batchId = request.batchId; 
    final sendAt = request.sendAt;
    
    // Proto: mail_settings.sandbox_mode -> Dart: mailSettings.sandboxMode
    if (request.mailSettings.sandboxMode) {
      print('Processing sandbox mail for batch $batchId');
    }

    // Use builder pattern for response
    return SendMailResponse()..status = 'Success';
  }
}
```

---

## 1. Core Server Classes

### `Server`
The primary class used to create and manage a gRPC server. It listens for incoming RPCs and dispatches them to the appropriate `Service` handler.

- **Constructors:**
  - `Server.create({required List<Service> services, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, ServerKeepAliveOptions keepAliveOptions, int? maxInboundMessageSize})` - Recommended factory to create a server.
- **Methods:**
  - `Future<void> serve({dynamic address, int? port, ServerCredentials? security, ServerSettings? http2ServerSettings, int backlog = 0, bool v6Only = false, bool shared = false, bool requestClientCertificate = false, bool requireClientCertificate = false})` - Starts the server. `address` defaults to `InternetAddress.anyIPv4`, `port` defaults to 80 (insecure) or 443 (secure).
  - `Future<void> shutdown()` - Gracefully shuts down the server, draining active connections.
  - `Service? lookupService(String service)` - Returns the service implementation for a given name.
- **Properties:**
  - `int? port` - The port the server is listening on, or `null` if not active.

### `ConnectionServer`
A base class for servers that serve via `ServerTransportConnection`s. `Server` and `NamedPipeServer` inherit from this.

- **Methods:**
  - `Future<void> serveConnection({required ServerTransportConnection connection, X509Certificate? clientCertificate, InternetAddress? remoteAddress})` - Serves a single pre-established transport connection.
  - `Future<void> shutdownActiveConnections()` - Cancels all active gRPC handlers and finishes all HTTP/2 connections.

---

## 2. Specialized Servers

### `LocalGrpcServer`
A high-performance, local-only gRPC server that automatically selects the best IPC transport for the platform (Unix domain sockets on macOS/Linux, Named Pipes on Windows).

- **Constructors:**
  - `LocalGrpcServer(String serviceName, {required List<Service> services, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, ServerKeepAliveOptions keepAliveOptions, int? maxInboundMessageSize})`
- **Methods:**
  - `Future<void> serve()` - Starts the local server. Address is resolved from `serviceName`.
  - `Future<void> shutdown()` - Gracefully shuts down the server and cleans up IPC resources (e.g., socket files).
- **Properties:**
  - `String serviceName` - The name used for address resolution.
  - `bool isServing` - Whether the server is active.
  - `String? address` - The resolved IPC path (e.g., `\\.\pipe\my-service` or `/tmp/grpc-local/my-service.sock`).

### `NamedPipeServer`
A Windows-specific server that uses Named Pipes for IPC. Typically used via `LocalGrpcServer`.

- **Constructors:**
  - `NamedPipeServer.create({required List<Service> services, ServerKeepAliveOptions keepAliveOptions, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, int? maxInboundMessageSize})`
- **Methods:**
  - `Future<void> serve({required String pipeName, int maxInstances = PIPE_UNLIMITED_INSTANCES, ServerSettings? http2ServerSettings})` - Starts the server on `\\.\pipe\{pipeName}`.
- **Properties:**
  - `String? pipePath` - The full Windows path for the named pipe.
  - `bool isRunning` - Whether the server is currently active.

---

## 3. Service Definition

### `Service`
The base class for all gRPC service implementations. Generated service stubs (e.g., `MyServiceBase`) inherit from this.

- **Methods:**
  - `$addMethod(ServiceMethod method)` - Adds an RPC method to the service (usually called by generated code).
  - `$onMetadata(ServiceCall context)` - Hook called when client metadata is received. Can be overridden for common header processing.
  - `$lookupMethod(String name)` - Finds a method by its simple name.
- **Properties:**
  - `String $name` - The full name of the service (e.g., `pkg.MailService`).

### `ServiceCall`
The server-side context for an active gRPC call. Provides access to client metadata and control over response headers/trailers.

- **Properties:**
  - `Map<String, String>? clientMetadata` - Headers sent by the client. Includes HTTP/2 pseudo-headers like `:path`.
  - `Map<String, String>? headers` - Custom metadata to be sent in the response headers. Set to `null` once headers are sent.
  - `Map<String, String>? trailers` - Custom metadata to be sent in the response trailers after all response messages.
  - `DateTime? deadline` - The time at which the call should be cancelled.
  - `bool isTimedOut` - Returns `true` if the `deadline` has been exceeded.
  - `bool isCanceled` - Returns `true` if the client has aborted the call.
  - `X509Certificate? clientCertificate` - The client's TLS certificate, if requested and available.
  - `InternetAddress? remoteAddress` - The client's IP address (UDS path or IP).
- **Methods:**
  - `void sendHeaders()` - Manually sends response headers. Done automatically before the first message.
  - `void sendTrailers({int? status, String? message})` - Sends trailers and closes the call with the specified status.

### `ServiceMethod<Q, R>`
Represents a single RPC method within a service.

- **Properties:**
  - `String name` - Method name.
  - `bool streamingRequest` - True if client-streaming.
  - `bool streamingResponse` - True if server-streaming.
  - `Q Function(List<int> request) requestDeserializer` - Function to convert bytes to a request object.
  - `List<int> Function(R response) responseSerializer` - Function to convert a response object to bytes.

---

## 4. Middleware & Interceptors

### `ServerInterceptor`
A class-based interceptor that can wrap the entire RPC invocation, including the request and response streams.

```dart
class AuthInterceptor extends ServerInterceptor {
  @override
  Stream<R> intercept<Q, R>(ServiceCall call, ServiceMethod<Q, R> method, 
      Stream<Q> requests, ServerStreamingInvoker<Q, R> invoker) {
    final token = call.clientMetadata?['authorization'];
    if (token != 'secret-token') {
      throw GrpcError.unauthenticated('Invalid token');
    }
    return invoker(call, method, requests);
  }
}
```

### `Interceptor` (typedef)
A simpler function-based interceptor called before the method handler.

- **Signature:** `typedef Interceptor = FutureOr<GrpcError?> Function(ServiceCall call, ServiceMethod method);`
- **Behavior:** Return `null` to continue, or a `GrpcError` to abort the call.

### `GrpcError`
Used to return specific gRPC status codes to the client.

- **Constructors:**
  - `GrpcError.unauthenticated([String? message])`
  - `GrpcError.permissionDenied([String? message])`
  - `GrpcError.notFound([String? message])`
  - `GrpcError.invalidArgument([String? message])`
  - `GrpcError.internal([String? message])`
  - `GrpcError.unavailable([String? message])`

---

## 5. Security & Keepalive

### `ServerCredentials`
Configures security for the server.
- `ServerCredentials.insecure()` - Plaintext communication (default).
- `ServerTlsCredentials({List<int>? certificate, String? certificatePassword, List<int>? privateKey, String? privateKeyPassword})` - Enables TLS.
- `ServerLocalCredentials()` - Restricts connections to the loopback interface (TCP only).

### `ServerKeepAliveOptions`
Configures how the server handles HTTP/2 keepalive pings from clients.

- **Fields:**
  - `int? maxBadPings` - Number of "bad" pings (too frequent) allowed before closing the connection. Default is 2.
  - `Duration minIntervalBetweenPingsWithoutData` - Minimum allowed time between pings when no data is being sent. Default is 5 minutes.
