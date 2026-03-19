# gRPC Server API Reference

## 1. Classes

### ConnectionServer
A gRPC server that serves via provided `ServerTransportConnection`s.

**Key Fields:**
- `Map<ServerTransportConnection, List<ServerHandler>> handlers`: Map of active transport connections to their server handlers (visible for testing).

**Key Methods:**
- `Service? lookupService(String service)`: Returns a registered service matching the given service name.
- `Future<void> serveConnection({required ServerTransportConnection connection, X509Certificate? clientCertificate, InternetAddress? remoteAddress})`: Handles a new server transport connection.
- `Future<void> shutdownActiveConnections()`: Cancels all active gRPC handlers and gracefully finishes all HTTP/2 connections.

### LocalGrpcServer
A local-only gRPC server that uses the best IPC transport per platform (Unix domain sockets on macOS/Linux, Named pipes on Windows).

**Constructors:**
- `LocalGrpcServer(String serviceName, {required List<Service> services, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, ServerKeepAliveOptions keepAliveOptions, int? maxInboundMessageSize})`: Creates a local gRPC server.

**Key Fields:**
- `String serviceName`: The service name used for address resolution.
- `bool isServing`: Whether the server is currently listening.
- `String? address`: The resolved IPC address (socket path or pipe path). Null before `serve()`.
- `ConnectionServer connectionServer`: The underlying `ConnectionServer` for advanced access.

**Key Methods:**
- `Future<void> serve()`: Starts listening for connections on the local IPC transport.
- `Future<void> shutdown()`: Shuts down gracefully, draining in-flight RPCs and cleaning up the socket/pipe.



**Example Usage:**
```dart
import 'package:grpc/grpc.dart';

// Assuming MyServiceImpl is defined as above
void main() async {
  final server = LocalGrpcServer(
    'my-service',
    services: [MyServiceImpl()],
  );

  await server.serve();
  print('Server listening at IPC address: ${server.address}');
  
  // Shutdown when done
  // await server.shutdown();
}
```

### NamedPipeServer
A gRPC server that listens on Windows named pipes.

**Constructors:**
- `NamedPipeServer.create({required List<Service> services, ServerKeepAliveOptions keepAliveOptions, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, int? maxInboundMessageSize})`: Creates a named pipe server for the given services.

**Key Fields:**
- `String? pipePath`: The full Windows path for the named pipe.
- `bool isRunning`: Whether the server is currently running.

**Key Methods:**
- `Future<void> serve({required String pipeName, int maxInstances = 255})`: Starts the named pipe server listening on `\\.\pipe\<pipeName>`.
- `Future<void> shutdown()`: Shuts down the server gracefully.



**Example Usage:**
```dart
import 'package:grpc/grpc.dart';

// Assuming MyServiceImpl is defined as above
void main() async {
  final server = NamedPipeServer.create(
    services: [MyServiceImpl()],
  );

  // Starts the named pipe server listening on \\.\pipe\my-service-12345
  await server.serve(pipeName: 'my-service-12345');
  print('Server listening at: ${server.pipePath}');
  
  // Shutdown when done
  // await server.shutdown();
}
```

### Server
A gRPC server that listens for incoming RPCs via TCP/TLS, dispatching them to the right `Service` handler.

**Constructors:**
- `Server.create({required List<Service> services, ServerKeepAliveOptions keepAliveOptions, List<Interceptor> interceptors, List<ServerInterceptor> serverInterceptors, CodecRegistry? codecRegistry, GrpcErrorHandler? errorHandler, int? maxInboundMessageSize})`: Creates a server for the given services.

**Key Fields:**
- `int? port`: The port that the server is listening on, or `null` if the server is not active.

**Key Methods:**
- `Service? lookupService(String service)`: Looks up a registered service by its name.
- `Future<void> serve({dynamic address, int? port, ServerCredentials? security, ServerSettings? http2ServerSettings, int backlog = 0, bool v6Only = false, bool shared = false, bool requestClientCertificate = false, bool requireClientCertificate = false})`: Starts the `Server` listening on the provided address and port.
- `Future<void> shutdown()`: Stops accepting new connections and shuts down the server.





**Example Usage:**
```dart
import 'package:grpc/grpc.dart';

// Assuming you have a generated service from a proto file
class MyServiceImpl extends MyServiceBase {
  @override
  Future<SendMailResponse> sendMail(ServiceCall call, SendMailRequest request) async {
    // Show the builder pattern (cascade ..) for constructing messages
    final mailFrom = MailFrom()..email = 'sender@example.com';
    
    return SendMailResponse()
      ..batchId = '12345'
      ..sendAt = '2023-10-01T12:00:00Z'
      ..mailSettings = (MailSettings()..sandboxMode = true)
      ..trackingSettings = (TrackingSettings()
        ..clickTracking = (ClickTracking()..enableText = true)
        ..openTracking = (OpenTracking()..substitutionTag = 'tag'))
      ..sandboxMode = true
      ..dynamicTemplateData = {'key': 'value'}
      ..contentId = 'content-123'
      ..customArgs = {'arg1': 'val1'}
      ..ipPoolName = 'my-ip-pool'
      ..replyTo = (ReplyTo()..email = 'reply@example.com')
      ..replyToList = [ReplyTo()..email = 'reply2@example.com']
      ..templateId = 'template-123'
      ..enableText = true
      ..substitutionTag = 'sub-tag'
      ..groupId = 1
      ..groupsToDisplay = [1, 2, 3];
  }
}

void main() async {
  final server = Server.create(
    services: [MyServiceImpl()],
  );

  await server.serve(port: 8080);
  print('Server listening on port ${server.port}');
}
```

### ServerCredentials
Wrapper around server credentials, providing a way to authenticate incoming connections.

**Key Fields:**
- `SecurityContext? get securityContext`: Creates a `SecurityContext` from these credentials if possible.

**Key Methods:**
- `bool validateClient(Socket socket)`: Validates an incoming connection. Returns `true` if the connection is allowed to proceed.

### ServerHandler
Handles an incoming gRPC call, implementing the `ServiceCall` interface.

**Constructors:**
- `ServerHandler({required ServerTransportStream stream, required ServiceLookup serviceLookup, required List<Interceptor> interceptors, required List<ServerInterceptor> serverInterceptors, required CodecRegistry? codecRegistry, required int? maxInboundMessageSize, X509Certificate? clientCertificate, InternetAddress? remoteAddress, GrpcErrorHandler? errorHandler, Sink<void>? onDataReceived})`: Creates a handler for an incoming HTTP/2 stream.

**Key Fields:**
- `DateTime? get deadline`: Deadline for this call.
- `bool get isCanceled`: Returns `true` if the client has canceled this call.
- `bool get isTimedOut`: Returns `true` if the deadline has been exceeded.
- `Map<String, String>? get clientMetadata`: Custom metadata received from the client.
- `Map<String, String>? get headers`: Custom metadata to be sent to the client.
- `Map<String, String>? get trailers`: Custom metadata to be sent to the client after all response messages.
- `X509Certificate? get clientCertificate`: The client certificate if available.
- `InternetAddress? get remoteAddress`: The IP address of the client, if available.
- `Future<void> get onCanceled`: Completes when the client cancels the call.
- `Future<void> get onTerminated`: Completes when the call lifecycle is over.
- `Future<void> get onResponseCancelDone`: Completes when the response subscription cancel has finished.

**Key Methods:**
- `void handle()`: Starts handling the incoming stream and its events.
- `void sendHeaders()`: Sends response headers to the client.
- `void sendTrailers({int? status = 0, String? message, Map<String, String>? errorTrailers})`: Sends response trailers and closes the stream.
- `void cancel()`: Cancels the handler, terminating in-flight operations and the HTTP/2 stream.

### ServerInterceptor
An abstract class defining a gRPC interceptor called around the corresponding `ServiceMethod` invocation.

**Key Methods:**
- `Stream<R> intercept<Q, R>(ServiceCall call, ServiceMethod<Q, R> method, Stream<Q> requests, ServerStreamingInvoker<Q, R> invoker)`: Intercepts a method invocation. If it throws a `GrpcError`, that error is returned as a response. If it modifies the stream, the invocation continues with the provided stream.

### ServerKeepAlive
A keep-alive "manager", deciding what to do when receiving pings from a client based on `ServerKeepAliveOptions`.

**Constructors:**
- `ServerKeepAlive({Future<void> Function()? tooManyBadPings, required ServerKeepAliveOptions options, required Stream<void> pingNotifier, required Stream<void> dataNotifier})`

**Key Fields:**
- `Future<void> Function()? tooManyBadPings`: Callback executed after receiving too many bad pings.
- `ServerKeepAliveOptions options`: Configuration options for keep-alive enforcement.
- `Stream<void> pingNotifier`: A stream of events for every ping received.
- `Stream<void> dataNotifier`: A stream of events for every data frame received.

**Key Methods:**
- `void handle()`: Starts listening to the ping and data streams.
- `void dispose()`: Cancels keep-alive subscriptions to allow the Dart VM to exit cleanly.

### ServerKeepAliveOptions
Options to configure a gRPC server for receiving keepalive signals.

**Constructors:**
- `const ServerKeepAliveOptions({Duration minIntervalBetweenPingsWithoutData = const Duration(minutes: 5), int? maxBadPings = 2})`

**Key Fields:**
- `int? maxBadPings`: The maximum number of bad pings the server will tolerate.
- `Duration minIntervalBetweenPingsWithoutData`: The minimum expected time between successive pings without interleaved data.

### ServerLocalCredentials
A set of credentials that only allows local TCP loopback connections.

**Constructors:**
- `ServerLocalCredentials()`

**Key Fields:**
- `SecurityContext? get securityContext`: Returns `null`.

**Key Methods:**
- `bool validateClient(Socket socket)`: Returns `true` only if the socket is a loopback address.

### ServerTlsCredentials
TLS credentials for a `Server` using certificates and private keys.

**Constructors:**
- `ServerTlsCredentials({List<int>? certificate, String? certificatePassword, List<int>? privateKey, String? privateKeyPassword})`

**Key Fields:**
- `List<int>? certificate`: Certificate chain bytes.
- `String? certificatePassword`: Password for the certificate.
- `List<int>? privateKey`: Private key bytes.
- `String? privateKeyPassword`: Password for the private key.
- `SecurityContext get securityContext`: Generates the `SecurityContext` using the provided keys/certificates.

**Key Methods:**
- `bool validateClient(Socket socket)`: Always returns `true`.

### Service
Abstract definition of a gRPC service handler.

**Key Fields:**
- `String get $name`: The name of the service.

**Key Methods:**
- `void $addMethod(ServiceMethod method)`: Registers a service method.
- `void $onMetadata(ServiceCall context)`: Client metadata handler for providing common handling of incoming metadata.
- `ServiceMethod? $lookupMethod(String name)`: Looks up a registered method by its name.

### ServiceCall
Abstract server-side context for a gRPC call.

**Key Fields:**
- `Map<String, String>? get clientMetadata`: Custom metadata from the client.
- `Map<String, String>? get headers`: Custom metadata to be sent to the client.
- `Map<String, String>? get trailers`: Custom metadata to be sent to the client after all response messages.
- `DateTime? get deadline`: Deadline for this call.
- `bool get isTimedOut`: Returns `true` if the deadline has been exceeded.
- `bool get isCanceled`: Returns `true` if the client canceled the call.
- `X509Certificate? get clientCertificate`: Returns the client certificate if available.
- `InternetAddress? get remoteAddress`: Returns the IP address of the client, if available.

**Key Methods:**
- `void sendHeaders()`: Manually sends response headers before the first response message is sent.
- `void sendTrailers({int? status, String? message})`: Send response trailers indicating the status code. The call is closed afterward.

### ServiceMethod<Q, R>
Definition of a single gRPC service method.

**Constructors:**
- `ServiceMethod(String name, Function handler, bool streamingRequest, bool streamingResponse, Q Function(List<int> request) requestDeserializer, List<int> Function(R response) responseSerializer)`

**Key Fields:**
- `String name`: The name of the method.
- `bool streamingRequest`: Whether the method receives a stream of requests.
- `bool streamingResponse`: Whether the method returns a stream of responses.
- `Q Function(List<int> request) requestDeserializer`: Deserialization function for incoming requests.
- `List<int> Function(R response) responseSerializer`: Serialization function for outgoing responses.
- `Function handler`: The invocation handler implementation.

**Key Methods:**
- `StreamController<Q> createRequestStream(StreamSubscription incoming)`: Creates the request stream.
- `Q deserialize(List<int> data)`: Deserializes raw data into a request object.
- `List<int> serialize(dynamic response)`: Serializes a response object into raw bytes.
- `Stream<R> handle(ServiceCall call, Stream<Q> requests, List<ServerInterceptor> interceptors)`: Handles the invocation of the service method, applying any interceptors.

## 2. Enums
*There are no public enums in the gRPC Server module.*

## 3. Extensions
*There are no public extensions in the gRPC Server module.*

## 4. Top-Level Functions

### Interceptor
`typedef Interceptor = FutureOr<GrpcError?> Function(ServiceCall call, ServiceMethod method);`
- **Description**: An interceptor function called before the corresponding `ServiceMethod` invocation.
- **Parameters**: `ServiceCall call`, `ServiceMethod method`
- **Returns**: `FutureOr<GrpcError?>`

### ServerStreamingInvoker<Q, R>
`typedef ServerStreamingInvoker<Q, R> = Stream<R> Function(ServiceCall call, ServiceMethod<Q, R> method, Stream<Q> requests);`
- **Description**: A function signature representing the internal invocation of a server streaming method.
- **Parameters**: `ServiceCall call`, `ServiceMethod<Q, R> method`, `Stream<Q> requests`
- **Returns**: `Stream<R>`

### ServiceLookup
`typedef ServiceLookup = Service? Function(String service);`
- **Description**: A function signature used for resolving a service by its string name.
- **Parameters**: `String service`
- **Returns**: `Service?`

### GrpcErrorHandler
`typedef GrpcErrorHandler = void Function(GrpcError error, StackTrace? trace);`
- **Description**: A callback function for handling and logging internal server-side errors.
- **Parameters**: `GrpcError error`, `StackTrace? trace`
- **Returns**: `void`
