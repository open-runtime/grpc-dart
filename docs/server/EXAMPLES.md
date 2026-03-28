# gRPC Server Examples

This document provides practical, copy-paste-ready examples for using the gRPC Server module in Dart. It covers basic usage, common workflows, error handling, and advanced configurations.

## 1. Basic Usage

### Protobuf Naming Conventions (CRITICAL)

When implementing services, **always use `camelCase` for field access**. While the `.proto` files use `snake_case`, the `protoc` plugin for Dart converts these to `camelCase` to follow Dart language conventions. Message and Enum names remain `PascalCase`.

| Proto Field Name | Dart Property Name |
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

### Implementing a Service

To create a gRPC server, you first need to implement the service defined in your protobuf file. Extend the generated service base class (e.g., `GreeterServiceBase`).

```dart
import 'package:grpc-dart/grpc.dart';
// Assuming you have generated files from helloworld.proto
import 'src/generated/helloworld.pbgrpc.dart';

class GreeterService extends GreeterServiceBase {
  @override
  Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
    // Access camelCase fields generated from the proto file
    // HelloRequest has a field 'name' (string name = 1;)
    return HelloReply()..message = 'Hello, ${request.name}!';
  }
}
```

### Starting a Standard TCP Server

Use the `Server.create` method to instantiate a server and `serve` to start listening.

```dart
import 'package:grpc-dart/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

Future<void> main() async {
  // 1. Instantiate the server with your services
  final server = Server.create(
    services: [GreeterService()],
  );

  // 2. Start serving on a specific port
  // Passing 0 lets the OS select an available port
  await server.serve(port: 50051);
  print('Server listening on port ${server.port}...');
  
  // 3. (Optional) Shutdown gracefully when needed
  // await server.shutdown();
}
```

### Using Local IPC (Unix Domain Sockets / Named Pipes)

If your client and server run on the same machine, `LocalGrpcServer` automatically selects the best local IPC mechanism (Unix Domain Sockets for macOS/Linux, Named Pipes for Windows).

```dart
import 'package:grpc-dart/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

Future<void> main() async {
  // Instantiate the local server with a specific service name
  // This name determines the socket path or pipe name
  final server = LocalGrpcServer(
    'my-local-service',
    services: [GreeterService()],
  );

  // Starts the local IPC server
  await server.serve();
  
  print('Local IPC server running at: ${server.address}');
  // Connections are local-only and extremely fast.
}
```

### Complex Service Implementation

The following example shows how to implement a more complex service using the builder pattern and correct Dart naming conventions for fields that are `snake_case` in the proto file.

```dart
import 'package:grpc-dart/grpc.dart';
import 'package:fixnum/fixnum.dart';
// Hypothetical generated mail service
import 'src/generated/mail.pbgrpc.dart';

class MailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // 1. Access camelCase fields generated from snake_case proto fields
    final String batchId = request.batchId; // string batch_id = 1;
    final Int64 sendAt = request.sendAt;    // int64 send_at = 2;

    // 2. Access nested fields
    if (request.hasMailSettings()) {
      final sandbox = request.mailSettings.sandboxMode; // bool sandbox_mode = 1;
      print('Sandbox mode: $sandbox');
    }

    // 3. Repeated fields and Maps use standard Dart collection APIs
    for (var recipient in request.replyToList) { // repeated string reply_to_list = 10;
      print('Reply-To: $recipient');
    }

    request.dynamicTemplateData.forEach((key, value) { // map<string, string> dynamic_template_data = 5;
      print('Template Data: $key = $value');
    });

    // 4. Constructing a response using the builder pattern (cascades)
    return SendMailResponse()
      ..messageId = 'msg-${request.batchId}'
      ..status = 'ACCEPTED';
  }
}
```

## 2. Common Workflows

### Handling Metadata and Call Context

The `ServiceCall` object provides access to client metadata, connection details, and allows sending custom headers/trailers.

```dart
import 'package:grpc-dart/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

class MetadataService extends GreeterServiceBase {
  @override
  Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
    // 1. Read client metadata (headers sent by the client)
    final authHeader = call.clientMetadata?['authorization'];

    // 2. Access call context details
    final deadline = call.deadline;      // When the call will time out
    final isCanceled = call.isCanceled;  // Whether the client cancelled
    final remoteAddress = call.remoteAddress; // Client IP address
    
    if (call.clientCertificate != null) {
      print('Client Cert Subject: ${call.clientCertificate!.subject}');
    }

    // 3. Send custom headers back to the client (must be done before first response)
    call.sendHeaders();
    call.headers?['x-custom-server-header'] = 'gRPC-Dart';

    // 4. Send custom trailers (sent after all response messages)
    call.trailers?['x-processing-time'] = '12ms';

    return HelloReply()..message = 'Hello with context!';
  }
  
  @override
  void $onMetadata(ServiceCall call) {
    // Optional: Override this to handle metadata for every RPC in the service
    print('Received metadata: ${call.clientMetadata}');
  }
}
```

### Configuring KeepAlive and Message Limits

You can configure keepalive settings to detect broken connections and prevent DDoS from bad pings.

```dart
import 'package:grpc-dart/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

Future<void> main() async {
  final server = Server.create(
    services: [GreeterService()],
    // Drop connections if a client sends too many bad pings
    keepAliveOptions: const ServerKeepAliveOptions(
      maxBadPings: 3,
      minIntervalBetweenPingsWithoutData: Duration(minutes: 5),
    ),
    // Increase maximum inbound message size (default is 4MB)
    maxInboundMessageSize: 10 * 1024 * 1024, 
  );

  await server.serve(port: 50051);
}
```

## 3. Error Handling

### Throwing gRPC Errors

Return explicit gRPC status codes to clients by throwing a `GrpcError`. You can also attach detailed error information using standard `google.rpc` messages.

```dart
import 'package:grpc-dart/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

class ValidatingService extends GreeterServiceBase {
  @override
  Future<HelloReply> sayHello(ServiceCall call, HelloRequest request) async {
    if (request.name.isEmpty) {
      // Throwing GrpcError sends the correct status code and message to the client
      throw GrpcError.invalidArgument(
        'The name field cannot be empty.',
        [
          // Attaching detailed error info (requires google/rpc/error_details.proto)
          ErrorInfo()
            ..reason = 'FIELD_REQUIRED'
            ..domain = 'example.com'
            ..metadata.addAll({'field': 'name'})
        ],
      );
    }
    
    if (request.name == 'Admin') {
      throw GrpcError.permissionDenied('Admin access is restricted.');
    }

    return HelloReply()..message = 'Hello, ${request.name}!';
  }
}
```

### Global Error Handling

To log or monitor unhandled exceptions that occur during RPC execution, provide a `GrpcErrorHandler` when creating the server.

```dart
import 'package:grpc-dart/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

void myErrorHandler(GrpcError error, StackTrace? trace) {
  print('Global Error Handler caught: ${error.code} - ${error.message}');
  if (trace != null) {
    print('Stacktrace: $trace');
  }
}

Future<void> main() async {
  final server = Server.create(
    services: [GreeterService()],
    errorHandler: myErrorHandler, // Catches errors before sending trailers
  );

  await server.serve(port: 50051);
}
```

## 4. Advanced Usage

### Using Interceptors

Interceptors run before or around the service method invocation. They are ideal for authentication, logging, or monitoring.

#### Function-based Interceptor
Best for simple pre-flight checks like authentication.

```dart
import 'dart:async';
import 'package:grpc-dart/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

// An interceptor that validates a Bearer token
FutureOr<GrpcError?> authInterceptor(ServiceCall call, ServiceMethod method) {
  final metadata = call.clientMetadata;
  final authHeader = metadata?['authorization'];

  if (authHeader == null || !authHeader.startsWith('Bearer ')) {
    return GrpcError.unauthenticated('Missing or invalid authentication token');
  }

  // Token is valid, return null to continue the request
  return null;
}
```

#### Class-based ServerInterceptor
Best for cross-cutting concerns that need to wrap the entire RPC lifecycle or modify the request/response streams.

```dart
import 'dart:async';
import 'package:grpc-dart/grpc.dart';

class LoggingInterceptor extends ServerInterceptor {
  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    print('Starting call: ${method.name}');
    
    // You can transform the request stream or the response stream here
    final responseStream = invoker(call, method, requests);
    
    return responseStream.map((response) {
      print('Sending response for ${method.name}');
      return response;
    });
  }
}

Future<void> main() async {
  final server = Server.create(
    services: [GreeterService()],
    interceptors: [authInterceptor],
    serverInterceptors: [LoggingInterceptor()],
  );

  await server.serve(port: 50051);
}
```

### Serving Over TLS (SecureSockets)

For production traffic over the network, encrypt connections using `ServerTlsCredentials`.

```dart
import 'dart:io';
import 'package:grpc-dart/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

Future<void> main() async {
  // Load certificates (ensure these paths are correct for your environment)
  final certificate = File('server.crt').readAsBytesSync();
  final privateKey = File('server.key').readAsBytesSync();

  // Configure TLS credentials
  final tlsCredentials = ServerTlsCredentials(
    certificate: certificate,
    privateKey: privateKey,
  );

  final server = Server.create(
    services: [GreeterService()],
  );

  // Pass the credentials to serve()
  await server.serve(
    port: 8443,
    security: tlsCredentials,
    // Optional: require clients to present their own certificates
    requestClientCertificate: true,
  );
  
  print('Secure server running on port 8443');
}
```

### Windows-Specific Named Pipes

`NamedPipeServer` provides secure, local-only IPC on Windows. It is the Windows equivalent of Unix domain sockets.

```dart
import 'dart:io';
import 'package:grpc-dart/grpc.dart';
import 'src/generated/helloworld.pbgrpc.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    print('NamedPipeServer is only supported on Windows');
    return;
  }

  final pipeServer = NamedPipeServer.create(
    services: [GreeterService()],
  );

  // Starts serving at \\.\pipe\my-custom-pipe
  await pipeServer.serve(
    pipeName: 'my-custom-pipe',
  );
  
  print('Named Pipe Server running at: ${pipeServer.pipePath}');
}
```