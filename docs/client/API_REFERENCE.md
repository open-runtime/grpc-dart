# gRPC Client API Reference

This document provides a comprehensive API reference for the **gRPC Client** module. It covers the core classes, transports, and configuration options required for building gRPC and gRPC-Web clients in Dart.

## 0. Naming Conventions (Protobuf to Dart)

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

### Builder Pattern Example
Always use cascades (`..`) and camelCase when constructing messages:

```dart
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart';

final request = SendMailRequest()
  ..batchId = 'batch-99'               // batch_id
  ..sendAt = Int64(1679745600)         // send_at
  ..mailSettings = (MailSettings()      // mail_settings
    ..sandboxMode = true               // sandbox_mode
    ..enableText = true)               // enable_text
  ..trackingSettings = (TrackingSettings()
    ..clickTracking = (ClickTracking()
      ..enable = true
      ..enableText = false)
    ..openTracking = (OpenTracking()
      ..enable = true
      ..substitutionTag = '[TRACK]'))  // substitution_tag
  ..groupId = 101                      // group_id
  ..groupsToDisplay.addAll([1, 5, 10]); // groups_to_display
```

---

## 1. Client Channels

### ClientChannel
The standard channel for HTTP/2 based gRPC communication over the network.

- **Constructors:**
  - `ClientChannel(Object host, {int port = 443, ChannelOptions options = const ChannelOptions(), void Function()? channelShutdownHandler})`
- **Methods:**
  - `Future<void> shutdown()` - Gracefully shuts down the channel.
  - `Future<void> terminate()` - Forcefully terminates the channel.
- **Getters:**
  - `Stream<ConnectionState> onConnectionStateChanged` - Monitor the health of the connection.

### LocalGrpcChannel
A high-performance, local-only gRPC channel that automatically selects the best IPC transport for the platform (Unix domain sockets on macOS/Linux, Named Pipes on Windows).

- **Constructors:**
  - `factory LocalGrpcChannel(String serviceName, {LocalChannelOptions options = const LocalChannelOptions(), void Function()? channelShutdownHandler})`
- **Properties:**
  - `String address` - The resolved IPC address (socket path or pipe path).

### NamedPipeClientChannel
A specialized channel for Windows Named Pipes. Typically used via `LocalGrpcChannel` but can be instantiated directly.

- **Constructors:**
  - `NamedPipeClientChannel(String pipeName, {ChannelOptions options = const ChannelOptions(), void Function()? channelShutdownHandler})`

### ClientTransportConnectorChannel
Allows for custom transport implementations by providing a `ClientTransportConnector`.

- **Constructors:**
  - `ClientTransportConnectorChannel(ClientTransportConnector transportConnector, {ChannelOptions options = const ChannelOptions()})`

---

## 2. Configuration Options

### ChannelOptions
Global configuration for a `ClientChannel`.

- **Fields:**
  - `ChannelCredentials credentials` - Security settings (TLS or insecure).
  - `Duration? idleTimeout` - How long to keep an idle connection open.
  - `Duration connectionTimeout` - Maximum time a single connection is used before refreshing.
  - `Duration? connectTimeout` - Maximum time allowed to establish a connection.
  - `BackoffStrategy backoffStrategy` - Exponential backoff strategy for retries.
  - `String userAgent` - Custom user-agent string.
  - `ClientKeepAliveOptions keepAlive` - Configuration for keepalive pings.
  - `CodecRegistry? codecRegistry` - Supported compression codecs.
  - `int? maxInboundMessageSize` - Limit for incoming message size.

### LocalChannelOptions
Preset options optimized for local IPC (disables TLS and proxies).

- **Fields:**
  - `Duration? connectTimeout`
  - `Duration connectionTimeout`
  - `Duration idleTimeout`
  - `BackoffStrategy backoffStrategy`
  - `ClientKeepAliveOptions keepAlive`
  - `CodecRegistry? codecRegistry`
  - `int? maxInboundMessageSize`

### NamedPipeChannelOptions
Options specific to Windows Named Pipes (extends `ChannelOptions`).

- **Fields:**
  - `Duration? idleTimeout`
  - `BackoffStrategy? backoffStrategy`
  - `Duration? connectTimeout`
  - `Duration? connectionTimeout`
  - `CodecRegistry? codecRegistry`
  - `ClientKeepAliveOptions? keepAlive`
  - `int? maxInboundMessageSize`

### CallOptions & WebCallOptions
Per-RPC configuration.

- **Fields:**
  - `Map<String, String> metadata` - Custom headers (e.g., Auth tokens).
  - `Duration? timeout` - Maximum duration for this specific call.
  - `List<MetadataProvider> providers` - Dynamic metadata providers.
  - `Codec? compression` - Preferred compression for the request.
  - `bool? bypassCorsPreflight` (Web only) - Avoids CORS preflights by packing headers into query parameters.
  - `bool? withCredentials` (Web only) - Sends browser cookies/credentials.

---

## 3. RPC Execution Classes

### Client
The base class for all generated service client stubs.

- **Constructors:**
  - `Client(ClientChannel channel, {CallOptions? options, Iterable<ClientInterceptor>? interceptors})`
- **Methods:**
  - `$createUnaryCall<Q, R>(ClientMethod<Q, R> method, Q request, {CallOptions? options})`
  - `$createStreamingCall<Q, R>(ClientMethod<Q, R> method, Stream<Q> requests, {CallOptions? options})`

### ResponseFuture<R>
Returned by unary RPCs. Implements `Future<R>` and `Response`.

- **Getters:**
  - `Future<Map<String, String>> headers` - Response headers.
  - `Future<Map<String, String>> trailers` - Response trailers.
- **Methods:**
  - `Future<void> cancel()` - Aborts the call.

### ResponseStream<R>
Returned by streaming RPCs. Implements `Stream<R>` and `Response`.

- **Getters:**
  - `Future<Map<String, String>> headers` - Response headers.
  - `Future<Map<String, String>> trailers` - Response trailers.
- **Methods:**
  - `Future<void> cancel()` - Aborts the stream.

---

## 4. Middleware & Monitoring

### ClientInterceptor
Base class for creating middleware that intercepts RPCs.

```dart
class LoggingInterceptor extends ClientInterceptor {
  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    print('Calling: ${method.path}');
    return invoker(method, request, options);
  }
}
```

### ConnectionState
Enum representing the current lifecycle of a channel.
- `idle`: No active calls, connection closed.
- `connecting`: Attempting to establish a connection.
- `ready`: Connection active and ready for RPCs.
- `transientFailure`: A temporary error occurred; the channel will attempt to reconnect.
- `shutdown`: The channel has been permanently closed.

### ClientKeepAliveOptions
Options for connection health monitoring via HTTP/2 PINGS.

- **Fields:**
  - `Duration? pingInterval` - Frequency of pings.
  - `Duration timeout` - Time to wait for a ping response before failing.
  - `bool permitWithoutCalls` - Whether to send pings even when no RPCs are active.

---

## 5. Security & Credentials

### ChannelCredentials
- `ChannelCredentials.secure({List<int>? certificates, String? password, String? authority, BadCertificateHandler? onBadCertificate})` - Enables TLS.
- `ChannelCredentials.insecure()` - Disables TLS (cleartext).

### Proxy
Configuration for connecting via an HTTP proxy.
- `Proxy({required String host, required int port, String? username, String? password})`
