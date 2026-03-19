# gRPC Client Examples

This document provides practical, copy-paste-ready examples for using the gRPC Client module in Dart. It covers basic usage, common workflows, error handling, and advanced patterns.

## 1. Basic Usage

### Instantiating a Client Channel and Stub

To make RPC calls, you first need a `ClientChannel` and a generated client stub. By default, `ClientChannel` uses HTTP/2.

```dart
import "package:grpc/grpc.dart";
import "src/generated/helloworld.pbgrpc.dart";

Future<void> main() async {
  // Create an insecure HTTP/2 channel to localhost:50051
  final channel = ClientChannel(
    "localhost",
    port: 50051,
    options: const ChannelOptions(
      credentials: ChannelCredentials.insecure(),
    ),
  );

  // Instantiate the generated client stub using the channel
  final stub = GreeterClient(channel);

  try {
    // Create a request message
    final request = HelloRequest()..name = "Dart Developer";

    // Call a unary RPC
    final response = await stub.sayHello(request);
    print("Greeter client received: ${response.message}");
  } finally {
    // Shutdown the channel when finished
    await channel.shutdown();
  }
}
```


### Making Unary Calls

A unary RPC sends a single request and receives a single response.

```dart
import "package:grpc/grpc.dart";
import "src/generated/route_guide.pbgrpc.dart";

Future<void> runGetFeature(RouteGuideClient stub) async {
  final point = Point()
    ..latitude = 409146138
    ..longitude = -746188906;

  try {
    final feature = await stub.getFeature(point);
    if (feature.name.isNotEmpty) {
      print("Found feature called \"${feature.name}\" at ${feature.location.latitude}, ${feature.location.longitude}");
    } else {
      print("Found no feature at ${point.latitude}, ${point.longitude}");
    }
  } catch (e) {
    print("Error getting feature: $e");
  }
}
```

### Making Client Streaming Calls

In client streaming, the client writes a sequence of messages and sends them to the server. Once the client has finished writing the messages, it waits for the server to read them all and return its response.

```dart
import "package:grpc/grpc.dart";
import "src/generated/route_guide.pbgrpc.dart";

Future<void> runRecordRoute(RouteGuideClient stub) async {
  Stream<Point> generateRoute() async* {
    yield Point()..latitude = 407838351..longitude = -746143763;
    await Future.delayed(const Duration(milliseconds: 500));
    yield Point()..latitude = 408122808..longitude = -743999179;
    await Future.delayed(const Duration(milliseconds: 500));
    yield Point()..latitude = 413628156..longitude = -749015468;
  }

  try {
    final summary = await stub.recordRoute(generateRoute());
    print("Route Summary:");
    print("  Points: ${summary.pointCount}"); // point_count -> pointCount
    print("  Features: ${summary.featureCount}"); // feature_count -> featureCount
    print("  Distance: ${summary.distance}");
    print("  Elapsed time: ${summary.elapsedTime} seconds"); // elapsed_time -> elapsedTime
  } catch (e) {
    print("Error recording route: $e");
  }
}
```

### Making Bidirectional Streaming Calls

In bidirectional streaming, both sides send a sequence of messages using a read-write stream. The two streams operate independently, so clients and servers can read and write in whatever order they like.

```dart
import "package:grpc/grpc.dart";
import "src/generated/route_guide.pbgrpc.dart";

Future<void> runRouteChat(RouteGuideClient stub) async {
  Stream<RouteNote> generateNotes() async* {
    final notes = [
      RouteNote()..location = (Point()..latitude = 0..longitude = 0)..message = "First message",
      RouteNote()..location = (Point()..latitude = 0..longitude = 1)..message = "Second message",
      RouteNote()..location = (Point()..latitude = 1..longitude = 0)..message = "Third message",
    ];
    for (var note in notes) {
      print("Sending message \"${note.message}\" at ${note.location.latitude}, ${note.location.longitude}");
      yield note;
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  try {
    final responseStream = stub.routeChat(generateNotes());
    await for (final note in responseStream) {
      print("Got message \"${note.message}\" at ${note.location.latitude}, ${note.location.longitude}");
    }
  } catch (e) {
    print("Error in route chat: $e");
  }
}
```

### Making Server Streaming Calls

gRPC supports server streaming, client streaming, and bidirectional streaming.

```dart
import "package:grpc/grpc.dart";
import "src/generated/route_guide.pbgrpc.dart";

Future<void> runListFeatures(RouteGuideClient stub) async {
  final rect = Rectangle()
    ..lo = (Point()..latitude = 400000000..longitude = -750000000)
    ..hi = (Point()..latitude = 420000000..longitude = -730000000);

  // Server Streaming RPC
  final ResponseStream<Feature> stream = stub.listFeatures(rect);

  try {
    await for (final feature in stream) {
      if (feature.name.isNotEmpty) {
        print("Found feature called \"${feature.name}\" at ${feature.location.latitude}, ${feature.location.longitude}");
      }
    }
  } catch (e) {
    print("Error receiving stream: $e");
  }
}
```

## 2. Common Workflows

### Configuring CallOptions (Metadata and Timeouts)

You can pass `CallOptions` to any RPC method to set custom metadata (headers), compression, or a timeout for the call.

```dart
import "package:grpc/grpc.dart";
import "src/generated/helloworld.pbgrpc.dart";

Future<void> callWithCallOptions(GreeterClient stub) async {
  final options = CallOptions(
    metadata: {
      "authorization": "Bearer my-auth-token",
      "custom-header": "value123",
    },
    timeout: const Duration(seconds: 5), // Set a 5-second deadline
    providers: [
      // Dynamic metadata provider
      (metadata, uri) {
        metadata["x-request-id"] = "req-${DateTime.now().millisecondsSinceEpoch}";
      }
    ],
  );

  final request = HelloRequest()..name = "Alice";
  
  // Pass the options to the generated method
  final response = await stub.sayHello(request, options: options);
  print(response.message);
}
```

### Accessing Response Headers and Trailers

gRPC responses contain both the primary message and metadata (headers and trailers). You can access these via `ResponseFuture` or `ResponseStream`.

```dart
import "package:grpc/grpc.dart";
import "src/generated/helloworld.pbgrpc.dart";

Future<void> readHeadersAndTrailers(GreeterClient stub) async {
  final request = HelloRequest()..name = "Bob";
  
  // Store the ResponseFuture instead of immediately awaiting the value
  final ResponseFuture<HelloReply> responseFuture = stub.sayHello(request);

  // Read headers (completes before the response value)
  final headers = await responseFuture.headers;
  print("Response Headers: $headers");

  // Await the actual response value
  final response = await responseFuture;
  print("Response value: ${response.message}");

  // Read trailers (completes after the response value)
  final trailers = await responseFuture.trailers;
  print("Response Trailers: $trailers");
}
```

### Canceling an Active Call

You can cancel an in-flight RPC by calling `.cancel()` on the `ResponseFuture` or `ResponseStream`.

```dart
import "package:grpc/grpc.dart";
import "src/generated/helloworld.pbgrpc.dart";

Future<void> cancelCall(GreeterClient stub) async {
  final request = HelloRequest()..name = "Charlie";
  final responseFuture = stub.sayHello(request);

  // Cancel the call before it completes
  await responseFuture.cancel();

  try {
    await responseFuture;
  } catch (e) {
    if (e is GrpcError && e.code == StatusCode.cancelled) {
      print("Call was successfully canceled: ${e.message}");
    }
  }
}
```

### Client Interceptors

Interceptors allow you to inspect, modify, or block outgoing requests and incoming responses.

```dart
import "dart:async";
import "package:grpc/grpc.dart";

class LoggingInterceptor extends ClientInterceptor {
  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    print("Sending unary request to ${method.path}");
    final newOptions = options.mergedWith(CallOptions(
      metadata: {"x-intercepted": "true"},
    ));
    
    final responseFuture = invoker(method, request, newOptions);
    
    // Log response completion
    responseFuture.then((_) {
      print("Received response from ${method.path}");
    }).catchError((e) {
      print("Error on ${method.path}: $e");
    });
    
    return responseFuture;
  }

  @override
  ResponseStream<R> interceptStreaming<Q, R>(
    ClientMethod<Q, R> method,
    Stream<Q> requests,
    CallOptions options,
    ClientStreamingInvoker<Q, R> invoker,
  ) {
    print("Starting streaming request to ${method.path}");
    return invoker(method, requests, options);
  }
}

// Usage:
// final stub = GreeterClient(channel, interceptors: [LoggingInterceptor()]);
```

## 3. Error Handling

### Catching and Processing GrpcError

gRPC errors are thrown as `GrpcError` objects, containing a standard `StatusCode` and an optional message.

```dart
import "package:grpc/grpc.dart";
import "src/generated/helloworld.pbgrpc.dart";

Future<void> handleErrors(GreeterClient stub) async {
  final request = HelloRequest()..name = "Eve";
  
  try {
    final response = await stub.sayHello(request);
    print(response.message);
  } on GrpcError catch (e) {
    // Handle specific gRPC status codes
    switch (e.code) {
      case StatusCode.deadlineExceeded:
        print("The request timed out!");
        break;
      case StatusCode.unauthenticated:
        print("Authentication failed: ${e.message}");
        break;
      case StatusCode.unavailable:
        print("Service unavailable. Is the server running?");
        break;
      default:
        print("gRPC Error: [${e.codeName}] ${e.message}");
    }
    
    // You can also inspect error details passed via trailers if any
    print("Error details: ${e.details}");
  } catch (e) {
    print("Unexpected non-gRPC error: $e");
  }
}
```

## 4. Advanced Usage

### Using gRPC-Web

For web applications, use `GrpcWebClientChannel` which executes requests over XMLHttpRequest (XHR) instead of raw HTTP/2 sockets.

```dart
import "package:grpc/grpc_web.dart";
import "src/generated/helloworld.pbgrpc.dart";

Future<void> useGrpcWeb() async {
  // Create a channel targeting a gRPC-Web proxy (like Envoy)
  final channel = GrpcWebClientChannel.xhr(
    Uri.parse("https://api.example.com"),
  );

  final stub = GreeterClient(channel);
  
  // Optionally use WebCallOptions for CORS preflight optimization
  final options = WebCallOptions(
    bypassCorsPreflight: true,
    withCredentials: true,
  );
  
  final request = HelloRequest()..name = "Web User";
  final response = await stub.sayHello(request, options: options);
  
  print("Web response: ${response.message}");
  await channel.shutdown();
}
```

### Local IPC Channels (macOS / Linux / Windows)

The library provides `LocalGrpcChannel` for efficient local Inter-Process Communication (IPC). It automatically selects Unix Domain Sockets on Linux/macOS and Named Pipes on Windows.

```dart
import "package:grpc/grpc.dart";
import "src/generated/helloworld.pbgrpc.dart";

Future<void> localIpcCommunication() async {
  // Create a local IPC channel using a named service
  // Under the hood, this uses UDS or Named Pipes depending on the OS
  final channel = LocalGrpcChannel(
    "my-local-service", // Service name matching the LocalGrpcServer
    options: const LocalChannelOptions(
      connectTimeout: Duration(seconds: 2),
    ),
  );

  // Address property reveals the resolved socket or pipe path
  print("Connecting via local IPC to: ${channel.address}");

  final stub = GreeterClient(channel);
  final request = HelloRequest()..name = "Local Process";
  
  try {
    final response = await stub.sayHello(request);
    print("Local IPC Response: ${response.message}");
  } finally {
    await channel.shutdown();
  }
}
```

### Advanced Channel Options (KeepAlive, Proxy, Backoff)

You can heavily customize the `ChannelOptions` for production resilience.

```dart
import "package:grpc/grpc.dart";

Future<void> advancedChannelOptions() async {
  final options = ChannelOptions(
    credentials: const ChannelCredentials.secure(),
    connectTimeout: const Duration(seconds: 10),
    idleTimeout: const Duration(minutes: 5),
    connectionTimeout: const Duration(minutes: 50),
    maxInboundMessageSize: 10 * 1024 * 1024, // 10 MB limit
    
    // HTTP Proxy support
    proxy: const Proxy(
      host: "proxy.internal",
      port: 8080,
    ),
    
    // KeepAlive settings to maintain stateful TCP connections
    keepAlive: const ClientKeepAliveOptions(
      pingInterval: Duration(seconds: 30),
      timeout: Duration(seconds: 15),
      permitWithoutCalls: true,
    ),
    
    // Custom backoff strategy for reconnections
    backoffStrategy: (Duration? lastBackoff) {
      if (lastBackoff == null) return const Duration(seconds: 1);
      final next = lastBackoff * 2;
      return next > const Duration(minutes: 1) ? const Duration(minutes: 1) : next;
    },
  );

  final channel = ClientChannel("grpc.example.com", options: options);
  
  // Use the channel...
  await channel.shutdown();
}
```

### Monitoring Connection State

You can listen to `onConnectionStateChanged` to react to connection transitions.

```dart
import "package:grpc/grpc.dart";

void monitorConnection(ClientChannel channel) {
  channel.onConnectionStateChanged.listen((ConnectionState state) {
    switch (state) {
      case ConnectionState.idle:
        print("Channel is idle");
        break;
      case ConnectionState.connecting:
        print("Channel is connecting...");
        break;
      case ConnectionState.ready:
        print("Channel is ready for RPCs");
        break;
      case ConnectionState.transientFailure:
        print("Channel encountered a transient failure (reconnecting)");
        break;
      case ConnectionState.shutdown:
        print("Channel is shutting down");
        break;
    }
  });
}
```
