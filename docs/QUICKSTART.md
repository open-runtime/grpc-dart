# gRPC Client Quickstart

## 1. Overview
The gRPC Client module provides the foundational classes and transports required to communicate with gRPC and gRPC-Web servers. It includes full support for HTTP/2 based gRPC, gRPC-Web via XHR, and local inter-process communication (IPC) via Unix domain sockets and Windows named pipes. Developers use this module to configure connection channels, apply interceptors, manage connection states, and execute unary or streaming Remote Procedure Calls (RPCs).

## 2. Import
The client classes are exported through the main package entry points.

```dart
// For standard HTTP/2 and IPC gRPC clients:
import 'package:grpc/grpc.dart';

// For Int64 support in protobuf fields:
import 'package:fixnum/fixnum.dart';

// For gRPC-Web clients (browser environments):
import 'package:grpc/grpc_web.dart'; 
```

## 3. Setup
To get started, instantiate a client channel and pass it to your generated service client stub (which extends the base `Client` class). 

```dart
// 1. Configure the credentials (e.g., insecure for local development)
final credentials = ChannelCredentials.insecure();

// 2. Configure channel options
final options = ChannelOptions(
  credentials: credentials,
  idleTimeout: Duration(minutes: 5),
  connectTimeout: Duration(seconds: 5),
);

// 3. Instantiate the standard HTTP/2 client channel
final channel = ClientChannel(
  'localhost',
  port: 50051,
  options: options,
);

// Alternative: gRPC-Web (requires a gRPC-Web proxy like Envoy)
// final webChannel = GrpcWebClientChannel.xhr(Uri.parse('http://localhost:8080'));

// Alternative: Local IPC (Unix domain sockets on macOS/Linux or Named Pipes on Windows)
// final localChannel = LocalGrpcChannel('my-service');
```

## 4. Executing RPCs

Once your channel is set up, you can execute RPCs using your generated client stub. Below are examples using a hypothetical `RouteGuide` and `MailService`.

### Unary RPC
A simple RPC where the client sends a single request and receives a single response.

```dart
// Obtains the feature at a given position.
final stub = RouteGuideClient(channel);
final point = Point()
  ..latitude = 409146138
  ..longitude = -746188606;

try {
  final feature = await stub.getFeature(point);
  print('Found feature "${feature.name}" at ${feature.location}');
} catch (e) {
  print('Error: $e');
}
```

### Server-to-Client Streaming RPC
The client sends a single request and gets a stream to read a sequence of messages back.

```dart
// Obtains the Features available within the given Rectangle.
final rect = Rectangle()
  ..lo = (Point()..latitude = 400000000..longitude = -750000000)
  ..hi = (Point()..latitude = 420000000..longitude = -730000000);

final responseStream = stub.listFeatures(rect);
await for (var feature in responseStream) {
  print('Feature: ${feature.name}');
}
```

### Client-to-Server Streaming RPC
The client writes a sequence of messages and sends them to the server using a provided stream.

```dart
// Accepts a stream of Points on a route being traversed, returning a RouteSummary.
final points = [
  Point()..latitude = 40712776..longitude = -74005974,
  Point()..latitude = 34052235..longitude = -118243683,
];

final summary = await stub.recordRoute(Stream.fromIterable(points));
print('Finished route with ${summary.pointCount} points.');
```

### Bidirectional Streaming RPC
Both sides send a sequence of messages using a read-write stream.

```dart
// Accepts a stream of RouteNotes while receiving other RouteNotes.
final notes = [
  RouteNote()..message = 'First note'..location = points[0],
  RouteNote()..message = 'Second note'..location = points[1],
];

final chatStream = stub.routeChat(Stream.fromIterable(notes));
await for (var note in chatStream) {
  print('Received note: ${note.message} at ${note.location}');
}
```

## 5. Message and Field Naming

### Naming Conventions
Protobuf-generated Dart code converts `snake_case` field names to `camelCase` to align with Dart conventions. **Always use camelCase when accessing message fields in Dart code.**

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

### Complex Message Example
The following example demonstrates constructing a complex `SendMailRequest` message using the builder pattern (cascades) and correct `camelCase` field access.

```dart
final mailStub = MailServiceClient(channel);

final request = SendMailRequest()
  ..batchId = 'batch-123' // string batch_id = 1;
  ..sendAt = Int64(1679700000) // int64 send_at = 2;
  ..mailSettings = (MailSettings()
    ..sandboxMode = true // bool sandbox_mode = 1; (Whether to run in sandbox mode)
    ..enableText = true // bool enable_text = 2; (Whether to enable text format)
  )
  ..trackingSettings = (TrackingSettings()
    ..clickTracking = (ClickTracking() // ClickTracking click_tracking = 1;
      ..enable = true
      ..enableText = true // bool enable_text = 2; (Enable text for click tracking)
    )
    ..openTracking = (OpenTracking() // OpenTracking open_tracking = 2;
      ..enable = true
      ..substitutionTag = '[open]' // string substitution_tag = 2; (The substitution tag)
    )
  )
  ..dynamicTemplateData.addAll({ // map<string, string> dynamic_template_data = 5;
    'user_name': 'Dart Developer',
    'plan': 'Pro',
  })
  ..contentId = 'template-v1' // string content_id = 6;
  ..customArgs.addAll({ // map<string, string> custom_args = 7;
    'internal_id': '88990',
  })
  ..ipPoolName = 'transactional-pool' // string ip_pool_name = 8;
  ..replyTo = 'support@example.com' // string reply_to = 9;
  ..replyToList.addAll(['billing@example.com', 'dev@example.com']) // repeated string reply_to_list = 10;
  ..templateId = 'd-998877' // string template_id = 11;
  ..groupId = 42 // int32 group_id = 12;
  ..groupsToDisplay.addAll([1, 2, 3]) // repeated int32 groups_to_display = 13;
  ..mailFrom = MailFrom.MAIL_FROM_SUPPORT; // MailFrom mail_from = 14; (Enum value)

final response = await mailStub.sendMail(request);
print('Mail sent with ID: ${response.messageId}');
```

## 6. Using Interceptors
You can define a `ClientInterceptor` to inject headers, log requests, or handle errors globally. Interceptors are applied in the order they are provided.

```dart
class AuthInterceptor extends ClientInterceptor {
  final String token;
  AuthInterceptor(this.token);

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    // Add authorization header to the call metadata
    final newOptions = options.mergedWith(
      CallOptions(metadata: {'authorization': 'Bearer $token'}),
    );
    return invoker(method, request, newOptions);
  }
}

final stubWithAuth = MailServiceClient(
  channel,
  interceptors: [AuthInterceptor('SECRET_TOKEN')],
);
```

## 7. Cleaning Up
Channels maintain persistent connections. Always shut them down when they are no longer needed to release OS resources (like sockets or pipe handles).

```dart
// Gracefully shut down the channel, allowing active RPCs to finish
await channel.shutdown();

// Or forcefully terminate the connection immediately (cancels active calls)
// await channel.terminate();
```

## 8. Configuration Reference

### `ChannelOptions`
Used when constructing a `ClientChannel` or `LocalGrpcChannel`.
- **`credentials`**: A `ChannelCredentials` instance (e.g., `secure()` or `insecure()`).
- **`idleTimeout`**: Time before idle connections are proactively closed.
- **`connectTimeout`**: Maximum time allowed to establish a connection.
- **`keepAlive`**: A `ClientKeepAliveOptions` instance to configure pings for health monitoring.
- **`maxInboundMessageSize`**: Limits the maximum allowed size of incoming messages.

### `CallOptions` & `WebCallOptions`
Passed to individual RPCs to configure per-call behavior.
- **`metadata`**: A `Map<String, String>` of custom headers.
- **`timeout`**: Maximum duration the specific call is allowed to take.
- **`compression`**: Specify a codec (e.g., `GzipCodec()`) for request compression.
- **`bypassCorsPreflight`** *(WebCallOptions only)*: Packs headers into a query parameter to avoid CORS preflights.
- **`withCredentials`** *(WebCallOptions only)*: Sends cookies/credentials with the XHR request.
