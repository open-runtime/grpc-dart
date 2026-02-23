# gRPC Dart Client Examples

This document provides practical, complete, and copy-paste-ready examples of how to use the gRPC Dart client module. The examples demonstrate basic connection setup, common workflows, error handling, and advanced configurations.

## Setup: Mock Generated Client
To ensure the examples are fully compilable, we define a simple mock client that extends the `Client` base class. In a real-world scenario, this client would be generated automatically from your `.proto` files using the `protoc-gen-dart` plugin.

```dart
import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:grpc/grpc_web.dart';

// Mock request and response types for demonstration.
class HelloRequest {
  String name = '';
  int age = 0;
  List<String> tags = [];
}

class HelloReply {
  String message = '';
}

/// A mock generated client for a hypothetical "Greeter" service.
/// Real clients will have strongly typed requests and responses.
class GreeterClient extends Client {
  static final _$sayHello = ClientMethod<HelloRequest, HelloReply>(
    '/helloworld.Greeter/SayHello',
    (HelloRequest value) => [], // Mock serializer
    (List<int> value) => HelloReply()..message = 'Hello', // Mock deserializer
  );

  GreeterClient(
    ClientChannel channel, {
    CallOptions? options,
    Iterable<ClientInterceptor>? interceptors,
  }) : super(channel, options: options, interceptors: interceptors);

  ResponseFuture<HelloReply> sayHello(HelloRequest request, {CallOptions? options}) {
    return $createUnaryCall(_$sayHello, request, options: options);
  }
}
```

---

## 1. Basic Usage

### Connecting via HTTP/2 (Default)
The most common way to connect to a gRPC server is using a standard `ClientChannel` over HTTP/2.

```dart
Future<void> basicHttp2Usage() async {
  // 1. Instantiate the channel to the remote endpoint.
  // By default, connections use secure TLS (ChannelCredentials.secure()).
  final channel = ClientChannel(
    'api.example.com',
    port: 443,
    options: const ChannelOptions(
      credentials: ChannelCredentials.secure(),
    ),
  );

  // 2. Instantiate the generated client stub using the channel.
  final stub = GreeterClient(channel);
  
  // 3. Make the RPC call.
  final response = await stub.sayHello(HelloRequest()..name = 'Dart Client');
  print('Server response: ${response.message}');

  // 4. Shut down the channel when you are completely finished with it.
  await channel.shutdown();
}
```

### Connecting via gRPC-Web (Browser Support)
When running your Dart application in a web browser, use `GrpcWebClientChannel` to connect using XHR or Fetch, avoiding native socket operations that are unsupported in browsers.

```dart
Future<void> grpcWebUsage() async {
  // Instantiate a gRPC-Web channel pointing to the proxy/server.
  final channel = GrpcWebClientChannel.xhr(
    Uri.parse('https://api.example.com:8080'),
  );

  final stub = GreeterClient(channel);
  
  // The API remains identical to the native client.
  final response = await stub.sayHello(HelloRequest()..name = 'Dart Web Client');
  print('Server response: ${response.message}');

  await channel.shutdown();
}
```

### Connecting via Windows Named Pipes
For local, secure inter-process communication (IPC) on Windows, use `NamedPipeClientChannel`.

```dart
Future<void> namedPipeUsage() async {
  // Use NamedPipeClientChannel for local Windows IPC.
  // The path resolves to '\\.\pipe\my-local-grpc-service'.
  final channel = NamedPipeClientChannel(
    'my-local-grpc-service',
    options: const NamedPipeChannelOptions(),
  );

  final stub = GreeterClient(channel);
  final response = await stub.sayHello(HelloRequest()..name = 'Dart Named Pipe Client');
  print('Server response: ${response.message}');

  await channel.shutdown();
}
```

---

## 2. Common Workflows

### Configuring KeepAlive and Connection Timeouts
Long-running connections often require keep-alive pings to prevent them from being silently dropped by firewalls or proxies.

```dart
Future<void> connectionOptionsUsage() async {
  final channel = ClientChannel(
    'api.example.com',
    port: 443,
    options: ChannelOptions(
      credentials: const ChannelCredentials.secure(),
      // Custom connection backoff delays.
      backoffStrategy: defaultBackoffStrategy,
      // Drop the connection if it's completely idle for 10 minutes.
      idleTimeout: const Duration(minutes: 10),
      // Set KeepAlive to actively send pings to verify connection health.
      keepAlive: const ClientKeepAliveOptions(
        pingInterval: Duration(minutes: 1),
        timeout: Duration(seconds: 20),
        // Keep sending pings even if there are no active RPCs.
        permitWithoutCalls: true,
      ),
    ),
  );

  final stub = GreeterClient(channel);
  await stub.sayHello(HelloRequest()..name = 'Dart KeepAlive Client');
  await channel.shutdown();
}
```

### Using Interceptors for Authentication
Interceptors (`ClientInterceptor`) are powerful middleware for executing logic before requests are sent. A common use case is seamlessly injecting authentication tokens.

```dart
/// An interceptor that adds a Bearer token to every outgoing RPC.
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
    // Clone the existing options and inject the 'authorization' metadata.
    final newOptions = options.mergedWith(
      CallOptions(metadata: {'authorization': 'Bearer $token'}),
    );
    return invoker(method, request, newOptions);
  }

  @override
  ResponseStream<R> interceptStreaming<Q, R>(
    ClientMethod<Q, R> method,
    Stream<Q> requests,
    CallOptions options,
    ClientStreamingInvoker<Q, R> invoker,
  ) {
    final newOptions = options.mergedWith(
      CallOptions(metadata: {'authorization': 'Bearer $token'}),
    );
    return invoker(method, requests, newOptions);
  }
}

Future<void> interceptorUsage() async {
  final channel = ClientChannel('localhost', port: 50051);

  // Wrap the client with the interceptor.
  final stub = GreeterClient(
    channel,
    interceptors: [AuthInterceptor('my-secret-token')],
  );

  // The request will now implicitly carry the auth token.
  await stub.sayHello(HelloRequest()..name = 'Authenticated Client');
  await channel.shutdown();
}
```

### Supplying Per-Call Metadata and Timeouts
You can pass a `CallOptions` object directly to an RPC to override timeouts or provide context-specific metadata.

```dart
Future<void> perCallCallOptionsUsage() async {
  final channel = ClientChannel('localhost', port: 50051);
  final stub = GreeterClient(channel);
  
  final response = await stub.sayHello(
    HelloRequest()..name = 'Dart Contextual Client',
    options: CallOptions(
      // Ensure the request fails if it takes more than 5 seconds.
      timeout: const Duration(seconds: 5),
      // Provide custom metadata headers for just this call.
      metadata: {'x-custom-request-id': 'req-12345'},
    ),
  );

  print('Response: ${response.message}');
  await channel.shutdown();
}
```

---

## 3. Error Handling

### Catching and Responding to gRPC Errors
gRPC uses a specific `GrpcError` exception class that maps to standard HTTP/2 and gRPC status codes.

```dart
Future<void> errorHandlingUsage() async {
  final channel = ClientChannel('localhost', port: 50051);
  final stub = GreeterClient(channel);

  try {
    final response = await stub.sayHello(HelloRequest()..name = 'Dart Faulty Client');
    print('Response: ${response.message}');
  } on GrpcError catch (e) {
    // Handle specific status codes.
    if (e.code == StatusCode.deadlineExceeded) {
      print('The request timed out!');
    } else if (e.code == StatusCode.unauthenticated) {
      print('Authentication failed: ${e.message}');
    } else if (e.code == StatusCode.unavailable) {
      print('The server is currently unavailable. Try again later.');
    } else {
      print('Caught gRPC Error: ${e.codeName} - ${e.message}');
    }
  } catch (e) {
    print('Caught generic error: $e');
  }

  await channel.shutdown();
}
```

### Monitoring Connection State
You can monitor the active state of a channel to build UI indicators (e.g., "Connecting...", "Offline").

```dart
Future<void> connectionStateUsage() async {
  final channel = ClientChannel('localhost', port: 50051);

  // Listen to connection state changes via the provided broadcast stream.
  final subscription = channel.onConnectionStateChanged.listen((state) {
    switch (state) {
      case ConnectionState.connecting:
        print('Connecting to the server...');
        break;
      case ConnectionState.ready:
        print('Connection successfully established!');
        break;
      case ConnectionState.transientFailure:
        print('Connection failed. A reconnect attempt will occur shortly...');
        break;
      case ConnectionState.idle:
        print('Connection is idle and not currently in use.');
        break;
      case ConnectionState.shutdown:
        print('Connection has been safely shut down.');
        break;
    }
  });

  final stub = GreeterClient(channel);
  await stub.sayHello(HelloRequest()..name = 'Dart Connected Client');
  
  // Cleanup subscriptions and channels.
  await subscription.cancel();
  await channel.shutdown();
}
```

---

## 4. Advanced Usage

### Dynamic Metadata Providers
`MetadataProvider` functions in `CallOptions` are evaluated right before an RPC is sent. This is highly useful for dynamically fetching async credentials.

```dart
Future<void> dynamicMetadataUsage() async {
  final channel = ClientChannel('localhost', port: 50051);
  final stub = GreeterClient(channel);
  
  final response = await stub.sayHello(
    HelloRequest()..name = 'Dart Async Auth Client',
    options: CallOptions(
      // Providers are invoked dynamically before the request is sent over the wire.
      providers: [
        (Map<String, String> metadata, String uri) async {
          // Asynchronously fetch a fresh token (e.g., from SecureStorage).
          final freshToken = await Future.delayed(
            const Duration(milliseconds: 100),
            () => 'fresh-token-123',
          );
          metadata['authorization'] = 'Bearer $freshToken';
        }
      ],
    ),
  );

  print('Response: ${response.message}');
  await channel.shutdown();
}
```

### Advanced gRPC-Web Settings (CORS Bypass)
When working with strictly isolated domains, you can instruct the proxy to unpack headers from the query parameters, effectively bypassing strict CORS preflight (`OPTIONS`) requirements.

```dart
Future<void> webCallOptionsUsage() async {
  final channel = GrpcWebClientChannel.xhr(Uri.parse('https://api.example.com'));
  final stub = GreeterClient(channel);

  final response = await stub.sayHello(
    HelloRequest()..name = 'Dart Web CORS Client',
    options: WebCallOptions(
      // Will pack HTTP headers into an '$httpHeaders' URL query parameter.
      // This downgrades a complex CORS request to a simple one.
      bypassCorsPreflight: true,
      
      // Instructs the browser to send cookies and credentials with the XHR.
      withCredentials: true,
      
      timeout: const Duration(seconds: 10),
    ),
  );

  print('Response: ${response.message}');
  await channel.shutdown();
}
```

### Custom Certificate Validation
Sometimes during development or when operating on local enterprise networks, you may need to selectively accept self-signed certificates.

```dart
Future<void> customCertificateUsage() async {
  final channel = ClientChannel(
    'internal.example.com',
    port: 443,
    options: ChannelOptions(
      credentials: ChannelCredentials.secure(
        // Inject custom logic to accept or reject TLS certificates.
        onBadCertificate: (X509Certificate certificate, String host) {
          // WARNING: Doing this in production exposes you to man-in-the-middle attacks!
          if (host == 'internal.example.com' || host == 'localhost') {
             print('Allowing bad certificate for trusted dev host: $host');
             return true; 
          }
          return false;
        },
      ),
    ),
  );

  final stub = GreeterClient(channel);
  await stub.sayHello(HelloRequest()..name = 'Dart Local Dev Client');
  await channel.shutdown();
}
```

### Connecting Through a Proxy
If your application's traffic must be routed through an explicit network proxy server, you can supply proxy credentials via `ChannelOptions`.

```dart
Future<void> proxiedConnectionUsage() async {
  final channel = ClientChannel(
    'api.example.com',
    port: 443,
    options: const ChannelOptions(
      credentials: ChannelCredentials.secure(),
      // Route all gRPC HTTP/2 traffic through a local proxy.
      proxy: Proxy(
        host: '192.168.1.100',
        port: 8080,
        username: 'proxy_user',
        password: 'proxy_password',
      ),
    ),
  );

  final stub = GreeterClient(channel);
  await stub.sayHello(HelloRequest()..name = 'Dart Proxied Client');
  await channel.shutdown();
}
```
