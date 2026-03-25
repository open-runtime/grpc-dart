# HTTP/2 API Reference

This document provides a comprehensive reference for the internal **Http2** module. This module provides a low-level HTTP/2 implementation used by the gRPC client and server.

## 1. Usage Examples

### Client Connection
```dart
import 'dart:io';
import 'package:grpc/grpc.dart';

Future<void> main() async {
  // 1. Establish a secure socket with ALPN 'h2'
  final socket = await SecureSocket.connect(
    'example.com',
    443,
    supportedProtocols: ['h2'],
  );

  // 2. Create a ClientTransportConnection
  final connection = ClientTransportConnection.viaSocket(socket);

  // 3. Prepare headers
  final headers = [
    Header.ascii(':method', 'GET'),
    Header.ascii(':path', '/'),
    Header.ascii(':scheme', 'https'),
    Header.ascii(':authority', 'example.com'),
  ];

  // 4. Make a request
  final stream = connection.makeRequest(headers, endStream: true);

  // 5. Listen for incoming messages
  stream.incomingMessages.listen((message) {
    if (message is HeadersStreamMessage) {
      for (var header in message.headers) {
        print('${header.name}: ${header.value}');
      }
    } else if (message is DataStreamMessage) {
      print('Received ${message.bytes.length} bytes');
    }
  }, onDone: () => print('Stream closed'));

  // 6. Gracefully shut down
  await connection.finish();
}
```

### Server Connection
```dart
import 'dart:io';
import 'package:grpc/grpc.dart';

Future<void> main() async {
  final server = await ServerSocket.bind('localhost', 8080);
  server.listen((socket) {
    // Create a ServerTransportConnection
    final connection = ServerTransportConnection.viaSocket(socket);

    // Listen for incoming streams
    connection.incomingStreams.listen((stream) {
      print('New incoming stream: ${stream.id}');

      stream.incomingMessages.listen((message) {
        if (message is HeadersStreamMessage) {
          // Send response headers
          stream.sendHeaders([Header.ascii(':status', '200')]);
          // Send response data
          stream.sendData([104, 101, 108, 108, 111], endStream: true);
        }
      });
    });
  });
}
```

## 2. Classes

### Transport Connections
- **TransportConnection** (Abstract) -- Represents a HTTP/2 connection.
  - **Fields:**
    - `onActiveStateChanged`: `ActiveStateHandler` - Callback invoked with `true` when the connection goes from idle to active, and `false` when it becomes idle.
    - `onInitialPeerSettingsReceived`: `Future<void>` - Completes when the first `SETTINGS` frame is received from the peer.
    - `onPingReceived`: `Stream<int>` - Stream emitting the ping ID every time a `PING` is received.
    - `onFrameReceived`: `Stream<void>` - Stream emitting an event every time a frame is received.
  - **Methods:**
    - `ping()`: `Future<void>` - Pings the other end.
    - `finish()`: `Future<void>` - Finishes the connection gracefully, preventing new streams.
    - `terminate([int? errorCode])`: `Future<void>` - Forcefully terminates the connection.

- **ClientTransportConnection** -- Represents a client-side HTTP/2 connection.
  - **Constructors:**
    - `factory ClientTransportConnection.viaSocket(Socket socket, {ClientSettings? settings})`
    - `factory ClientTransportConnection.viaStreams(Stream<List<int>> incoming, StreamSink<List<int>> outgoing, {ClientSettings? settings})`
  - **Fields:**
    - `isOpen`: `bool` - Whether the connection is open and can be used to make new requests.
  - **Methods:**
    - `makeRequest(List<Header> headers, {bool endStream = false})`: `ClientTransportStream` - Creates a new outgoing stream.

- **ServerTransportConnection** -- Represents a server-side HTTP/2 connection.
  - **Constructors:**
    - `factory ServerTransportConnection.viaSocket(Socket socket, {ServerSettings? settings})`
    - `factory ServerTransportConnection.viaStreams(Stream<List<int>> incoming, StreamSink<List<int>> outgoing, {ServerSettings? settings})`
  - **Fields:**
    - `incomingStreams`: `Stream<ServerTransportStream>` - Stream of incoming HTTP/2 streams initiated by the client.

### Settings
- **Settings** (Abstract) -- Base settings for a `TransportConnection`.
  - **Fields:**
    - `concurrentStreamLimit`: `int?` - The maximum number of concurrent streams the remote end can open.
    - `streamWindowSize`: `int?` - The default stream window size (defaults to 65535 bytes).

- **ClientSettings** -- Settings for a client connection.
  - **Fields:**
    - `allowServerPushes`: `bool` - Whether the client allows pushes from the server (defaults to `false`).

- **ServerSettings** -- Settings for a server connection.

- **ActiveSettings** -- The settings currently in effect for a connection.
  - **Fields:**
    - `headerTableSize`: `int` - Maximum size of the header compression table (initial: 4096).
    - `enablePush`: `bool` - Whether server push is permitted.
    - `maxConcurrentStreams`: `int?` - Maximum number of concurrent streams allowed.
    - `initialWindowSize`: `int` - Initial window size for stream-level flow control (initial: 65535).
    - `maxFrameSize`: `int` - Largest frame payload the sender is willing to receive (initial: 16384).
    - `maxHeaderListSize`: `int?` - Maximum size of header list prepared to be accepted.

### Streams
- **TransportStream** (Abstract) -- Represents a HTTP/2 stream.
  - **Fields:**
    - `id`: `int` - The ID of this stream (odd for client-initiated, even for server-initiated).
    - `incomingMessages`: `Stream<StreamMessage>` - Stream of data and/or headers from the remote end.
    - `outgoingMessages`: `StreamSink<StreamMessage>` - Sink for writing data and/or headers to the remote end.
    - `onTerminated`: `void Function(int?)` - Sets the termination handler, called if an `RST_STREAM` frame is received.
  - **Methods:**
    - `terminate()`: `void` - Forcefully terminates the stream.
    - `sendHeaders(List<Header> headers, {bool endStream = false})`: `void` - Helper to send a `HeadersStreamMessage`.
    - `sendData(List<int> bytes, {bool endStream = false})`: `void` - Helper to send a `DataStreamMessage`.

- **ClientTransportStream** -- Client-side view of a HTTP/2 stream.
  - **Fields:**
    - `peerPushes`: `Stream<TransportStreamPush>` - Streams pushed by the server in response to this stream.

- **ServerTransportStream** -- Server-side view of a HTTP/2 stream.
  - **Fields:**
    - `canPush`: `bool` - Whether a `push()` call will succeed.
  - **Methods:**
    - `push(List<Header> requestHeaders)`: `ServerTransportStream` - Pushes a new stream to the client.

### Stream Messages
- **StreamMessage** (Abstract) -- Base class for messages sent over a stream.
  - **Fields:**
    - `endStream`: `bool` - Whether this is the final message in the stream.

- **DataStreamMessage** -- A message containing data bytes.
  - **Fields:**
    - `bytes`: `List<int>` - The data payload.

- **HeadersStreamMessage** -- A message containing HTTP/2 headers.
  - **Fields:**
    - `headers`: `List<Header>` - The list of headers.

- **TransportStreamPush** -- Represents a server push.
  - **Fields:**
    - `requestHeaders`: `List<Header>` - The synthetic request headers for the pushed stream.
    - `stream`: `ClientTransportStream` - The pushed stream itself.

### HPACK & Huffman Compression
- **HPackContext** -- Context for encoding and decoding HPACK headers.
  - **Fields:**
    - `encoder`: `HPackEncoder`
    - `decoder`: `HPackDecoder`

- **Header** -- Represents a single HTTP/2 header.
  - **Constructors:**
    - `factory Header.ascii(String name, String value)` - Creates a header from ASCII strings.
  - **Fields:**
    - `name`: `List<int>` - The header name.
    - `value`: `List<int>` - The header value.
    - `neverIndexed`: `bool` - Whether this header should never be indexed by HPACK.

- **HuffmanCodec** -- Codec for Huffman encoding/decoding.
  - **Methods:**
    - `decode(List<int> bytes)`: `List<int>`
    - `encode(List<int> bytes)`: `List<int>`

## 3. Enums and Constants

### StreamState
Represents the current lifecycle state of a HTTP/2 stream.
- `Idle`: Stream is not yet started.
- `ReservedLocal`: Stream reserved by local `PUSH_PROMISE`.
- `ReservedRemote`: Stream reserved by remote `PUSH_PROMISE`.
- `Open`: Stream is fully open and can send/receive frames.
- `HalfClosedLocal`: Local side has finished sending (sent `END_STREAM`).
- `HalfClosedRemote`: Remote side has finished sending (received `END_STREAM`).
- `Closed`: Stream is finished normally.
- `Terminated`: Stream was forcefully terminated (e.g., via `RST_STREAM`).

### ErrorCode
Standard HTTP/2 error codes used in `RST_STREAM` and `GOAWAY` frames.
- `NO_ERROR` (0x0): Graceful shutdown.
- `PROTOCOL_ERROR` (0x1): Protocol error detected.
- `INTERNAL_ERROR` (0x2): Implementation internal error.
- `FLOW_CONTROL_ERROR` (0x3): Flow control window exceeded.
- `SETTINGS_TIMEOUT` (0x4): Settings not acknowledged in time.
- `STREAM_CLOSED` (0x5): Frame received for a closed stream.
- `FRAME_SIZE_ERROR` (0x6): Frame size exceeds `MAX_FRAME_SIZE`.
- `REFUSED_STREAM` (0x7): Stream refused before processing.
- `CANCEL` (0x8): Stream no longer needed.
- `COMPRESSION_ERROR` (0x9): HPACK compression error.
- `CONNECT_ERROR` (0xa): Connection error during proxy/tunneling.
- `ENHANCE_YOUR_CALM` (0xb): Rate limit or resource exhaustion.
- `INADEQUATE_SECURITY` (0xc): Transport security requirements not met.
- `HTTP_1_1_REQUIRED` (0xd): HTTP/1.1 required.

### FrameType
Constants for HTTP/2 frame types.
- `DATA` (0x0)
- `HEADERS` (0x1)
- `PRIORITY` (0x2)
- `RST_STREAM` (0x3)
- `SETTINGS` (0x4)
- `PUSH_PROMISE` (0x5)
- `PING` (0x6)
- `GOAWAY` (0x7)
- `WINDOW_UPDATE` (0x8)
- `CONTINUATION` (0x9)

### Top-Level Constants
- `CONNECTION_PREFACE`: `List<int>` - The HTTP/2 connection preface (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`).
- `http2HuffmanCodec`: `HuffmanCodec` - The default Huffman codec for HTTP/2.
- `EOS_BYTE`: `int` - (256) The Huffman symbol for end-of-string.
- `FRAME_HEADER_SIZE`: `int` - (9) Size of a standard HTTP/2 frame header in bytes.

## 4. Top-Level Functions

- `viewOrSublist(List<int> data, int offset, int length)` -> `List<int>`
  - Efficiently extracts a sub-section of data, returning a view if possible.

- `readInt64`, `readInt32`, `readInt24`, `readInt16`
  - Helper functions for reading big-endian integers from byte lists.

- `setInt64`, `setInt32`, `setInt24`, `setInt16`
  - Helper functions for writing big-endian integers to byte lists.

- `readConnectionPreface(Stream<List<int>> incoming)` -> `Stream<List<int>>`
  - Verifies and strips the connection preface from an incoming byte stream.

## 6. Internal API Reference

This section covers low-level classes used internally by the HTTP/2 implementation. Most users should prefer the high-level `TransportConnection` and `TransportStream` interfaces.

### Connections & Handlers
- **Connection** (Internal Abstract) -- Base implementation for HTTP/2 connections.
  - **Fields:** `acknowledgedSettings`, `peerSettings`, `isClientConnection`, `onActiveStateChanged`.
- **StreamHandler** -- Manages multiple HTTP/2 streams over a single connection.
  - **Fields:** `highestPeerInitiatedStream`, `isServer`, `ranOutOfStreamIds`, `canOpenStream`, `incomingStreams`, `openStreams`.
- **SettingsHandler** -- Processes local and remote settings changes.
  - **Methods:** `handleSettingsFrame(SettingsFrame frame)`, `changeSettings(List<Setting> changes)`.
- **PingHandler** -- Manages outgoing pings and incoming ping ACKs.
- **FrameReader** / **FrameWriter** -- Low-level classes for decoding/encoding HTTP/2 frames.
- **FrameDefragmenter** -- Handles reassembly of fragmented `HEADERS` and `PUSH_PROMISE` frames.

### Flow Control & Queues
- **Window** -- Tracks a single flow control window.
  - **Fields:** `size`.
- **IncomingWindowHandler** -- Manages the local flow control window.
- **OutgoingStreamWindowHandler** -- Manages the remote flow control window for a stream.
- **ConnectionMessageQueueIn** / **ConnectionMessageQueueOut** -- Multiplexes messages between the connection and individual streams.
- **StreamMessageQueueIn** / **StreamMessageQueueOut** -- Buffers messages for a specific stream.

### Low-Level Frames
- **FrameHeader** -- The 9-byte header present on all HTTP/2 frames.
  - **Fields:** `length`, `type`, `flags`, `streamId`.
- **DataFrame** -- Carries variable-length sequences of octets associated with a stream.
- **HeadersFrame** -- Used to open a stream and carries header block fragments.
- **PriorityFrame** -- (Deprecated/Internal) Specifies the sender-advised priority of a stream.
- **RstStreamFrame** -- Allows for immediate termination of a stream.
- **SettingsFrame** -- Conveys configuration parameters that affect how endpoints communicate.
- **PushPromiseFrame** -- Notifies the peer in advance of streams the sender intends to initiate.
- **PingFrame** -- Mechanism for measuring a minimal round-trip time.
- **GoawayFrame** -- Used to initiate shutdown of a connection or to signal serious errors.
- **WindowUpdateFrame** -- Used to implement flow control.

### HPACK Internals
- **HPackEncoder** / **HPackDecoder** -- Stateful HPACK compression/decompression logic.
- **IndexTable** -- The static and dynamic tables used for header compression.

### Utilities & Mixins
- **BufferIndicator** -- Signals when a stream or sink is ready to accept more data without excessive buffering.
- **BufferedBytesWriter** -- Batches byte writes for efficiency.
- **TerminatableMixin** -- Shared logic for objects that can be forcefully closed.
- **ClosableMixin** -- Shared logic for objects that support graceful shutdown.
- **CancellableMixin** -- Shared logic for objects that support cancellation.

## 7. Exceptions
- `TransportException`: Base class for all HTTP/2 exceptions.
- `TransportConnectionException`: Exception related to connection-level errors.
- `StreamTransportException`: Exception related to stream-level errors.
- `ProtocolException`: Raised when a protocol violation is detected.
- `FlowControlException`: Raised when flow control limits are violated.
- `FrameSizeException`: Raised when a frame size error occurs.
- `TerminatedException`: Raised when an operation is attempted on a terminated connection.
- `StreamException`: Base class for stream-specific errors.
- `StreamClosedException`: Raised when an operation is attempted on a closed stream.
- `HPackDecodingException`: Raised during HPACK header decompression.
- `HuffmanDecodingException`: Raised during Huffman decompression.