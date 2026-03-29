# gRPC Server Examples

This document provides practical, copy-paste-ready examples for configuring and running the gRPC Server in Dart.

> **Note:** These examples assume you are using the Protobuf-generated Dart code. For details on how to generate this code, see the [Quickstart Guide](../QUICKSTART.md).

---

## 1. Basic Usage

### Standard TCP Server (Extending `ServiceBase`)
The most common way to implement a service is by extending the generated base class.

```dart
import 'dart:async';
import 'dart:io';

import 'package:grpc-dart/grpc.dart';
// import 'package:your_app/generated/helloworld.pbgrpc.dart'; 

class GreeterService extends GreeterServiceBase {
  @override
  Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
    return HelloReply()..message = 'Hello, ${request.name}!';
  }
}

Future<void> main() async {
  final server = Server.create(
    services: [GreeterService()],
    keepAliveOptions: const ServerKeepAliveOptions(
      maxBadPings: 2,
      minIntervalBetweenPingsWithoutData: Duration(minutes: 5),
    ),
  );

  await server.serve(address: InternetAddress.anyIPv4, port: 8080);
  print('Server listening on port ${server.port}');
}
```

### Manual Service Implementation
If you are not using generated code (e.g., dynamic proxies or mock services), you can implement `Service` directly.

```dart
import 'package:grpc-dart/grpc.dart';

class ManualGreeterService extends Service {
  @override
  String get $name => 'helloworld.Greeter';

  ManualGreeterService() {
    $addMethod(ServiceMethod<HelloRequest, HelloReply>(
      'SayHello',
      sayHello_Pre,
      false, // streamingRequest
      false, // streamingResponse
      (List<int> value) => HelloRequest.fromBuffer(value),
      (HelloReply value) => value.writeToBuffer(),
    ));
  }

  Future<HelloReply> sayHello_Pre(ServiceCall call, Future<HelloRequest> request) async {
    return sayHello(call, await request);
  }

  Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
    return HelloReply()..message = 'Hello, manual ${request.name}!';
  }
}
```

### Local IPC Server (Unix Domain Sockets & Named Pipes)
`LocalGrpcServer` provides high-performance, local-only communication. It uses Unix domain sockets on macOS/Linux and Named Pipes on Windows.

```dart
import 'package:grpc-dart/grpc.dart';

Future<void> main() async {
  final localServer = LocalGrpcServer(
    'my-local-service', // Service name used for the socket/pipe path
    services: [GreeterService()],
  );

  await localServer.serve();
  print('Local server listening at ${localServer.address}');
}
```

---

## 2. Complex Message Handling

### Dart Naming Conventions (camelCase)
Protobuf `snake_case` fields are converted to `camelCase` in Dart. Always use the builder pattern (cascades `..`) when constructing responses.

```dart
import 'package:grpc-dart/grpc.dart';
import 'package:fixnum/fixnum.dart';
// import 'package:your_app/generated/mail.pbgrpc.dart';

class MailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // 1. Accessing snake_case fields via camelCase properties
    final batchId = request.batchId;              // batch_id
    final sendAt = request.sendAt;                // send_at
    
    // 2. Nested message access
    if (request.mailSettings.sandboxMode) {        // mail_settings, sandbox_mode
      print('Sandbox mode enabled for: $batchId');
    }

    if (request.trackingSettings.clickTracking.enable) { // click_tracking
      print('Click tracking tag: ${request.trackingSettings.openTracking.substitutionTag}');
    }

    // 3. Exhaustive builder pattern example (demonstrating camelCase conversion)
    final complexRequest = SendMailRequest()
      ..batchId = 'batch-123'                      // batch_id
      ..sendAt = Int64(1679745600)                // send_at
      ..mailSettings = (MailSettings()             // mail_settings
        ..sandboxMode = true                       // sandbox_mode
        ..enableText = true)                       // enable_text
      ..trackingSettings = (TrackingSettings()     // tracking_settings
        ..clickTracking = (ClickTracking()         // click_tracking
          ..enable = true
          ..enableText = false)
        ..openTracking = (OpenTracking()           // open_tracking
          ..enable = true
          ..substitutionTag = '[TRACK]'))          // substitution_tag
      ..dynamicTemplateData['user'] = 'John Doe'   // dynamic_template_data
      ..templateId = 'tmpl-456'                    // template_id
      ..contentId = 'content-789'                  // content_id
      ..customArgs['source'] = 'web'               // custom_args
      ..ipPoolName = 'transactional-pool'          // ip_pool_name
      ..replyTo = 'support@example.com'            // reply_to
      ..replyToList.addAll(['a@ex.com', 'b@ex.com']) // reply_to_list
      ..groupId = 101                              // group_id
      ..groupsToDisplay.addAll([1, 5, 10]);        // groups_to_display

    // 4. Repeated fields and builder pattern
    return SendMailResponse()
      ..status = 'Accepted'
      ..batchId = batchId                          // batch_id
      ..timestamp = Int64(DateTime.now().millisecondsSinceEpoch);
  }
}
```

---

## 3. Using ServiceCall Context

`ServiceCall` provides access to request metadata and allows you to set response headers and trailers.

```dart
class ContextAwareService extends GreeterServiceBase {
  @override
  Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
    // 1. Read custom metadata sent by client
    final authToken = call.clientMetadata?['authorization'];
    
    // 2. Access client connection information
    final remoteAddress = call.remoteAddress?.address;
    final clientCert = call.clientCertificate;
    
    // 3. Check for deadline/timeouts
    if (call.isTimedOut) {
       print('Call timed out before processing finished');
    }
    
    if (call.isCanceled) {
      print('Client canceled the call');
    }

    // 4. Send custom headers (must be done before first message)
    call.headers?['x-processed-by'] = 'node-01';
    
    // 5. Send custom trailers (sent at the end of the call)
    call.trailers?['x-latency-ms'] = '45';

    return HelloReply()..message = 'Hello!';
  }
}
```

---

## 4. Streaming RPCs

### Server-to-Client Streaming
```dart
class StreamingService extends RouteGuideServiceBase {
  @override
  Stream<Feature> listFeatures(ServiceCall call, Rectangle request) async* {
    for (var i = 0; i < 10; i++) {
      yield Feature()
        ..name = 'Feature $i'
        ..location = (Point()..latitude = i * 10 ..longitude = i * 10);
      await Future.delayed(Duration(milliseconds: 100));
    }
  }
}
```

### Bidirectional Streaming
```dart
class BidiService extends RouteGuideServiceBase {
  @override
  Stream<RouteNote> routeChat(ServiceCall call, Stream<RouteNote> request) async* {
    await for (final note in request) {
      print('Received note at ${note.location.latitude}, ${note.location.longitude}');
      // Echo the note back to the client
      yield note;
    }
  }
}
```

---

## 5. Security & TLS

```dart
Future<void> main() async {
  final certificate = File('server.crt').readAsBytesSync();
  final privateKey = File('server.key').readAsBytesSync();

  final credentials = ServerTlsCredentials(
    certificate: certificate,
    privateKey: privateKey,
    // Optional: certificatePassword: '...', privateKeyPassword: '...'
  );

  final server = Server.create(services: [GreeterService()]);
  await server.serve(port: 443, security: credentials);
}
```

---

## 6. Error Handling

Throw `GrpcError` to return specific status codes and messages to the client.

```dart
@override
Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
  if (request.name.isEmpty) {
    throw GrpcError.invalidArgument('Name cannot be empty');
  }

  try {
    return await doWork(request);
  } catch (e) {
    // Wrap unexpected exceptions
    throw GrpcError.internal('Internal failure: $e');
  }
}
```

---

## 7. Interceptors

Interceptors are useful for cross-cutting concerns like logging, authentication, and tracing.

```dart
// 1. Function-based interceptor (Auth check)
FutureOr<GrpcError?> authInterceptor(ServiceCall call, ServiceMethod method) {
  if (call.clientMetadata?['token'] != 'secret') {
    return GrpcError.unauthenticated('Invalid token');
  }
  return null;
}

// 2. Class-based interceptor (Logging)
class LoggingInterceptor extends ServerInterceptor {
  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    print('Invoking RPC: ${method.name}');
    return invoker(call, method, requests);
  }
}

Future<void> main() async {
  final server = Server.create(
    services: [GreeterService()],
    interceptors: [authInterceptor],
    serverInterceptors: [LoggingInterceptor()],
  );
  await server.serve(port: 8080);
}
```
