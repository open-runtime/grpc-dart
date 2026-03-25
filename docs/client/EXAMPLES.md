# gRPC Dart Client Examples

This document provides practical, copy-paste-ready examples for using the **gRPC Client** module in Dart. These examples assume you have generated Dart source files from standard `helloworld.proto` and `route_guide.proto` schemas.

## 1. Basic Usage

### Creating a Channel and Client Stub

This example demonstrates how to instantiate a `ClientChannel`, configure it with `ChannelOptions`, and make a simple Unary RPC call using a generated client stub.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart'; // Assume this contains generated protobufs

Future<void> main() async {
  // 1. Create a channel to the virtual gRPC endpoint.
  final channel = ClientChannel(
    'localhost',
    port: 50051,
    options: const ChannelOptions(
      // Disable TLS for local development
      credentials: ChannelCredentials.insecure(),
      idleTimeout: Duration(minutes: 5),
    ),
  );

  // 2. Instantiate the generated client stub.
  final stub = GreeterClient(channel);

  // 3. Make an RPC call.
  try {
    // Create the request message using the builder pattern (cascades)
    final request = HelloRequest()..name = 'Dart';
    
    // Call the method, which returns a ResponseFuture<HelloReply>
    final response = await stub.sayHello(request);
    
    print('Greeter client received: ${response.message}');
  } on GrpcError catch (e) {
    print('gRPC Error: ${e.codeName} - ${e.message}');
  } catch (e) {
    print('Caught error: $e');
  }

  // 4. Clean up the channel when done.
  await channel.shutdown();
}
```

---

## 2. Common Workflows

### Streaming RPCs

gRPC supports Unary, Server Streaming, Client Streaming, and Bidirectional Streaming. These examples use the `RouteGuide` standard example.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
import 'src/generated/route_guide.pbgrpc.dart'; // Assume this contains generated protobufs

Future<void> main() async {
  final channel = ClientChannel(
    'localhost',
    port: 50051,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  
  final stub = RouteGuideClient(channel);

  await runGetFeature(stub);
  await runListFeatures(stub);
  await runRecordRoute(stub);
  await runRouteChat(stub);

  await channel.shutdown();
}

/// Simple Unary RPC example
Future<void> runGetFeature(RouteGuideClient stub) async {
  final point = Point()
    ..latitude = 409146138
    ..longitude = -746188606;

  try {
    // Obtains the feature at a given position.
    final feature = await stub.getFeature(point);
    if (feature.name.isEmpty) {
      print('No feature found at ${feature.location}');
    } else {
      print('Found feature "${feature.name}" at ${feature.location}');
    }
  } catch (e) {
    print('Error in GetFeature: $e');
  }
}

/// Server-streaming RPC example
Future<void> runListFeatures(RouteGuideClient stub) async {
  final rect = Rectangle()
    ..lo = (Point()..latitude = 400000000..longitude = -750000000)
    ..hi = (Point()..latitude = 420000000..longitude = -730000000);

  // Server streaming RPC returns a ResponseStream
  final responseStream = stub.listFeatures(rect);

  try {
    // Iterate over incoming features using await for
    await for (final feature in responseStream) {
      print('Found feature: ${feature.name} at '
          '${feature.location.latitude}, ${feature.location.longitude}');
    }
  } catch (e) {
    print('Error in ListFeatures: $e');
  }
}

/// Client-streaming RPC example
Future<void> runRecordRoute(RouteGuideClient stub) async {
  // A generator that yields points on a route
  Stream<Point> generateRoute() async* {
    yield Point()..latitude = 4078383..longitude = -7461437;
    await Future.delayed(const Duration(milliseconds: 500));
    yield Point()..latitude = 4081228..longitude = -7439991;
  }

  try {
    // Send the stream to the server and await the single summary response
    final summary = await stub.recordRoute(generateRoute());
    print('Finished route with ${summary.pointCount} points.'); // point_count
    print('Feature count: ${summary.featureCount}');             // feature_count
    print('Total distance: ${summary.distance}');
    print('Elapsed time: ${summary.elapsedTime} seconds');     // elapsed_time
  } catch (e) {
    print('Error in RecordRoute: $e');
  }
}

/// Bidirectional-streaming RPC example
Future<void> runRouteChat(RouteGuideClient stub) async {
  final requests = StreamController<RouteNote>();
  
  // Establish the bidirectional stream
  final responseStream = stub.routeChat(requests.stream);

  // Listen to responses from the server
  final responseSubscription = responseStream.listen(
    (RouteNote note) {
      print('Got message "${note.message}" at '
          '${note.location.latitude}, ${note.location.longitude}');
    },
    onError: (Object e) {
      print('Error in RouteChat: $e');
    },
    onDone: () => print('RouteChat stream closed by server.'),
  );

  // Send requests to the server
  requests.add(RouteNote()
    ..message = 'First message'
    ..location = (Point()..latitude = 0..longitude = 0));
    
  await Future.delayed(const Duration(seconds: 1));
  
  requests.add(RouteNote()
    ..message = 'Second message'
    ..location = (Point()..latitude = 0..longitude = 1));

  // Close the request stream when done; the response stream will eventually finish
  await requests.close();
  await responseSubscription.asFuture();
}
```

---

## 3. Complex Message and Field Naming

### Dart Naming Conventions
Protobuf-generated Dart code automatically converts `snake_case` field names to `camelCase`. **Always use camelCase for property access in Dart.** Message and Enum names remain `PascalCase`.

The following example demonstrates constructing a complex `SendMailRequest` using the builder pattern and correct Dart naming conventions.

```dart
import 'package:fixnum/fixnum.dart';
import 'src/generated/mail.pbgrpc.dart'; // Hypothetical mail service

Future<void> sendTransactionalMail(MailServiceClient stub) async {
  // Construct the request using cascades for nested builders
  final request = SendMailRequest()
    ..batchId = 'TXN-98765'               // string batch_id = 1;
    ..sendAt = Int64(1679700000)         // int64 send_at = 2;
    ..mailSettings = (MailSettings()     // MailSettings mail_settings = 3;
      ..sandboxMode = true               // bool sandbox_mode = 1;
      ..enableText = true                // bool enable_text = 2;
    )
    ..trackingSettings = (TrackingSettings() // TrackingSettings tracking_settings = 4;
      ..clickTracking = (ClickTracking()      // ClickTracking click_tracking = 1;
        ..enable = true
        ..enableText = true             // bool enable_text = 2;
      )
      ..openTracking = (OpenTracking()        // OpenTracking open_tracking = 2;
        ..enable = true
        ..substitutionTag = '[open]'     // string substitution_tag = 2;
      )
    )
    ..dynamicTemplateData.addAll({       // map<string, string> dynamic_template_data = 5;
      'user_name': 'Dart Developer',
      'plan': 'Pro',
    })
    ..contentId = 'template-v1'          // string content_id = 6;
    ..customArgs.addAll({                // map<string, string> custom_args = 7;
      'internal_id': '88990',
    })
    ..ipPoolName = 'transactional-pool'   // string ip_pool_name = 8;
    ..replyTo = 'support@example.com'    // string reply_to = 9;
    ..replyToList.addAll(['billing@example.com', 'dev@example.com']) // repeated string reply_to_list = 10;
    ..templateId = 'd-998877'            // string template_id = 11;
    ..groupId = 42                       // int32 group_id = 12;
    ..groupsToDisplay.addAll([1, 2, 3])  // repeated int32 groups_to_display = 13;
    ..mailFrom = MailFrom.MAIL_FROM_SUPPORT; // MailFrom mail_from = 14; (Enum)

  try {
    final response = await stub.sendMail(request);
    print('Mail sent successfully. Message ID: ${response.messageId}');
  } catch (e) {
    print('Error: $e');
  }
}
```

---

## 4. Error Handling

Properly handle `GrpcError` structures with different `StatusCode` values.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

Future<void> main() async {
  final channel = ClientChannel(
    'localhost',
    port: 50051,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  
  final stub = GreeterClient(channel);
  
  try {
    final response = await stub.sayHello(HelloRequest()..name = 'Dart');
    print(response.message);
  } on GrpcError catch (e) {
    // Handle specific gRPC status codes
    if (e.code == StatusCode.unauthenticated) {
      print('Authentication failed: ${e.message}');
    } else if (e.code == StatusCode.deadlineExceeded) {
      print('Request timed out.');
    } else if (e.code == StatusCode.resourceExhausted) {
      print('Too many requests.');
    } else {
      print('gRPC Error (${e.codeName}): ${e.message}');
    }
    
    // Check if the server sent detailed error trailers
    if (e.trailers != null && e.trailers!.isNotEmpty) {
      print('Error trailers: ${e.trailers}');
    }
  } catch (e, stackTrace) {
    print('Unexpected error: $e\n$stackTrace');
  }

  await channel.shutdown();
}
```

---

## 5. Advanced Usage

### Runtime Configuration & Dynamic Metadata

Use `CallOptions` for timeouts, and `MetadataProvider` functions to dynamically inject metadata (like authorization headers) on each call.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

Future<void> main() async {
  final channel = ClientChannel(
    'localhost',
    port: 50051,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  final stub = GreeterClient(channel);

  // A MetadataProvider is invoked before every RPC to modify the outgoing metadata
  FutureOr<void> fetchAuthToken(Map<String, String> metadata, String uri) async {
    // Fetch a token dynamically (e.g., from an OAuth2 provider)
    final token = await Future.delayed(
      const Duration(milliseconds: 100), 
      () => 'fresh-token',
    );
    metadata['authorization'] = 'Bearer $token';
  }

  // Configure runtime options for the RPC
  final options = CallOptions(
    providers: [fetchAuthToken],
    timeout: const Duration(seconds: 5),
  );

  final response = await stub.sayHello(
    HelloRequest()..name = 'Dart',
    options: options,
  );
  
  print('Response: ${response.message}');
  await channel.shutdown();
}
```

### Client Interceptors

Interceptors can catch and mutate requests or options before they are sent.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

/// A custom interceptor that injects a token into all outgoing requests.
class AuthInterceptor extends ClientInterceptor {
  final String _token;

  AuthInterceptor(this._token);

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    // Merge the provided options with the custom metadata
    final newOptions = options.mergedWith(
      CallOptions(metadata: {'authorization': 'Bearer $_token'})
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
      CallOptions(metadata: {'authorization': 'Bearer $_token'})
    );
    return invoker(method, requests, newOptions);
  }
}

Future<void> main() async {
  final channel = ClientChannel(
    'localhost',
    port: 50051,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  
  // Pass interceptors directly to the generated client constructor.
  // Interceptors are applied in direct order.
  final stub = GreeterClient(
    channel,
    interceptors: [AuthInterceptor('super-secret-token')],
  );
  
  final response = await stub.sayHello(HelloRequest()..name = 'Dart');
  print('Response: ${response.message}');
  
  await channel.shutdown();
}
```

### Connection State Monitoring & Keep-Alive

Monitor connection drops via streams and implement `ClientKeepAliveOptions`.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';

Future<void> main() async {
  // Keep alive pings can be configured via ClientKeepAliveOptions
  final channel = ClientChannel(
    'localhost',
    port: 50051,
    options: const ChannelOptions(
      credentials: ChannelCredentials.insecure(),
      keepAlive: ClientKeepAliveOptions(
        pingInterval: Duration(minutes: 5), // ping_interval
        timeout: Duration(seconds: 20),
        permitWithoutCalls: true,           // permit_without_calls
      ),
    ),
  );

  // Monitor the connection state over time
  final subscription = channel.onConnectionStateChanged.listen((ConnectionState state) {
    switch (state) {
      case ConnectionState.connecting:
        print('Connecting...');
        break;
      case ConnectionState.ready:
        print('Connection established and ready.');
        break;
      case ConnectionState.transientFailure:
        print('Transient failure occurred, reconnecting...');
        break;
      case ConnectionState.idle:
        print('Channel is idle.');
        break;
      case ConnectionState.shutdown:
        print('Channel has been shut down.');
        break;
    }
  });

  await Future.delayed(const Duration(seconds: 1));
  await subscription.cancel();
  await channel.shutdown();
}
```

### Local IPC Channels

Utilize native machine-local transports for lower latency and improved security in local environments.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

Future<void> main() async {
  // Use LocalGrpcChannel for local IPC. 
  // - macOS/Linux: Uses Unix domain sockets
  // - Windows: Uses Named pipes
  final localChannel = LocalGrpcChannel(
    'my-service',
    options: const LocalChannelOptions(
      connectTimeout: Duration(seconds: 5),
    ),
  );

  final localStub = GreeterClient(localChannel);
  
  try {
    final response = await localStub.sayHello(HelloRequest()..name = 'Local IPC');
    print('Local response: ${response.message}');
  } catch (e) {
    print('Error: $e');
  }
  
  // Windows-specific named pipe channel can also be instantiated directly:
  // final pipeChannel = NamedPipeClientChannel('my-service');
  
  await localChannel.shutdown();
}
```

### gRPC Web and CORS

Leverage `GrpcWebClientChannel` with `WebCallOptions` to bypass preflight requests in browser environments.

```dart
import 'dart:async';
import 'package:grpc/grpc_web.dart';
import 'src/generated/helloworld.pbgrpc.dart';

Future<void> main() async {
  // Use GrpcWebClientChannel for XHR-based communication in browsers
  final channel = GrpcWebClientChannel.xhr(
    Uri.parse('https://api.example.com'),
  );
  
  final stub = GreeterClient(channel);
  
  // WebCallOptions helps with CORS issues by shifting headers to query params
  final options = WebCallOptions(
    bypassCorsPreflight: true, // bypass_cors_preflight
    withCredentials: true,    // with_credentials
  );

  try {
    final response = await stub.sayHello(
      HelloRequest()..name = 'Web Client',
      options: options,
    );
    print('Web response: ${response.message}');
  } catch (e) {
    print('Error: $e');
  }
}
```