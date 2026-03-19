# gRPC Server Examples

This document provides practical, copy-paste-ready examples for the **gRPC Server** module. It covers basic usage, common workflows, error handling, and advanced configuration patterns.

## 1. Basic Usage

### Implementing a Service

To create a gRPC server, you first need to implement the service generated from your `.proto` file. The server logic lives within a class that extends the generated base service class (which itself extends `Service`).

Below is an implementation of a hypothetical `MailService` that covers a typical `.proto` file with underscores in field names:

```protobuf
syntax = "proto3";
package examples;

enum MailFrom {
  MAIL_FROM_UNSPECIFIED = 0;
  MAIL_FROM_NO_REPLY = 1;
  MAIL_FROM_SUPPORT = 2;
}

message MailSettings {
  // Whether to run in sandbox mode.
  bool sandbox_mode = 1;
  // Whether to enable text format.
  bool enable_text = 2;
}

message ClickTracking {
  // Whether to enable click tracking.
  bool enable = 1;
  // Whether to enable text format for click tracking.
  bool enable_text = 2;
}

message OpenTracking {
  // Whether to enable open tracking.
  bool enable = 1;
  // The substitution tag for tracking.
  string substitution_tag = 2;
}

message TrackingSettings {
  // Click tracking settings.
  ClickTracking click_tracking = 1;
  // Open tracking settings.
  OpenTracking open_tracking = 2;
}

// Request to send an email.
message SendMailRequest {
  // Unique batch identifier.
  string batch_id = 1;
  // Timestamp to send the email at.
  int64 send_at = 2;
  // Global mail settings.
  MailSettings mail_settings = 3;
  // Tracking settings for the email.
  TrackingSettings tracking_settings = 4;
  // Dynamic data for templates.
  map<string, string> dynamic_template_data = 5;
  // Content identifier.
  string content_id = 6;
  // Custom arguments for tracking.
  map<string, string> custom_args = 7;
  // IP pool name to use.
  string ip_pool_name = 8;
  // Reply-to address.
  string reply_to = 9;
  // Multiple reply-to addresses.
  repeated string reply_to_list = 10;
  // ID of the template to use.
  string template_id = 11;
  // Target group ID.
  int32 group_id = 12;
  // List of group IDs to display.
  repeated int32 groups_to_display = 13;
  // Enum representing the mail sender.
  MailFrom mail_from = 14;
}

message SendMailResponse {
  // The identifier of the sent message.
  string message_id = 1;
}

service MailService {
  // Sends a single mail.
  rpc SendMail (SendMailRequest) returns (SendMailResponse);
}
```

When implementing the generated `MailServiceBase`, **always use camelCase** for Dart field access corresponding to underscored proto fields. `Message` and `Enum` names remain `PascalCase`.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
import 'src/generated/mail.pbgrpc.dart'; // Assume this contains generated protobufs
import 'package:fixnum/fixnum.dart';

/// Implementation of the MailService defined in the .proto file.
class MailServiceImpl extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // Access fields using camelCase:
    
    // Unique batch identifier.
    final String batchId = request.batchId;
    
    // Timestamp to send the email at.
    final Int64 sendAt = request.sendAt;
    
    // Global mail settings.
    final MailSettings mailSettings = request.mailSettings;
    
    // Tracking settings for the email.
    final TrackingSettings trackingSettings = request.trackingSettings;
    
    // Content identifier.
    final String contentId = request.contentId;
    
    // IP pool name to use.
    final String ipPoolName = request.ipPoolName;
    
    // Reply-to address.
    final String replyTo = request.replyTo;
    
    // Multiple reply-to addresses.
    final List<String> replyToList = request.replyToList;
    
    // ID of the template to use.
    final String templateId = request.templateId;
    
    // Target group ID.
    final int groupId = request.groupId;
    
    // List of group IDs to display.
    final List<int> groupsToDisplay = request.groupsToDisplay;
    
    // Dynamic data for templates.
    final Map<String, String> dynamicTemplateData = request.dynamicTemplateData;
    
    // Custom arguments for tracking.
    final Map<String, String> customArgs = request.customArgs;

    // Enum representing the mail sender.
    final MailFrom mailFrom = request.mailFrom;

    print('Received request for batch $batchId to be sent at $sendAt');

    // Create a response and set its fields using camelCase:
    // The identifier of the sent message.
    final response = SendMailResponse()
      ..messageId = 'msg_$batchId';

    return response;
  }
}
```

### Constructing Messages with the Builder Pattern

You can use the builder pattern (cascade `..`) to easily construct requests and inner messages, ensuring that optional fields or edge cases are covered cleanly:

```dart
import 'package:fixnum/fixnum.dart';
import 'src/generated/mail.pbgrpc.dart';

// Constructing a fully populated SendMailRequest covering edge cases:
final request = SendMailRequest()
  // Unique batch identifier.
  ..batchId = 'batch_123'
  // Timestamp to send the email at.
  ..sendAt = Int64(1672531200)
  // Global mail settings.
  ..mailSettings = (MailSettings()
    ..sandboxMode = true
    ..enableText = true)
  // Tracking settings for the email.
  ..trackingSettings = (TrackingSettings()
    ..clickTracking = (ClickTracking()
      ..enable = true
      ..enableText = false)
    ..openTracking = (OpenTracking()
      ..enable = true
      ..substitutionTag = '[open]'))
  // Dynamic data for templates.
  ..dynamicTemplateData.addAll({'user': 'Alice', 'role': 'Admin'})
  // Content identifier.
  ..contentId = 'content_456'
  // Custom arguments for tracking.
  ..customArgs.addAll({'source': 'app', 'campaign': 'spring_sale'})
  // IP pool name to use.
  ..ipPoolName = 'transactional'
  // Reply-to address.
  ..replyTo = 'support@example.com'
  // Multiple reply-to addresses.
  ..replyToList.addAll(['sales@example.com', 'help@example.com'])
  // ID of the template to use.
  ..templateId = 'template_789'
  // Target group ID.
  ..groupId = 10
  // List of group IDs to display.
  ..groupsToDisplay.addAll([1, 2, 3])
  // Enum representing the mail sender.
  ..mailFrom = MailFrom.MAIL_FROM_NO_REPLY;
```

### Instantiating and Serving `Server`

The standard `Server` listens over TCP/IP and HTTP/2. It requires a list of initialized services.

```dart
import 'package:grpc/grpc.dart';
import 'src/generated/mail.pbgrpc.dart';

Future<void> main() async {
  // 1. Instantiate the server
  final server = Server.create(
    services: [MailServiceImpl()],
    // Optional configuration:
    maxInboundMessageSize: 4 * 1024 * 1024, // 4MB
  );

  // 2. Start serving
  await server.serve(port: 8080);
  print('Server listening on port ${server.port}...');

  // (Optional) shutdown gracefully
  // await server.shutdown();
}
```

### Instantiating `LocalGrpcServer`

`LocalGrpcServer` provides local-only IPC using the best transport per platform (Unix Domain Sockets on macOS/Linux, Named Pipes on Windows). This avoids opening network ports.

```dart
import 'package:grpc/grpc.dart';
import 'src/generated/mail.pbgrpc.dart';

Future<void> main() async {
  // 1. Instantiate LocalGrpcServer with a service name
  final localServer = LocalGrpcServer(
    'my-local-app',
    services: [MailServiceImpl()],
  );

  // 2. Start serving
  await localServer.serve();
  
  if (localServer.isServing) {
    print('Local server serving at: ${localServer.address}');
  }

  // 3. Clean up on exit
  // await localServer.shutdown();
}
```

### Instantiating `NamedPipeServer` (Windows-only)

If you are developing specifically for Windows and need advanced named pipe IPC behavior, you can use `NamedPipeServer`.

```dart
import 'dart:io';
import 'package:grpc/grpc.dart';
import 'src/generated/mail.pbgrpc.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    print('NamedPipeServer is only supported on Windows.');
    return;
  }

  // 1. Create a named pipe server
  final pipeServer = NamedPipeServer.create(
    services: [MailServiceImpl()],
  );

  // 2. Start serving on a named pipe
  await pipeServer.serve(
    pipeName: 'my-windows-service', // Maps to \\.\pipe\my-windows-service
    maxInstances: 255,              // Optional: Configure max concurrent pipe instances
  );
  
  print('Named Pipe server listening at: ${pipeServer.pipePath}');
}
```

## 2. Common Workflows

### Accessing Metadata (Headers and Trailers)

You can access incoming `clientMetadata` and set response `headers` and `trailers` via the `ServiceCall` object.

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';
import 'src/generated/mail.pbgrpc.dart';

class MetadataServiceImpl extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // 1. Read incoming metadata
    final Map<String, String>? clientMetadata = call.clientMetadata;
    final String? authHeader = clientMetadata?['authorization'];

    // 2. Set outgoing headers before the first response is sent
    call.sendHeaders(); // Manually send default headers early if needed
    
    // 3. Set custom trailers (sent automatically after the response completes)
    call.trailers?['x-custom-trailer'] = 'operation-successful';

    return SendMailResponse()
      ..messageId = 'metadata-msg';
  }
}
```

### Checking Call Deadlines

If a client sets a timeout, `call.deadline` and `call.isTimedOut` will reflect that. You should verify `call.isCanceled` during long-running streaming methods.

```dart
  // Example for a streaming method
  Stream<SendMailResponse> streamMails(ServiceCall call, SendMailRequest request) async* {
    while (!call.isCanceled && !call.isTimedOut) {
      // Check if deadline is approaching
      if (call.deadline != null && DateTime.now().isAfter(call.deadline!)) {
        break; // Stop yielding
      }
      
      yield SendMailResponse()..messageId = 'active-stream';
      await Future.delayed(const Duration(seconds: 1));
    }
  }
```

## 3. Error Handling

### Throwing `GrpcError`

When processing fails, throw a `GrpcError` with the appropriate status code. The client receives this error mapped to standard gRPC status codes.

```dart
class ValidatingServiceImpl extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    if (request.batchId.isEmpty) {
      // Throw GrpcError.invalidArgument
      throw GrpcError.invalidArgument('The batch_id field is required.');
    }

    if (request.mailSettings.sandboxMode == false && request.contentId.isEmpty) {
      // Throw GrpcError.failedPrecondition
      throw GrpcError.failedPrecondition('Content ID must be specified outside of sandbox mode.');
    }

    // Unhandled standard exceptions become GrpcError.internal.
    try {
      // riskyOperation();
    } catch (e) {
      throw GrpcError.internal('Internal failure: $e');
    }

    return SendMailResponse()..messageId = 'valid';
  }
}
```

### Global Error Handling (`GrpcErrorHandler`)

You can provide a `GrpcErrorHandler` when creating your server to centrally log or monitor all uncaught server errors.

```dart
void logError(GrpcError error, StackTrace? trace) {
  print('Global Error Intercepted: ${error.code} - ${error.message}');
  if (trace != null) {
    print('StackTrace: $trace');
  }
}

Future<void> main() async {
  final server = Server.create(
    services: [MailServiceImpl()],
    errorHandler: logError, // Catch all unhandled GrpcErrors here
  );
  await server.serve(port: 8080);
}
```

## 4. Advanced Usage

### Using Interceptors (`Interceptor` and `ServerInterceptor`)

Interceptors allow you to run logic before a `ServiceMethod` is invoked.

*   `Interceptor`: Simple function to inspect headers/metadata and optionally block the call by returning a `GrpcError`.
*   `ServerInterceptor`: Class to completely wrap the method stream, modifying requests or responses.

#### `Interceptor` (Authentication/Authorization)

```dart
import 'dart:async';
import 'package:grpc/grpc.dart';

FutureOr<GrpcError?> authInterceptor(ServiceCall call, ServiceMethod method) {
  final clientMetadata = call.clientMetadata;
  final token = clientMetadata?['authorization'];

  if (token != 'Bearer secret-token') {
    // Return a GrpcError to block the call immediately
    return GrpcError.unauthenticated('Invalid or missing authentication token');
  }

  // Return null to allow the call to proceed
  return null;
}

Future<void> main() async {
  final server = Server.create(
    services: [MailServiceImpl()],
    interceptors: [authInterceptor],
  );
  await server.serve(port: 8080);
}
```

#### `ServerInterceptor` (Logging/Stream Wrapping)

```dart
class LoggingServerInterceptor extends ServerInterceptor {
  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    print('>>> Starting call: ${method.name}');
    
    // You can intercept/modify the requests stream here
    final interceptedRequests = requests.map((req) {
      print('Received request data');
      return req;
    });

    // Invoke the actual handler
    final responseStream = invoker(call, method, interceptedRequests);

    // Intercept/modify the responses stream
    return responseStream.map((res) {
      print('Sending response data');
      return res;
    }).handleError((error) {
      print('<<< Error in call: ${method.name} -> $error');
      throw error; // Re-throw to ensure correct status code
    });
  }
}

Future<void> main() async {
  final server = Server.create(
    services: [MailServiceImpl()],
    serverInterceptors: [LoggingServerInterceptor()],
  );
  await server.serve(port: 8080);
}
```

### Server KeepAlive Configuration

To protect against idle clients or excessive ping attacks, configure `ServerKeepAliveOptions`.

```dart
Future<void> main() async {
  final server = Server.create(
    services: [MailServiceImpl()],
    keepAliveOptions: ServerKeepAliveOptions(
      // Max bad pings before closing connection (DDoS protection)
      maxBadPings: 2,
      // Minimum interval between pings without data
      minIntervalBetweenPingsWithoutData: const Duration(minutes: 5),
    ),
  );
  await server.serve(port: 8080);
}
```

### TLS/SSL Server Credentials

Instead of standard HTTP/2, use `ServerTlsCredentials` to encrypt traffic (highly recommended in production).

```dart
import 'dart:io';
import 'package:grpc/grpc.dart';

Future<void> main() async {
  // Read certificates from disk
  final certificate = File('certs/server.crt').readAsBytesSync();
  final privateKey = File('certs/server.key').readAsBytesSync();

  final credentials = ServerTlsCredentials(
    certificate: certificate,
    privateKey: privateKey,
  );

  final server = Server.create(
    services: [MailServiceImpl()],
  );

  // Bind to 443 with TLS
  await server.serve(
    port: 443,
    security: credentials,
  );
  print('Secure server listening on port 443...');
}
```

### Multiplexing Multiple Services

A single `Server` can host any number of gRPC services simultaneously.

```dart
Future<void> main() async {
  final server = Server.create(
    services: [
      MailServiceImpl(),
      // BillingServiceImpl(),
      // AnalyticsServiceImpl(),
    ],
  );
  await server.serve(port: 8080);
}
```
