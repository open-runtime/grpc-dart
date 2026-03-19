# gRPC Server Module - Quickstart

## 1. Overview
The **gRPC Server** module provides a suite of robust, high-performance server implementations for Dart. It supports standard HTTP/2 over TCP/TLS (`Server`), macOS/Linux Unix Domain Sockets (`LocalGrpcServer`), and secure Windows Named Pipes (`NamedPipeServer`). This module gives you the utilities to easily expose generated `Service` classes, manage client connections via `ServiceCall`, and intercept requests using `Interceptor` and `ServerInterceptor`.

## 2. Import

To use the server module, use the following real import paths corresponding to the `lib/src/server/` directory:

```dart
// Standard TCP/TLS Server and Credentials
import 'package:grpc/src/server/server.dart';

// Local IPC Servers
import 'package:grpc/src/server/local_server.dart';
import 'package:grpc/src/server/named_pipe_server.dart';

// Interceptors and Service Calls
import 'package:grpc/src/server/interceptor.dart';
import 'package:grpc/src/server/call.dart';
import 'package:grpc/src/server/service.dart';

// Server KeepAlive
import 'package:grpc/src/server/server_keepalive.dart';

// Shared utilities like CodecRegistry and GrpcError
import 'package:grpc/src/shared/codec_registry.dart';
import 'package:grpc/src/shared/status.dart';
```

## 3. Implementing a Service

When using generated protobuf files, your generated service class (e.g., `MailServiceBase`) will extend the `Service` class. You must override the RPC methods and use the generated message types.

When constructing responses or reading requests, **always use camelCase** for the generated Dart fields (e.g., `batchId`, `sendAt`, `templateId`), never snake_case.

### Example: Implementing a Mail Service

```dart
import 'dart:async';
import 'package:grpc/src/server/call.dart';
import 'package:grpc/src/shared/status.dart';

// Assuming SendMailRequest and SendMailResponse are generated from your protos
import 'generated/mail.pbgrpc.dart'; 

class MailService extends MailServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // Access fields using camelCase!
    final template = request.templateId;
    final reply = request.replyTo;
    final pool = request.ipPoolName;
    final args = request.customArgs;
    
    // Check deadline or cancellation
    if (call.isCanceled || call.isTimedOut) {
      throw GrpcError.cancelled('Client cancelled the request');
    }

    // You can access client metadata
    final auth = call.clientMetadata?['authorization'];
    if (auth == null) {
      throw GrpcError.unauthenticated('Missing authorization');
    }

    // You can explicitly send headers before the response
    call.headers?['x-mail-received'] = 'true';
    call.sendHeaders();

    // Construct response using the builder pattern with cascades (..)
    return SendMailResponse()
      ..batchId = 'batch_123'
      ..sendAt = '2026-03-19T12:00:00Z'
      ..sandboxMode = false
      ..templateId = template
      ..replyTo = reply
      ..ipPoolName = pool
      ..customArgs.addAll(args);
  }
}
```

## 4. Setup and Serving

To set up a basic gRPC server, instantiate the `Server` class using `Server.create()` and provide your generated `Service` implementations. You can optionally specify a `CodecRegistry` for compression (e.g., Gzip) and a global `errorHandler`.

```dart
import 'dart:io';
import 'package:grpc/src/server/server.dart';
import 'package:grpc/src/shared/codec_registry.dart';
import 'package:grpc/src/shared/codec.dart';

Future<void> main() async {
  // Optional: Add GZIP compression support
  final codecRegistry = CodecRegistry()..add(GzipCodec());

  // Instantiate the server with your generated services
  final server = Server.create(
    services: [
      MailService(),
    ],
    codecRegistry: codecRegistry,
    maxInboundMessageSize: 10 * 1024 * 1024, // 10 MB limit
    errorHandler: (error, trace) {
      print('Global server error caught: $error');
    },
  );

  // Start listening for connections
  await server.serve(
    address: InternetAddress.anyIPv4,
    port: 50051,
  );
  
  print('Server listening on port ${server.port}...');
  
  // Later, gracefully shut down active connections:
  // await server.shutdown();
}
```

## 5. Local IPC Servers

### Cross-Platform Local IPC Server (`LocalGrpcServer`)
If you want to host a server that only accepts local machine connections securely (using Unix Domain Sockets on macOS/Linux or Named Pipes on Windows), use `LocalGrpcServer`.

```dart
import 'package:grpc/src/server/local_server.dart';

Future<void> main() async {
  final localServer = LocalGrpcServer(
    'my-local-service', // Socket or Pipe name
    services: [ MailService() ],
  );

  await localServer.serve();
  print('Listening on local IPC address: ${localServer.address}');
  
  // await localServer.shutdown();
}
```

### Windows Named Pipe Server (`NamedPipeServer`)
If you are explicitly targeting Windows and need to restrict to `PIPE_REJECT_REMOTE_CLIENTS`, use `NamedPipeServer`.

```dart
import 'package:grpc/src/server/named_pipe_server.dart';

Future<void> main() async {
  final pipeServer = NamedPipeServer.create(
    services: [ MailService() ],
    maxInboundMessageSize: 5 * 1024 * 1024,
  );

  // The full path resolves to \.\pipe\my-service-12345
  await pipeServer.serve(pipeName: 'my-service-12345');
  print('Pipe server is running: ${pipeServer.isRunning}');
  
  // Access the number of active streams (useful for testing)
  // print('Active pipes: ${pipeServer.activePipeStreamCount}');
}
```

## 6. Interceptors

### Adding a Simple Interceptor
You can intercept incoming calls to read metadata or authenticate users before the `ServiceMethod` executes. Return a `GrpcError` to reject the call, or `null` to proceed.

```dart
import 'dart:async';
import 'package:grpc/src/server/interceptor.dart';
import 'package:grpc/src/server/call.dart';
import 'package:grpc/src/server/service.dart';
import 'package:grpc/src/shared/status.dart';

FutureOr<GrpcError?> authInterceptor(ServiceCall call, ServiceMethod method) {
  final token = call.clientMetadata?['authorization'];
  if (token == null || token != 'secret-token') {
    return GrpcError.unauthenticated('Invalid or missing token');
  }
  // Inject custom trailers back to the client
  call.trailers?['x-auth-status'] = 'success';
  return null; // Proceed
}

// Attach it during creation:
final server = Server.create(
  services: [],
  interceptors: [authInterceptor],
);
```

### Advanced Server Streaming Interceptor
For modifying streams or catching exceptions around the invocation, implement `ServerInterceptor`:

```dart
import 'dart:async';
import 'package:grpc/src/server/interceptor.dart';
import 'package:grpc/src/server/call.dart';
import 'package:grpc/src/server/service.dart';

class LoggingInterceptor extends ServerInterceptor {
  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    print('Starting RPC call: ${method.name}');
    // You can intercept the request stream, or handle errors on the response stream
    return super.intercept(call, method, requests, invoker).handleError((error) {
      print('RPC threw an error: $error');
      throw error;
    });
  }
}

// Attach it during creation:
final server = Server.create(
  services: [],
  serverInterceptors: [LoggingInterceptor()],
);
```

## 7. Configuration and Context

### ServiceCall Context Details
Inside any RPC handler, the `ServiceCall` object exposes useful metadata:
- **`clientMetadata`**: Custom key-value pairs from the client request.
- **`headers` / `trailers`**: Metadata to send back. Trailers are sent automatically when the stream closes or when `sendTrailers()` is called.
- **`deadline`**: The `DateTime` when the request will expire, if set.
- **`isCanceled` / `isTimedOut`**: Booleans indicating if the request was aborted.
- **`remoteAddress`**: The `InternetAddress` of the client.
- **`clientCertificate`**: The client's `X509Certificate`, if requested via TLS.

### TLS Security
To secure your `Server` with TLS, provide `ServerTlsCredentials` to the `serve()` method. You can optionally require client certificates.

```dart
import 'package:grpc/src/server/server.dart';

final credentials = ServerTlsCredentials(
  certificate: certificateBytes, // List<int>
  privateKey: privateKeyBytes,   // List<int>
);

// Assuming server is an instance of `Server`
await server.serve(
  port: 443,
  security: credentials,
  requestClientCertificate: true, // Ask the client for a cert
  requireClientCertificate: false,
);
```

For limiting TCP connections strictly to loopback addresses, you can use `ServerLocalCredentials`:

```dart
await server.serve(
  port: 50051,
  security: ServerLocalCredentials(),
);
```

### Keep-Alive Policies
You can mitigate bad ping floods (DDoS protection) via `ServerKeepAliveOptions`. This dictates how aggressively the server drops connections that violate ping limits:

```dart
import 'package:grpc/src/server/server_keepalive.dart';

final keepAliveOptions = ServerKeepAliveOptions(
  maxBadPings: 2,
  minIntervalBetweenPingsWithoutData: Duration(minutes: 5),
);

final server = Server.create(
  services: [],
  keepAliveOptions: keepAliveOptions,
);
```

## 8. Related Modules
- **Client Module** (`lib/src/client/`): Contains the counterparts to connect to these servers (e.g., `ClientChannel`, `ClientInterceptor`).
- **Shared Module** (`lib/src/shared/`): Provides base constructs heavily utilized here, such as `GrpcError`, `StatusCode`, and `CodecRegistry`.
- **Local IPC Utilities** (`lib/src/shared/local_ipc.dart`): Contains directory resolution logic used by the `LocalGrpcServer`.
