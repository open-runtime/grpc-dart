# gRPC Client API Reference

### 1. Classes

* **CallOptions** -- Runtime options for an RPC.
  * Fields:
    * `Map<String, String> metadata`: Static metadata.
    * `Duration? timeout`: Optional timeout for the call.
    * `List<MetadataProvider> metadataProviders`: Per-RPC metadata providers.
    * `Codec? compression`: Compression codec.
  * Constructors: `CallOptions({Map<String, String>? metadata, Duration? timeout, List<MetadataProvider>? providers, Codec? compression})`, `CallOptions.from(Iterable<CallOptions> options)`
  * Methods:
    * `mergedWith(CallOptions? other) -> CallOptions`: Merges these options with another instance.
  * **Example**:
    ```dart
    import 'package:grpc/grpc.dart';

    final options = CallOptions(
      metadata: {'authorization': 'Bearer token'},
      timeout: Duration(seconds: 30),
      providers: [
        (metadata, uri) async {
          metadata['x-custom-header'] = 'value';
        }
      ],
    );
    ```

* **ChannelCredentials** -- Options controlling TLS security settings on a ClientChannel.
  * Fields:
    * `bool isSecure`: Indicates if TLS is enabled.
    * `String? authority`: The authority to verify the TLS connection against.
    * `BadCertificateHandler? onBadCertificate`: Handler for checking certificates that fail validation.
    * `SecurityContext? securityContext`: Returns the underlying SecurityContext (if secure).
  * Constructors: `ChannelCredentials.insecure({String? authority})`, `ChannelCredentials.secure({List<int>? certificates, String? password, String? authority, BadCertificateHandler? onBadCertificate})`
  * **Example**:
    ```dart
    import 'package:grpc/grpc.dart';

    // Insecure credentials for local development
    final insecureCreds = ChannelCredentials.insecure();

    // Secure credentials for production
    final secureCreds = ChannelCredentials.secure();
    ```

* **ChannelOptions** -- Options controlling how connections are made on a ClientChannel.
  * Fields:
    * `ChannelCredentials credentials`: The channel credentials.
    * `Duration? idleTimeout`: The time a connection can be idle before closing.
    * `CodecRegistry? codecRegistry`: Registry for supported codecs.
    * `Duration connectionTimeout`: Maximum time a single connection will be used for new requests.
    * `Duration? connectTimeout`: Maximum time to wait for a connection to be established.
    * `BackoffStrategy backoffStrategy`: Strategy for connection backoffs.
    * `String userAgent`: User agent string.
    * `ClientKeepAliveOptions keepAlive`: Keepalive options.
    * `Proxy? proxy`: Proxy configuration.
    * `int? maxInboundMessageSize`: Maximum allowed inbound message size.
  * Constructors: `ChannelOptions(...)`
  * **Example**:
    ```dart
    import 'package:grpc/grpc.dart';

    final options = ChannelOptions(
      credentials: ChannelCredentials.insecure(),
      idleTimeout: Duration(minutes: 10),
      connectTimeout: Duration(seconds: 5),
    );
    ```

* **Client** -- Base class for client stubs.
  * Constructors: `Client(ClientChannel channel, {CallOptions? options, Iterable<ClientInterceptor>? interceptors})`
  * Methods:
    * `$createUnaryCall<Q, R>(ClientMethod<Q, R> method, Q request, {CallOptions? options}) -> ResponseFuture<R>`: Creates and invokes a unary call invoking interceptors.
    * `$createStreamingCall<Q, R>(ClientMethod<Q, R> method, Stream<Q> requests, {CallOptions? options}) -> ResponseStream<R>`: Creates and invokes a streaming call invoking interceptors.
    * `$createCall<Q, R>(ClientMethod<Q, R> method, Stream<Q> requests, {CallOptions? options}) -> ClientCall<Q, R>`: (Deprecated) Creates a call without invoking interceptors.

* **ClientCall<Q, R>** -- An active call to a gRPC endpoint.
  * Fields:
    * `CallOptions options`: Runtime options for the call.
    * `bool isCancelled`: Indicates if the call has been cancelled.
    * `Stream<R> response`: Stream of responses from the server.
    * `Future<Map<String, String>> headers`: Header metadata returned from the server.
    * `Future<Map<String, String>> trailers`: Trailer metadata returned from the server.
  * Methods:
    * `cancel() -> Future<void>`: Cancels this gRPC call.
    * `onConnectionError(Object error) -> void`: Terminates the call on a connection error.
    * `onConnectionReady(ClientConnection connection) -> void`: Sends the request once connection is ready.

* **ClientChannel** -- A channel to a virtual RPC endpoint (abstract interface).
  * Methods:
    * `shutdown() -> Future<void>`: Shuts down the channel gracefully.
    * `terminate() -> Future<void>`: Terminates the channel immediately.
    * `createCall<Q, R>(ClientMethod<Q, R> method, Stream<Q> requests, CallOptions options) -> ClientCall<Q, R>`: Initiates a new RPC.
    * `Stream<ConnectionState> get onConnectionStateChanged`: Stream of connection state changes.

* **ClientChannel** (Http2) -- A channel to a virtual gRPC endpoint using HTTP/2. (Extends `ClientChannelBase`).
  * Fields:
    * `Object host`: Target host.
    * `int port`: Target port.
    * `ChannelOptions options`: Channel options.
  * Constructors: `ClientChannel(Object host, {int port = 443, ChannelOptions options, void Function()? channelShutdownHandler})`
  * Methods:
    * `createConnection() -> ClientConnection`: Creates a new Http2ClientConnection.
  * **Example**:
    ```dart
    import 'package:grpc/grpc.dart';

    final channel = ClientChannel(
      'localhost',
      port: 50051,
      options: const ChannelOptions(
        credentials: ChannelCredentials.insecure(),
      ),
    );
    
    // Shutting down the channel when done
    // await channel.shutdown();
    ```

* **ClientChannelBase** -- Auxiliary base class implementing much of ClientChannel.
  * Methods:
    * `shutdown() -> Future<void>`: Shuts down the channel.
    * `terminate() -> Future<void>`: Terminates the channel.
    * `getConnection() -> Future<ClientConnection>`: Returns an active connection to the endpoint.
    * `createConnection() -> ClientConnection`: Abstract method to create a connection.
    * `createCall<Q, R>(...) -> ClientCall<Q, R>`: Dispatches a new call on the connection.

* **ClientConnection** -- Abstract interface for a connection to a server.
  * Fields:
    * `String authority`: The authority of the connection.
    * `String scheme`: The scheme (http or https).
  * Methods:
    * `dispatchCall(ClientCall call) -> void`: Puts a call on the queue to be dispatched.
    * `makeRequest(String path, Duration? timeout, Map<String, String> metadata, ErrorHandler onRequestFailure, {required CallOptions callOptions}) -> GrpcTransportStream`: Starts a request.
    * `shutdown() -> Future<void>`: Shuts down this connection gracefully.
    * `terminate() -> Future<void>`: Terminates this connection immediately.
    * `set onStateChanged(void Function(ConnectionState) cb)`: Sets a listener for state changes.

* **ClientInterceptor** -- Intercepts client calls before they are executed.
  * Methods:
    * `interceptUnary<Q, R>(ClientMethod<Q, R> method, Q request, CallOptions options, ClientUnaryInvoker<Q, R> invoker) -> ResponseFuture<R>`: Intercepts a unary call.
    * `interceptStreaming<Q, R>(ClientMethod<Q, R> method, Stream<Q> requests, CallOptions options, ClientStreamingInvoker<Q, R> invoker) -> ResponseStream<R>`: Intercepts a streaming call.
  * **Example**:
    ```dart
    import 'package:grpc/grpc.dart';

    class LoggingInterceptor extends ClientInterceptor {
      @override
      ResponseFuture<R> interceptUnary<Q, R>(
        ClientMethod<Q, R> method,
        Q request,
        CallOptions options,
        ClientUnaryInvoker<Q, R> invoker,
      ) {
        print('Sending request to ${method.path}');
        return super.interceptUnary(method, request, options, invoker);
      }
    }
    ```

* **ClientKeepAlive** -- A keep alive manager deciding when to send pings or shutdown based on options.
  * Fields:
    * `KeepAliveState state`: The current keep-alive state.
    * `void Function() onPingTimeout`: Callback invoked when ping times out.
    * `void Function() ping`: Callback invoked to send a ping.
  * Constructors: `ClientKeepAlive({required ClientKeepAliveOptions options, required void Function() ping, required void Function() onPingTimeout})`
  * Methods:
    * `onTransportStarted() -> void`
    * `onFrameReceived() -> void`
    * `sendPing() -> void`
    * `onTransportActive() -> void`
    * `onTransportIdle() -> void`
    * `onTransportTermination() -> void`

* **ClientKeepAliveOptions** -- Options to configure a gRPC client for sending keepalive signals.
  * Fields:
    * `Duration? pingInterval`: How often a ping should be sent.
    * `Duration timeout`: Time to wait before shutting down after no response.
    * `bool permitWithoutCalls`: Whether to keep alive with no active calls.
    * `bool shouldSendPings`: Indicates if pings should be sent.
  * Constructors: `ClientKeepAliveOptions({Duration? pingInterval, Duration timeout = const Duration(seconds: 20), bool permitWithoutCalls = false})`

* **ClientMethod<Q, R>** -- Description of a gRPC method.
  * Fields:
    * `String path`: The method path.
    * `List<int> Function(Q value) requestSerializer`: Function to serialize requests.
    * `R Function(List<int> value) responseDeserializer`: Function to deserialize responses.
  * Constructors: `ClientMethod(String path, List<int> Function(Q) requestSerializer, R Function(List<int>) responseDeserializer)`

* **ClientTransportConnector** -- A transport-specific configuration used by gRPC clients to connect.
  * Fields:
    * `Future get done`: Completes when the client closes or errors.
    * `String authority`: Header populated from credentials or hostname.
  * Methods:
    * `connect() -> Future<ClientTransportConnection>`: Creates a client connection.
    * `shutdown() -> void`: Shuts down the connection.

* **ClientTransportConnectorChannel** -- A ClientChannelBase implementation wrapping a ClientTransportConnector.
  * Fields:
    * `ClientTransportConnector transportConnector`: The transport connector to use.
    * `ChannelOptions options`: Channel options.
  * Constructors: `ClientTransportConnectorChannel(ClientTransportConnector transportConnector, {ChannelOptions options = const ChannelOptions()})`
  * Methods:
    * `createConnection() -> ClientConnection`: Creates an Http2ClientConnection from the transport connector.

* **Disconnected** (extends KeepAliveState) -- Represents a disconnected keepalive state.
  * Methods:
    * `disconnect() -> void`
    * `onEvent(KeepAliveEvent event, ClientKeepAlive manager) -> KeepAliveState?`

* **GrpcOrGrpcWebClientChannelInternal** -- Unified internal channel to pick gRPC or gRPC-web.
  * Constructors: `GrpcOrGrpcWebClientChannelInternal(...)`, `GrpcOrGrpcWebClientChannelInternal.grpc(...)`

* **GrpcTransportStream** -- Stream representation for transport messages.
  * Fields:
    * `Stream<GrpcMessage> incomingMessages`: Incoming messages stream.
    * `StreamSink<List<int>> outgoingMessages`: Sink for outgoing messages.
  * Methods:
    * `terminate() -> Future<void>`: Terminates the stream.

* **GrpcWebClientChannel** -- A channel to a grpc-web endpoint.
  * Fields:
    * `Uri uri`: The endpoint URI.
    * `int? maxInboundMessageSize`: Max inbound message size limit.
  * Constructors: `GrpcWebClientChannel.xhr(Uri uri, {int? maxInboundMessageSize, void Function()? channelShutdownHandler})`
  * Methods:
    * `createConnection() -> ClientConnection`

* **GrpcWebDecoder** -- Decoder for parsing gRPC-web frames from chunked ByteBuffers.
  * Fields:
    * `int? maxInboundMessageSize`: Optional limit for parsing large frames.
  * Constructors: `GrpcWebDecoder({int? maxInboundMessageSize})`
  * Methods:
    * `convert(ByteBuffer input) -> GrpcMessage`
    * `startChunkedConversion(Sink<GrpcMessage> sink) -> Sink<ByteBuffer>`

* **Http2ClientConnection** -- HTTP/2 ClientConnection implementation.
  * Fields:
    * `ChannelOptions options`: Options used for the connection.
    * `String authority`: Connection authority.
    * `String scheme`: Connection scheme.
    * `ConnectionState state`: Current state of the connection.
  * Constructors: `Http2ClientConnection(Object host, int port, ChannelOptions options)`, `Http2ClientConnection.fromClientTransportConnector(...)`
  * Methods:
    * `connectTransport() -> Future<ClientTransportConnection>`
    * `dispatchCall(ClientCall call) -> void`
    * `makeRequest(...) -> GrpcTransportStream`
    * `shutdown() -> Future<void>`
    * `terminate() -> Future<void>`

* **Http2TransportStream** -- HTTP/2 implementation of GrpcTransportStream.
  * Fields:
    * `Stream<GrpcMessage> incomingMessages`
    * `StreamSink<List<int>> outgoingMessages`
  * Constructors: `Http2TransportStream(TransportStream _transportStream, ErrorHandler _onError, CodecRegistry? codecRegistry, Codec? compression, {int? maxInboundMessageSize})`
  * Methods:
    * `terminate() -> Future<void>`

* **Idle** (extends KeepAliveState) -- Idle keepalive state, indicating transport has no active rpcs.
  * Fields:
    * `Timer? pingTimer`
    * `Stopwatch timeSinceFrame`
  * Constructors: `Idle([Timer? pingTimer, Stopwatch? stopwatch])`
  * Methods:
    * `onEvent(KeepAliveEvent event, ClientKeepAlive manager) -> KeepAliveState?`
    * `disconnect() -> void`

* **IXMLHttpRequest** -- Interface abstracting XMLHttpRequest functionality.
  * Fields: `onReadyStateChange`, `onProgress`, `onError`, `readyState`, `response`, `responseText`, `responseHeaders`, `status`
  * Methods: `abort()`, `open(...)`, `overrideMimeType(...)`, `send(...)`, `setRequestHeader(...)`, `toXMLHttpRequest()`

* **KeepAliveState** (Sealed class) -- Base state for ClientKeepAlive.
  * Methods:
    * `onEvent(KeepAliveEvent event, ClientKeepAlive manager) -> KeepAliveState?`
    * `disconnect() -> void`

* **LocalChannelOptions** -- Options for LocalGrpcChannel.
  * Fields:
    * `Duration? connectTimeout`, `Duration connectionTimeout`, `Duration idleTimeout`, `BackoffStrategy backoffStrategy`, `ClientKeepAliveOptions keepAlive`, `CodecRegistry? codecRegistry`, `int? maxInboundMessageSize`
  * Constructors: `LocalChannelOptions(...)`
  * Methods:
    * `toChannelOptions() -> ChannelOptions`: Converts to standard ChannelOptions.

* **LocalGrpcChannel** -- A local-only gRPC client channel that uses the best IPC transport.
  * Fields:
    * `String serviceName`: The service name used for address resolution.
    * `String address`: The resolved IPC address.
  * Constructors: `LocalGrpcChannel(String serviceName, {LocalChannelOptions options = const LocalChannelOptions(), void Function()? channelShutdownHandler})`
  * Methods:
    * `shutdown() -> Future<void>`
    * `terminate() -> Future<void>`
    * `createCall<Q, R>(...) -> ClientCall<Q, R>`
  * **Example**:
    ```dart
    import 'package:grpc/grpc.dart';

    // Creates a local-only gRPC client channel (uses Named Pipes on Windows, UDS on macOS/Linux)
    final channel = LocalGrpcChannel('my-service');
    
    // await channel.shutdown();
    ```

* **NamedPipeChannelOptions** -- Channel options preset for local named pipe communication.
  * Constructors: `NamedPipeChannelOptions(...)`

* **NamedPipeClientChannel** -- A gRPC client channel that communicates over Windows named pipes.
  * Fields:
    * `String pipeName`: Name of the pipe to connect to.
    * `ChannelOptions options`: Channel options.
    * `String pipePath`: Full Windows path for the named pipe.
  * Constructors: `NamedPipeClientChannel(String pipeName, {ChannelOptions options = const ChannelOptions(), void Function()? channelShutdownHandler})`
  * Methods:
    * `createConnection() -> ClientConnection`

* **NamedPipeException** -- Exception thrown when a named pipe operation fails.
  * Fields:
    * `String message`: Human-readable error message.
    * `int errorCode`: Win32 error code.
  * Constructors: `NamedPipeException(String message, int errorCode)`

* **NamedPipeTransportConnector** -- ClientTransportConnector implementation for Windows named pipes.
  * Fields:
    * `String pipeName`: Name of the pipe.
    * `Duration? connectTimeout`: Maximum time to wait for establishment.
    * `String pipePath`: Full path.
    * `String authority`: Always returns 'localhost'.
    * `Future<void> done`: Completion future.
  * Constructors: `NamedPipeTransportConnector(String pipeName, {Duration? connectTimeout})`
  * Methods:
    * `connect() -> Future<ClientTransportConnection>`
    * `shutdown() -> void`

* **PingDelayed** (extends KeepAliveState) -- Keepalive state where ping is delayed.
  * Fields: `Timer pingTimer`, `Stopwatch timeSinceFrame`
  * Constructors: `PingDelayed(Timer pingTimer)`
  * Methods: `onEvent(...)`, `disconnect()`

* **PingScheduled** (extends KeepAliveState) -- Keepalive state where ping is scheduled for the future.
  * Fields: `Timer pingTimer`, `Stopwatch timeSinceFrame`
  * Constructors: `PingScheduled(Timer pingTimer, [Stopwatch? stopwatch])`
  * Methods: `onEvent(...)`, `disconnect()`

* **Proxy** -- Proxy data class with optional authentication.
  * Fields:
    * `String host`: Proxy host.
    * `int port`: Proxy port.
    * `String? username`: Optional username.
    * `String? password`: Optional password.
    * `bool isAuthenticated`: Returns true if a username is provided.
  * Constructors: `Proxy({required String host, required int port, String? username, String? password})`

* **QueryParameter** -- Enclosing class for query parameters.
  * Fields:
    * `String key`: The parameter key.
    * `List<String> values`: List of parameter values.
    * `String value`: Single parameter value.
  * Constructors: `QueryParameter(String key, String value)`, `QueryParameter.multi(String key, List<String> values)`
  * Methods:
    * `compareTo(QueryParameter other) -> int`: Compares based on string value.
    * `static buildQuery(List<QueryParameter> queryParams) -> String`: Builds a canonical URL query string.

* **Response** -- Abstract representation of a gRPC response.
  * Fields:
    * `Future<Map<String, String>> headers`: Header metadata from the server.
    * `Future<Map<String, String>> trailers`: Trailer metadata from the server.
  * Methods:
    * `cancel() -> Future<void>`: Cancels the gRPC call.

* **ResponseFuture<R>** -- A gRPC response producing a single value.
  * Fields:
    * `Future<Map<String, String>> headers`
    * `Future<Map<String, String>> trailers`
  * Constructors: `ResponseFuture(ClientCall<dynamic, R> _call)`
  * Methods:
    * `cancel() -> Future<void>`

* **ResponseStream<R>** -- A gRPC response producing a stream of values.
  * Fields:
    * `ResponseFuture<R> single`: A future resolving to the single response.
    * `Future<Map<String, String>> headers`
    * `Future<Map<String, String>> trailers`
  * Constructors: `ResponseStream(ClientCall<dynamic, R> _call)`
  * Methods:
    * `cancel() -> Future<void>`

* **ShutdownScheduled** (extends KeepAliveState) -- State where connection shutdown is scheduled pending a ping response.
  * Fields: `bool isIdle`, `Timer shutdownTimer`
  * Constructors: `ShutdownScheduled(Timer shutdownTimer, bool isIdle)`
  * Methods: `onEvent(...)`, `disconnect()`

* **SocketTransportConnector** -- Socket based implementation of ClientTransportConnector.
  * Fields:
    * `Proxy? proxy`: The active proxy configuration.
    * `Object host`: Target host.
    * `int port`: Target port.
    * `String authority`: Computed authority.
    * `Future get done`: Completion future.
  * Constructors: `SocketTransportConnector(Object _host, int _port, ChannelOptions _options)`
  * Methods:
    * `connect() -> Future<ClientTransportConnection>`
    * `initSocket(Object host, int port) -> Future<Socket>`
    * `connectToProxy(Proxy proxy) -> Future<Stream<List<int>>>`
    * `shutdown() -> void`

* **WebCallOptions** (extends CallOptions) -- Runtime options specific to gRPC-web.
  * Fields:
    * `bool? bypassCorsPreflight`: Eliminates CORS preflight by packing headers into query params.
    * `bool? withCredentials`: Sends credentials along with the XHR.
  * Constructors: `WebCallOptions({Map<String, String>? metadata, Duration? timeout, List<MetadataProvider>? providers, bool? bypassCorsPreflight, bool? withCredentials})`
  * Methods:
    * `mergedWith(CallOptions? other) -> CallOptions`

* **XhrClientConnection** -- gRPC-Web client connection using XHR.
  * Fields:
    * `Uri uri`: Target URI.
    * `int? maxInboundMessageSize`: Size limit for inbound messages.
    * `String authority`
    * `String scheme`
  * Constructors: `XhrClientConnection(Uri uri, {int? maxInboundMessageSize})`
  * Methods:
    * `makeRequest(...) -> GrpcTransportStream`
    * `terminate() -> Future<void>`
    * `dispatchCall(ClientCall call) -> void`
    * `shutdown() -> Future<void>`

* **XMLHttpRequestImpl** -- Implementation of IXMLHttpRequest that delegates to a real dart:html/web XMLHttpRequest.
  * Constructors: `XMLHttpRequestImpl()`
  * Methods: Implements all properties and methods of `IXMLHttpRequest`

* **XhrTransportStream** -- XHR based implementation of GrpcTransportStream.
  * Fields:
    * `Stream<GrpcMessage> incomingMessages`
    * `StreamSink<List<int>> outgoingMessages`
  * Constructors: `XhrTransportStream(IXMLHttpRequest _request, {required ErrorHandler onError, required dynamic onDone, int? maxInboundMessageSize})`
  * Methods:
    * `terminate() -> Future<void>`

### 2. Enums

* **ConnectionState** -- Represents the connection state of a client.
  * `connecting`: Actively trying to connect.
  * `ready`: Connection successfully established.
  * `transientFailure`: Some transient failure occurred, waiting to re-connect.
  * `idle`: Not currently connected, and no pending RPCs.
  * `shutdown`: Shutting down, no further RPCs allowed.

* **KeepAliveEvent** -- Events affecting the keepalive manager's state machine.
  * `onTransportActive`: Transport becomes active.
  * `onFrameReceived`: A frame is received from the transport.
  * `onTransportIdle`: Transport becomes idle.
  * `sendPing`: Indicates a ping should be sent.

### 3. Extensions

*(No public extensions defined in the `gRPC Client` module.)*

### 4. Top-Level Functions

* **allowBadCertificates** -- `bool allowBadCertificates(X509Certificate certificate, String host)`
  * Bad certificate handler that disables all certificate checks (DO NOT USE IN PRODUCTION).

* **defaultBackoffStrategy** -- `Duration defaultBackoffStrategy(Duration? lastBackoff)`
  * Provides the default connection backoff algorithm from the gRPC connection backoff spec.

* **moveHttpHeadersToQueryParam** -- `Uri moveHttpHeadersToQueryParam(Map<String, String> metadata, Uri requestUri)`
  * Manipulates the path and headers of the HTTP request to avoid CORS preflight requests by moving headers to query parameters.

#### Typedefs (Supporting Types)

* **MetadataProvider** -- `FutureOr<void> Function(Map<String, String> metadata, String uri)`
  * Defines a metadata provider invoked for every RPC to modify/add custom metadata to the outgoing request.

* **ClientUnaryInvoker<Q, R>** -- `ResponseFuture<R> Function(ClientMethod<Q, R> method, Q request, CallOptions options)`
  * Defines the invoker signature for executing unary calls.

* **ClientStreamingInvoker<Q, R>** -- `ResponseStream<R> Function(ClientMethod<Q, R> method, Stream<Q> requests, CallOptions options)`
  * Defines the invoker signature for executing streaming calls.

* **BadCertificateHandler** -- `bool Function(X509Certificate certificate, String host)`
  * Defines a handler for checking certificates that fail validation.

* **BackoffStrategy** -- `Duration Function(Duration? lastBackoff)`
  * Defines a connection backoff strategy handler.

* **SocketClosedHandler** -- `void Function()`
* **ActiveStateHandler** -- `void Function(bool isActive)`
* **ErrorHandler** -- `void Function(Object, StackTrace)`


### 5. Usage with Generated Protobuf Classes

When using the `ClientChannel` and `CallOptions` with generated protobuf classes, use the builder pattern (cascade `..`) to construct messages. Ensure that field names are converted to `camelCase` (e.g., `batch_id` becomes `batchId`, `send_at` becomes `sendAt`, `mail_settings` becomes `mailSettings`).

```dart
import 'package:grpc/grpc.dart';

// Assuming SendMailRequest and other classes are generated from protobuf.
// import 'src/generated/my_service.pbgrpc.dart';

// Mocking the generated classes for the example
class MailSettings {
  bool sandboxMode = false;
}

class TrackingSettings {
  bool clickTracking = false;
  bool openTracking = false;
}

class SendMailRequest {
  String batchId = '';
  int sendAt = 0;
  MailSettings mailSettings = MailSettings();
  TrackingSettings trackingSettings = TrackingSettings();
  String dynamicTemplateData = '';
  String contentId = '';
  Map<String, String> customArgs = {};
  String ipPoolName = '';
  String replyTo = '';
  List<String> replyToList = [];
  String templateId = '';
  bool enableText = false;
  String substitutionTag = '';
  int groupId = 0;
  List<int> groupsToDisplay = [];
}

class MyServiceClient extends Client {
  MyServiceClient(super.channel);

  ResponseFuture<dynamic> sendMail(SendMailRequest request, {CallOptions? options}) {
    // Generated implementation
    return ResponseFuture(ClientCall(
      ClientMethod('MyService/SendMail', (v) => [], (v) => v),
      Stream.value(request),
      options ?? CallOptions(),
    ));
  }
}

Future<void> main() async {
  // Create a channel using the provided options
  final channel = ClientChannel(
    'api.example.com',
    port: 443,
    options: const ChannelOptions(
      credentials: ChannelCredentials.secure(),
    ),
  );

  // Initialize the generated client stub
  final stub = MyServiceClient(channel);

  // Use the builder pattern to construct the message
  final request = SendMailRequest()
    ..batchId = 'batch-123'
    ..sendAt = 1618318999
    ..mailSettings = (MailSettings()..sandboxMode = true)
    ..trackingSettings = (TrackingSettings()
      ..clickTracking = true
      ..openTracking = true)
    ..dynamicTemplateData = '{"key":"value"}'
    ..contentId = 'content-456'
    ..customArgs = {'app': 'demo'}
    ..ipPoolName = 'transactional'
    ..replyTo = 'support@example.com'
    ..replyToList = ['admin@example.com', 'billing@example.com']
    ..templateId = 'd-123456789'
    ..enableText = true
    ..substitutionTag = '{{tag}}'
    ..groupId = 1
    ..groupsToDisplay = [1, 2, 3];

  try {
    final response = await stub.sendMail(
      request,
      options: CallOptions(metadata: {'authorization': 'Bearer token'}),
    );
    print('Response received');
  } on GrpcError catch (e) {
    print('gRPC Error: ${e.codeName} - ${e.message}');
  } finally {
    await channel.shutdown();
  }
}
```
