# Http2 Module Quickstart

## 1. Overview
The `Http2` module provides a low-level, pure-Dart implementation of the HTTP/2 transport protocol (RFC 7540) operating over a bidirectional stream of bytes. It is the underlying transport for gRPC and features full support for multiplexing, flow control, HPACK header compression, stream prioritization, and server push.

## 2. Naming Conventions (Protobuf to Dart)
While the `Http2` module itself is a core transport implementation, it follows the same naming conventions as Protobuf-generated Dart code. All `snake_case` field names from proto definitions are converted to `camelCase` in Dart. **Always use camelCase** for Dart property access. Message and enum names remain `PascalCase` (e.g., `ClientSettings`, `ErrorCode`).

| Proto Field Name | Dart Property Name | Description |
|------------------|--------------------|-------------|
| `batch_id` | `batchId` | String identifier |
| `send_at` | `sendAt` | Int64 timestamp |
| `mail_settings` | `mailSettings` | Nested message |
| `tracking_settings` | `trackingSettings` | Tracking configuration |
| `click_tracking` | `clickTracking` | Click tracking toggle |
| `open_tracking` | `openTracking` | Open tracking toggle |
| `sandbox_mode` | `sandboxMode` | Boolean flag |
| `dynamic_template_data` | `dynamicTemplateData` | Map field |
| `content_id` | `contentId` | String content ID |
| `custom_args` | `customArgs` | Map of custom arguments |
| `ip_pool_name` | `ipPoolName` | IP pool identifier |
| `reply_to` | `replyTo` | Single reply address |
| `reply_to_list` | `replyToList` | Repeated reply addresses |
| `template_id` | `templateId` | Template identifier |
| `enable_text` | `enableText` | Boolean flag |
| `substitution_tag` | `substitutionTag` | String tag |
| `group_id` | `groupId` | Int32 group ID |
| `groups_to_display` | `groupsToDisplay` | Repeated group IDs |

## 3. Import
To use the Http2 module, import the transport library using the `package:grpc-dart/` prefix:

```dart
import 'package:grpc-dart/src/http2/http2.dart';
```

## 4. Setup

### Client Setup
Establish a connection to an HTTP/2 capable server using a `SecureSocket` with ALPN negotiation.

```dart
import 'dart:io';
import 'package:grpc-dart/src/http2/http2.dart';

Future<void> setupClient() async {
  // 1. Connect via SecureSocket with 'h2' protocol
  final socket = await SecureSocket.connect(
    'localhost',
    443,
    supportedProtocols: ['h2'],
  );
  
  // 2. Configure client settings
  final clientSettings = ClientSettings(
    allowServerPushes: true, // Whether the client allows pushes from the server
    concurrentStreamLimit: 100, // Max concurrent streams the server can open
    streamWindowSize: 65535, // Initial stream window size
  );
  
  // 3. Create the connection
  final clientConnection = ClientTransportConnection.viaSocket(
    socket, 
    settings: clientSettings,
  );
}
```

### Server Setup
Bind a `SecureServerSocket` and handle incoming HTTP/2 connections.

```dart
import 'dart:io';
import 'package:grpc-dart/src/http2/http2.dart';

Future<void> setupServer(SecurityContext context) async {
  final serverSocket = await SecureServerSocket.bind(
    'localhost', 
    443, 
    context, 
    supportedProtocols: ['h2'],
  );
  
  serverSocket.listen((SecureSocket socket) {
    final serverSettings = ServerSettings(
      concurrentStreamLimit: 1000, // Max concurrent streams the client can open
      streamWindowSize: 1048576,    // 1MB initial window size
    );
    
    final serverConnection = ServerTransportConnection.viaSocket(
      socket, 
      settings: serverSettings,
    );
    
    // Handle incoming streams
    serverConnection.incomingStreams.listen(_handleStream);
  });
}
```

## 5. Common Operations

### Making a Request (Client)
```dart
final headers = [
  Header.ascii(':method', 'GET'),
  Header.ascii(':path', '/api/resource'),
  Header.ascii(':scheme', 'https'),
  Header.ascii(':authority', 'localhost'),
];

// Open a new stream
final stream = clientConnection.makeRequest(headers, endStream: true);

// Listen for response messages
stream.incomingMessages.listen((StreamMessage message) {
  if (message is HeadersStreamMessage) {
    // Response headers received
    print('Status: ${message.headers.firstWhere((h) => h.nameString == ":status").valueString}');
  } else if (message is DataStreamMessage) {
    // Response data chunk received
    print('Received ${message.bytes.length} bytes');
  }
});

// Handle stream termination (e.g., RST_STREAM)
stream.onTerminated = (int? errorCode) {
  if (errorCode != null) {
    print('Stream terminated with error: $errorCode');
  }
};
```

### Responding to a Request (Server)
```dart
void _handleStream(ServerTransportStream stream) {
  stream.incomingMessages.listen((message) {
    if (message is HeadersStreamMessage) {
      // 1. Send response headers
      stream.sendHeaders([
        Header.ascii(':status', '200'),
        Header.ascii('content-type', 'application/octet-stream'),
      ]);
      
      // 2. Send response data
      stream.sendData([0, 1, 2, 3], endStream: true);
    }
  });
}
```

### Server Push
The server can push resources if `canPush` is true and the client permits it.

```dart
if (stream.canPush) {
  final pushHeaders = [
    Header.ascii(':method', 'GET'),
    Header.ascii(':path', '/static/style.css'),
    Header.ascii(':authority', 'localhost'),
  ];
  
  final pushStream = stream.push(pushHeaders);
  pushStream.sendHeaders([Header.ascii(':status', '200')]);
  pushStream.sendData([/* css bytes */], endStream: true);
}
```

### Connection Monitoring and Control
```dart
// Wait for initial settings exchange
await clientConnection.onInitialPeerSettingsReceived;

// Send a ping to measure latency
await clientConnection.ping();

// Listen for incoming pings
clientConnection.onPingReceived.listen((id) => print('Received ping $id'));

// Monitor connection activity (idle vs active)
clientConnection.onActiveStateChanged = (bool isActive) {
  print('Connection is now ${isActive ? "active" : "idle"}');
};

// Graceful shutdown
await clientConnection.finish();
```

## 6. Exhaustive API Reference

### Connection Types
*   **`ClientTransportConnection`**: Manages a client-side HTTP/2 connection.
    *   `isOpen` (bool): Whether the connection is currently open and accepting new requests.
    *   `makeRequest(headers, {endStream})`: Initiates a new bidirectional stream.
*   **`ServerTransportConnection`**: Manages a server-side HTTP/2 connection.
    *   `incomingStreams` (Stream): Emits `ServerTransportStream` for every new request initiated by the client.

### Stream Types
*   **`TransportStream`**: Common interface for HTTP/2 streams.
    *   `id` (int): The unique HTTP/2 stream identifier.
    *   `incomingMessages` (Stream): Stream of `HeadersStreamMessage` and `DataStreamMessage`.
    *   `outgoingMessages` (StreamSink): Sink for sending `StreamMessage`s.
    *   `sendHeaders(headers, {endStream})`: Convenience method to send headers.
    *   `sendData(bytes, {endStream})`: Convenience method to send data.
    *   `terminate()`: Forcefully terminates the stream (sends `RST_STREAM`).
    *   `onTerminated` (Setter): Callback invoked when the stream is terminated via `RST_STREAM`.

### Message Types
*   **`HeadersStreamMessage`**: Represents a frame of HTTP headers.
    *   `headers` (List<Header>): The list of name-value pairs.
    *   `endStream` (bool): If true, this is the final message on the stream.
*   **`DataStreamMessage`**: Represents a frame of binary data.
    *   `bytes` (List<int>): The raw payload bytes.
    *   `endStream` (bool): If true, this is the final message on the stream.

### Enums and Constants
*   **`ErrorCode`**: Standard HTTP/2 error codes used in `RST_STREAM` and `GOAWAY` frames.
    *   `NO_ERROR` (0): Graceful shutdown.
    *   `PROTOCOL_ERROR` (1): Protocol violation detected.
    *   `INTERNAL_ERROR` (2): Implementation error.
    *   `FLOW_CONTROL_ERROR` (3): Flow control window exceeded.
    *   `SETTINGS_TIMEOUT` (4): Settings ACK not received.
    *   `STREAM_CLOSED` (5): Frame received for closed stream.
    *   `FRAME_SIZE_ERROR` (6): Frame exceeds max size.
    *   `REFUSED_STREAM` (7): Stream rejected before processing.
    *   `CANCEL` (8): Stream no longer needed.
    *   `COMPRESSION_ERROR` (9): HPACK decoding failed.
    *   `CONNECT_ERROR` (10): Connection established but failed.
    *   `ENHANCE_YOUR_CALM` (11): Rate limiting or excessive resource use.
    *   `INADEQUATE_SECURITY` (12): TLS requirements not met.
    *   `HTTP_1_1_REQUIRED` (13): Peer requires downgrade to HTTP/1.1.

## 7. Related Modules
*   **`package:grpc-dart/grpc.dart`**: High-level gRPC library which uses this module.
*   **`dart:io`**: Provides `Socket` and `SecureSocket` for the underlying transport.
