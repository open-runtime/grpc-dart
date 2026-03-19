# gRPC Client Quickstart

## 1. Overview
The **gRPC Client** module provides the core transport mechanisms and foundational classes required to communicate with gRPC services from Dart applications. It includes robust support for HTTP/2 network connections (`ClientChannel`), gRPC-Web via XHR for browser environments (`GrpcWebClientChannel`), and highly efficient local IPC mechanisms via Unix Domain Sockets and Windows Named Pipes (`LocalGrpcChannel`). It also exposes extensible utilities for managing connection lifecycles, constructing RPC channels, modifying call metadata, and intercepting calls via the `ClientInterceptor` interface.

## 2. Import
Depending on your target platform and transport requirements, use the following real import paths:

```dart
// Core HTTP/2 client (Mobile/Desktop/Server) and Local IPC
import 'package:grpc/grpc.dart';

// Browser-based gRPC-Web client (Web only)
import 'package:grpc/grpc_web.dart';

// Platform-agnostic client (selects HTTP/2 or gRPC-Web automatically)
import 'package:grpc/grpc_or_grpcweb.dart';
```

## 3. Setup
To use the client, you must first create a channel which manages the transport connection to the server. You then pass this channel to your generated service stub (e.g., `MyServiceClient`).

### Standard HTTP/2 Channel
```dart
import 'package:grpc/grpc.dart';

final channel = ClientChannel(
  'localhost',
  port: 50051,
  options: const ChannelOptions(
    credentials: ChannelCredentials.insecure(),
  ),
);
```

### Local IPC Channel (Unix Domain Socket / Named Pipe)
```dart
import 'package:grpc/grpc.dart';

final localChannel = LocalGrpcChannel(
  'my-service',
  options: const LocalChannelOptions(),
);
```

### gRPC-Web Channel
```dart
import 'package:grpc/grpc_web.dart';

final webChannel = GrpcWebClientChannel.xhr(
  Uri.parse('http://localhost:8080'),
);
```

### Platform-Agnostic Channel
```dart
import 'package:grpc/grpc_or_grpcweb.dart';

// Automatically uses HTTP/2 on native platforms and XHR on the web.
final platformChannel = GrpcOrGrpcWebClientChannel.grpc(
  'localhost',
  port: 50051,
  options: const ChannelOptions(
    credentials: ChannelCredentials.insecure(),
  ),
);
```

## 4. Common Operations

*(The following examples assume you have generated a `GreeterClient`, `HelloRequest`, and `HelloReply` from a `.proto` file.)*

### Making a Unary RPC Call
```dart
// Instantiate the client stub using your chosen channel
final stub = GreeterClient(channel);
final request = HelloRequest()..name = 'World';

try {
  // Execute a unary call
  final response = await stub.sayHello(request);
  print('Greeting: ${response.message}');
} on GrpcError catch (e) {
  print('Caught gRPC error: ${e.codeName} - ${e.message}');
} catch (e) {
  print('Caught error: $e');
}
```

### Making a Server Streaming RPC Call
```dart
final streamRequest = HelloRequest()..name = 'World';

// Execute a server streaming call
final stream = stub.sayHelloStream(streamRequest);

// Listen to incoming messages asynchronously
await for (var response in stream) {
  print('Received: ${response.message}');
}
```

### Making a Client Streaming RPC Call
```dart
// Create a stream of requests
Stream<HelloRequest> requestStream() async* {
  yield HelloRequest()..name = 'Alice';
  await Future.delayed(const Duration(seconds: 1));
  yield HelloRequest()..name = 'Bob';
}

// Execute a client streaming call
final response = await stub.sayHelloClientStream(requestStream());
print('Greeting: ${response.message}');
```

### Making a Bidirectional Streaming RPC Call
```dart
// Create a stream of requests
Stream<HelloRequest> requestStream() async* {
  yield HelloRequest()..name = 'Alice';
  await Future.delayed(const Duration(seconds: 1));
  yield HelloRequest()..name = 'Bob';
}

// Execute a bidirectional streaming call
final responseStream = stub.sayHelloBidiStream(requestStream());

// Listen to incoming messages asynchronously
await for (var response in responseStream) {
  print('Received: ${response.message}');
}
```

### Accessing Response Headers and Trailers
```dart
final request = HelloRequest()..name = 'World';

// Instead of awaiting the response directly, you can hold the ResponseFuture
final call = stub.sayHello(request);

// Access headers before the response completes
final headers = await call.headers;
print('Headers: $headers');

// Wait for the response
final response = await call;
print('Greeting: ${response.message}');

// Access trailers after the response completes
final trailers = await call.trailers;
print('Trailers: $trailers');
```

### Cancelling a Call
```dart
final request = HelloRequest()..name = 'World';
final call = stub.sayHello(request);

// Cancel the call if needed
await call.cancel();
```

### Using Call Options and Metadata
You can customize the execution of a single call (or a stream) by providing a `CallOptions` object:

```dart
final options = CallOptions(
  metadata: {'authorization': 'Bearer token_123'},
  timeout: const Duration(seconds: 30),
);

final request = HelloRequest()..name = 'Authorized User';
final response = await stub.sayHello(request, options: options);
```

### Intercepting Calls
You can intercept and manipulate requests/responses using the `ClientInterceptor` interface:

```dart
class LoggingInterceptor extends ClientInterceptor {
  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    print('Sending request to ${method.path}');
    return invoker(method, request, options);
  }
}

// Attach the interceptor when creating the Client
final client = Client(
  channel,
  interceptors: [LoggingInterceptor()],
);
// Or pass it to your generated stub constructor directly
final stubWithInterceptor = GreeterClient(
  channel,
  interceptors: [LoggingInterceptor()],
);
```

### Graceful Shutdown
When your application terminates or you are done communicating, shut down the channel to free underlying network resources:

```dart
await channel.shutdown();
// or terminate immediately:
// await channel.terminate();
```

## 5. Configuration

Client behavior is configured primarily through `ChannelOptions` when instantiating `ClientChannel` or `GrpcOrGrpcWebClientChannelInternal`. Key options include:

- **`credentials`**: Determines if the connection is secure via `ChannelCredentials.secure()` or plaintext via `ChannelCredentials.insecure()`.
- **`idleTimeout`**: The duration before an idle connection is dropped (defaults to 5 minutes).
- **`connectionTimeout`**: The max duration a single connection is kept alive for new requests (defaults to 50 minutes to avoid forceful server closures).
- **`connectTimeout`**: The max allowed time to wait for connection establishment.
- **`keepAlive`**: Settings for sending HTTP/2 PING frames to keep the connection alive via `ClientKeepAliveOptions`.
- **`proxy`**: An optional `Proxy` configuration specifying a proxy host, port, and credentials.
- **`backoffStrategy`**: An algorithm function to determine reconnection delay (defaults to an exponential backoff with jitter via `defaultBackoffStrategy`).
- **`maxInboundMessageSize`**: Maximum allowed inbound message size in bytes.

For `LocalGrpcChannel`, configuration is provided via `LocalChannelOptions`:
```dart
final localChannel = LocalGrpcChannel(
  'my-service',
  options: LocalChannelOptions(
    connectTimeout: const Duration(seconds: 5),
    keepAlive: const ClientKeepAliveOptions(
      pingInterval: Duration(minutes: 5),
    ),
  ),
);
```

For `GrpcWebClientChannel`, `maxInboundMessageSize` and `channelShutdownHandler` are provided directly during instantiation:
```dart
final webChannel = GrpcWebClientChannel.xhr(
  Uri.parse('http://localhost:8080'),
  maxInboundMessageSize: 1024 * 1024 * 10, // 10 MB limit
);
```

When building for gRPC-Web with Cross-Origin Resource Sharing (CORS) preflight bypassing, you can use `WebCallOptions`:
```dart
final webOptions = WebCallOptions(
  metadata: {'custom-header': 'value'},
  bypassCorsPreflight: true,
  withCredentials: true,
);
```

## 6. Related Modules
- **`package:grpc/grpc.dart`**: General exports encompassing both client and server APIs, authentication, core gRPC models, and IPC paths.
- **`package:grpc/src/client/interceptor.dart`**: Contains the `ClientInterceptor` base class and typedefs for injecting custom logic into unary and streaming RPC calls.
- **`package:grpc/src/client/transport/transport.dart`**: Interfaces (`GrpcTransportStream`) and typedefs for pluggable custom transport connectivity implementations.
- **`package:grpc/src/client/transport/cors.dart`**: Utilities for manipulating HTTP headers and paths for bypassing CORS preflight requests in the browser.
