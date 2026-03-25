# gRPC Server Examples

This document provides practical, copy-paste-ready examples for the **gRPC Server** module. It covers basic instantiation, common workflows, error handling, and advanced features such as interceptors and keepalive configurations.

## 1. Basic Usage

### Standard TCP Server
The standard `Server` listens on TCP ports and is the most common way to serve gRPC clients. This example uses a generated `MailServiceBase` class which handles method dispatching.

```dart
import 'dart:io';
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart';
// import 'src/generated/mail.pbgrpc.dart';

class MailServiceImpl extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // 1. Access snake_case proto fields using camelCase Dart fields:
    final String batchId = request.batchId;           // from batch_id
    final Int64 sendAt = request.sendAt;              // from send_at
    final String templateId = request.templateId;      // from template_id

    // 2. Access nested messages and enums:
    final bool sandbox = request.mailSettings.sandboxMode; // from sandbox_mode
    final MailFrom sender = request.mailFrom;              // from mail_from

    print('Processing batch $batchId for sender $sender (sandbox: $sandbox)');

    // 3. Construct response using the builder pattern (cascade ..):
    return SendMailResponse()
      ..messageId = 'msg_${batchId}'; // from message_id
  }
}

Future<void> main() async {
  // Instantiate the server with your generated services
  final server = Server.create(
    services: [MailServiceImpl()],
    // Optional: add a global error handler for unexpected errors
    errorHandler: (error, stackTrace) {
      print('Global gRPC Server Error: $error');
    },
  );

  // Serve the server on a specified port
  await server.serve(
    address: InternetAddress.anyIPv4,
    port: 50051,
    // Alternatively, secure the connection:
    // security: ServerTlsCredentials(certificate: ..., privateKey: ...)
  );

  print('Server listening on port ${server.port}');
  
  // When your application is stopping:
  // await server.shutdown();
}
```

### Local gRPC Server (IPC)
The `LocalGrpcServer` uses Unix domain sockets on macOS/Linux and Named Pipes on Windows. It is highly optimized for local, on-machine communication.

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  // The service name determines the IPC address.
  // - macOS/Linux: \$XDG_RUNTIME_DIR/grpc-local/mail-service.sock
  // - Windows: \\.\pipe\mail-service
  final localServer = LocalGrpcServer(
    'mail-service',
    services: [MailServiceImpl()],
  );

  await localServer.serve();
  
  print('Local IPC server serving on: ${localServer.address}');

  // Shutdown when done
  // await localServer.shutdown();
}
```

### Windows Named Pipe Server
For specialized Windows local-only IPC using `NamedPipeServer`.

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  // Ensure we only run this on Windows platforms, as it relies on dart:ffi
  final pipeServer = NamedPipeServer.create(
    services: [MailServiceImpl()],
  );

  // Start listening on a Windows named pipe
  await pipeServer.serve(
    pipeName: 'mail-service-12345',
    maxInstances: 255, // Optional bounded concurrency limit
  );

  print('Serving on Named Pipe: ${pipeServer.pipePath}');

  // await pipeServer.shutdown();
}
```

## 2. Common Workflows

### Accessing Call Context (Headers & Trailers)
The `ServiceCall` object provides access to metadata, headers, trailers, and client context.

```dart
class ContextAwareMailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // Read custom metadata sent by the client
    final authHeader = call.clientMetadata?['authorization'];
    print('Client Auth: $authHeader');

    // Add custom headers to the response
    call.headers?['x-server-custom-header'] = 'MailServer-Alpha';
    
    // Optionally send headers early (otherwise sent automatically with the first response message)
    call.sendHeaders();

    // Add trailing metadata sent after all response messages complete
    call.trailers?['x-request-cost'] = '0.05';

    // Retrieve information about the client connection
    print('Client IP: ${call.remoteAddress?.address}');
    
    if (call.deadline != null && call.isTimedOut) {
      print('Warning: call has exceeded its deadline.');
    }

    return SendMailResponse()..messageId = 'processed_${request.batchId}';
  }
}
```

### Advanced Field Access and Builder Pattern
This example demonstrates construction of a complex request and how to access all nested/repeated fields in the service.

```dart
import 'package:grpc/grpc.dart';
import 'package:fixnum/fixnum.dart';

// Illustrative client-side request construction using the builder pattern
SendMailRequest buildComplexRequest() {
  return SendMailRequest()
    ..batchId = 'TXN-2026-987'             // batch_id
    ..sendAt = Int64(1774396800)           // send_at
    ..templateId = 'welcome-template'      // template_id
    ..contentId = 'body-content-v2'        // content_id
    ..ipPoolName = 'dedicated-pool'        // ip_pool_name
    ..groupId = 505                        // group_id
    ..mailSettings = (MailSettings()       // mail_settings
      ..sandboxMode = false                // sandbox_mode
      ..enableText = true)                 // enable_text
    ..trackingSettings = (TrackingSettings() // tracking_settings
      ..clickTracking = (ClickTracking()..enable = true) // click_tracking
      ..openTracking = (OpenTracking()..enable = true..substitutionTag = '[open]')) // open_tracking, substitution_tag
    ..dynamicTemplateData.addAll({         // dynamic_template_data
      'user_name': 'Alice',
      'plan': 'Premium'
    })
    ..customArgs.addAll({                  // custom_args
      'campaign': 'spring_2026',
      'segment': 'beta_users'
    })
    ..replyTo = 'support@example.com'      // reply_to
    ..replyToList.addAll([                 // reply_to_list
      'backup-support@example.com',
      'archive@example.com'
    ])
    ..groupsToDisplay.addAll([10, 20, 30]); // groups_to_display
}

class FullMailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // Accessing every field type (camelCase access is MANDATORY):
    final String bId = request.batchId;
    final Int64 sAt = request.sendAt;
    final String tId = request.templateId;
    final String cId = request.contentId;
    final String ipPool = request.ipPoolName;
    final int gId = request.groupId;
    
    // Nested message fields
    final bool sMode = request.mailSettings.sandboxMode;
    final bool eText = request.mailSettings.enableText;
    final bool cTrack = request.trackingSettings.clickTracking.enable;
    final bool oTrack = request.trackingSettings.openTracking.enable;
    final String sTag = request.trackingSettings.openTracking.substitutionTag;
    
    // Collections (Map and List)
    final Map<String, String> dData = request.dynamicTemplateData;
    final Map<String, String> cArgs = request.customArgs;
    final String rTo = request.replyTo;
    final List<String> rToList = request.replyToList;
    final List<int> gDisplay = request.groupsToDisplay;

    return SendMailResponse()..messageId = 'processed_${bId}';
  }
}
```

## 3. Error Handling

### Returning gRPC Errors
Throw standard `GrpcError` exceptions to report explicit failure states to the client. The handler will automatically capture the error and send the appropriate `grpc-status`.

```dart
class ValidatingMailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    if (request.batchId.isEmpty) {
      // Send an INVALID_ARGUMENT (code 3) status to the client
      throw GrpcError.invalidArgument('batchId must not be empty');
    }

    if (request.mailSettings.sandboxMode && request.replyToList.isNotEmpty) {
      // Throw a FAILED_PRECONDITION (code 9) for invalid state combinations
      throw GrpcError.failedPrecondition('Recipients are not allowed in sandbox mode');
    }

    try {
      // Perform an operation that might fail
      return SendMailResponse()..messageId = 'ok';
    } catch (e) {
      // Catch internal exceptions and return a generic INTERNAL (code 13) error
      throw GrpcError.internal('Internal Server Error: $e');
    }
  }
}
```

## 4. Advanced Usage

### Using Basic Interceptors (Authentication)
A standard `Interceptor` executes before the `ServiceMethod` handler, allowing request validation or rejection based on context headers.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';

// An interceptor that checks for an authentication token
FutureOr<GrpcError?> authInterceptor(ServiceCall call, ServiceMethod method) {
  final authHeader = call.clientMetadata?['authorization'];
  
  if (authHeader == null || !authHeader.startsWith('Bearer ')) {
    return GrpcError.unauthenticated('Missing or invalid token');
  }

  final token = authHeader.substring(7);
  if (token != 'valid-production-token') {
    return GrpcError.permissionDenied('Invalid credentials');
  }

  // Returning null means the interceptor passes and the request handler will be called
  return null;
}

Future<void> main() async {
  final server = Server.create(
    services: [MailServiceImpl()],
    // Interceptors run sequentially before the service method
    interceptors: [authInterceptor],
  );

  await server.serve(port: 50051);
}
```

### Using ServerInterceptors (Streaming interception)
A `ServerInterceptor` provides advanced capabilities, allowing you to manipulate or observe both the request and response streams directly.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';

class LoggingServerInterceptor extends ServerInterceptor {
  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    print('Executing RPC: ${method.name}');
    
    final stopwatch = Stopwatch()..start();
    final responseStream = invoker(call, method, requests);
    
    return responseStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (R data, EventSink<R> sink) {
          sink.add(data);
        },
        handleError: (Object error, StackTrace trace, EventSink<R> sink) {
          print('Error in ${method.name}: $error');
          sink.addError(error, trace);
        },
        handleDone: (EventSink<R> sink) {
          stopwatch.stop();
          print('Completed ${method.name} in ${stopwatch.elapsedMilliseconds}ms');
          sink.close();
        },
      )
    );
  }
}

Future<void> main() async {
  final server = Server.create(
    services: [MailServiceImpl()],
    serverInterceptors: [LoggingServerInterceptor()],
  );

  await server.serve(port: 50051);
}
```

### Using Service-Specific Initialization via `$onMetadata`
For unified handling of metadata across all methods within a single `Service`, override `$onMetadata`. This fires once per call before the method handler is invoked.

```dart
class MetadataAwareMailService extends MailServiceBase {
  // Shared state accessible by the method handlers
  String? _currentUser;

  @override
  void $onMetadata(ServiceCall context) {
    // This executes before any method in this service is invoked.
    final token = context.clientMetadata?['x-user-id'];
    if (token == null) {
      throw GrpcError.unauthenticated('User ID header required');
    }
    _currentUser = 'User_$token';
  }

  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    print('Action by $_currentUser');
    return SendMailResponse()..messageId = 'ok';
  }
}
```