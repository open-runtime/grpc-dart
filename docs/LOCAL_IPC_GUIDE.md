# Local IPC with gRPC: Many Clients, One Server

**Unix Domain Sockets (macOS/Linux) and Named Pipes (Windows)**

This guide covers how to run a single gRPC server with multiple local clients
using the fastest available IPC transport on each platform. No network stack,
no TLS overhead, no port conflicts.

---

## Quick Start

### Server (3 lines)

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  final server = LocalGrpcServer('myapp-grpc', services: [MyServiceImpl()]);
  await server.serve();
  print('Listening on ${server.address}');

  // ... later ...
  await server.shutdown();
}
```

### Client (3 lines)

```dart
import 'package:grpc/grpc.dart';

Future<void> main() async {
  final channel = LocalGrpcChannel('myapp-grpc');
  final stub = MyServiceClient(channel);
  final response = await stub.sayHello(HelloRequest(name: 'world'));
  print(response.message);
  await channel.shutdown();
}
```

`LocalGrpcServer` and `LocalGrpcChannel` automatically pick the best
transport per platform:
- **macOS/Linux**: Unix domain socket at `$XDG_RUNTIME_DIR/grpc-local/myapp-grpc.sock`
- **Windows**: Named pipe at `\\.\pipe\myapp-grpc`

Both transports speak HTTP/2. The protobuf contract, streaming semantics,
metadata, deadlines, and interceptors all work identically to TCP.

### Advanced Options

```dart
// Server with interceptors and message size limits
final server = LocalGrpcServer(
  'myapp-grpc',
  services: [MyServiceImpl()],
  serverInterceptors: [MyAuthInterceptor()],
  keepAliveOptions: ServerKeepAliveOptions(maxBadPings: 5),
  maxInboundMessageSize: 4 * 1024 * 1024, // 4 MB
);

// Client with custom timeouts
final channel = LocalGrpcChannel(
  'myapp-grpc',
  options: LocalChannelOptions(
    connectTimeout: Duration(seconds: 10),
    keepAlive: ClientKeepAliveOptions(
      pingInterval: Duration(seconds: 30),
      timeout: Duration(seconds: 10),
    ),
    maxInboundMessageSize: 4 * 1024 * 1024,
  ),
);
```

### Platform-Specific API (when you need full control)

If you need features that `LocalGrpcServer`/`LocalGrpcChannel` don't expose
(TLS over UDS, custom socket paths, multiple addresses), use the
platform-specific classes directly:

```dart
// Unix domain socket (macOS/Linux)
final server = Server.create(services: [MyServiceImpl()]);
await server.serve(
  address: InternetAddress('/custom/path.sock', type: InternetAddressType.unix),
  port: 0,
);
final channel = ClientChannel(
  InternetAddress('/custom/path.sock', type: InternetAddressType.unix),
  port: 0,
  options: ChannelOptions(credentials: ChannelCredentials.insecure()),
);

// Named pipe (Windows)
final pipeServer = NamedPipeServer.create(services: [MyServiceImpl()]);
await pipeServer.serve(pipeName: 'custom-pipe-name');
final pipeChannel = NamedPipeClientChannel('custom-pipe-name');
```

---

## How the Client and Server Find Each Other

There is no service discovery. The client and server agree on an address
at build time or via configuration.

### Unix Domain Sockets

The address is a **filesystem path**:

```
/tmp/myapp-grpc.sock
/var/run/myapp/grpc.sock
$XDG_RUNTIME_DIR/myapp-grpc.sock
```

The server creates the socket file when it calls `serve()`. The client
connects to the same path. If the path doesn't exist, the client gets
`SocketException: Connection refused`.

**Stale socket cleanup**: If the server crashes without cleaning up, the
socket file persists but nothing is listening. The next server start will
fail with "Address already in use" unless you delete the file first:

```dart
final socketFile = File(socketPath);
if (socketFile.existsSync()) socketFile.deleteSync();
```

### Named Pipes (Windows)

The address is a **pipe name** (not a filesystem path):

```
myapp-grpc          → server creates \\.\pipe\myapp-grpc
myapp-grpc-12345    → unique per-process instance
```

The server creates the pipe when it calls `serve(pipeName: ...)`. The
`NamedPipeServer.serve()` method returns only after the pipe exists in the
Windows kernel namespace — there is no race between serve and connect.

**No stale cleanup needed**: When the server process exits (even on crash),
Windows automatically destroys the pipe. Named pipes don't leave orphan
files.

### Choosing a Unique Name

For many-clients-one-server, use a well-known name:

```dart
const pipeName = 'myapp-grpc';
const socketPath = '/tmp/myapp-grpc.sock';
```

For one-client-one-server (e.g., per-plugin), embed a unique identifier:

```dart
final pipeName = 'myapp-plugin-${pid}';
final socketPath = '/tmp/myapp-plugin-${pid}.sock';
```

**Service name limit**: Service names must be 32 characters or fewer
(alphanumeric, hyphens, underscores, dots). This limit ensures the full UDS
socket path fits within the macOS 104-byte `sun_path` limit.

---

## Channel Options for Local IPC

Local IPC doesn't need TLS, proxy support, or aggressive reconnection.
Here are the recommended settings:

```dart
// Unix domain socket
final channel = ClientChannel(
  InternetAddress(socketPath, type: InternetAddressType.unix),
  port: 0,
  options: ChannelOptions(
    credentials: ChannelCredentials.insecure(), // No TLS needed
    idleTimeout: Duration(minutes: 5),          // Close idle connections
    connectTimeout: Duration(seconds: 5),       // Fail fast if server is down
    keepAlive: ClientKeepAliveOptions(
      pingInterval: Duration(seconds: 30),      // Detect dead connections
      timeout: Duration(seconds: 10),           // How long to wait for pong
      permitWithoutCalls: false,                // Don't ping when idle
    ),
  ),
);

// Named pipe — NamedPipeChannelOptions pre-sets insecure + no proxy
final channel = NamedPipeClientChannel(
  'myapp-grpc',
  options: NamedPipeChannelOptions(
    idleTimeout: Duration(minutes: 5),
    connectTimeout: Duration(seconds: 5),
    keepAlive: ClientKeepAliveOptions(
      pingInterval: Duration(seconds: 30),
      timeout: Duration(seconds: 10),
      permitWithoutCalls: false,
    ),
  ),
);
```

### Key Options Explained

| Option | Default | Recommendation | Why |
|--------|---------|----------------|-----|
| `credentials` | TLS | `insecure()` | Local IPC doesn't traverse a network |
| `idleTimeout` | 5 min | 5 min | Closes connections with no active RPCs |
| `connectTimeout` | none | 5s | Fail fast if server isn't running |
| `connectionTimeout` | 50 min | 50 min or less | Refreshes the HTTP/2 connection periodically |
| `keepAlive.pingInterval` | disabled | 30s | Detects dead server without waiting for an RPC to fail |
| `keepAlive.timeout` | 20s | 10s | Local pings should respond instantly |
| `keepAlive.permitWithoutCalls` | false | false | Don't waste resources pinging when idle |
| `maxInboundMessageSize` | unlimited | Set a limit | Prevents accidental OOM from malformed messages |
| `backoffStrategy` | exponential (1s-120s) | default | Reconnect delay after failure |

---

## How Failure Recovery Works

The gRPC client automatically reconnects after failures. You don't need to
manage connections yourself.

### Connection State Machine

```
                    ┌─────────────────────┐
                    │                     │
                    v                     │
   ┌──────┐    ┌────────────┐    ┌───────┴─┐
   │ idle │───>│ connecting │───>│  ready   │
   └──┬───┘    └─────┬──────┘    └────┬─────┘
      │              │                │
      │              v                │ (socket error,
      │        ┌───────────────┐      │  server crash,
      │        │  transient    │<─────┘  GOAWAY)
      │        │  failure      │
      │        └───────┬───────┘
      │                │
      │    (backoff timer fires)
      │                │
      │                v
      │         ┌────────────┐
      └────────>│ connecting │  (retry)
                └────────────┘
```

### What Happens When the Server Dies

1. **In-flight RPCs** receive `GrpcError` with status `UNAVAILABLE`
2. The connection moves to `transientFailure`
3. After a backoff delay (1s, 1.6s, 2.56s, ... up to 120s), the client
   retries the connection
4. New RPCs queued during reconnection are dispatched when the connection
   is re-established
5. If the server never comes back, pending RPCs eventually fail with
   `UNAVAILABLE`

### What Happens When the Server Restarts

1. The client detects the broken connection (via TCP RST, pipe EOF, or
   keepalive timeout)
2. Backoff timer fires, client reconnects
3. The new connection goes through a fresh HTTP/2 handshake
4. Pending RPCs are dispatched on the new connection
5. **No application code needed** — the channel handles this transparently

### What Happens During Graceful Server Shutdown

When the server calls `server.shutdown()`:

1. Server stops accepting new connections
2. Server sends GOAWAY to all connected clients
3. In-flight RPCs are cancelled (RST_STREAM)
4. The server waits up to 5 seconds for connections to drain
5. If connections don't drain, they are forcefully terminated
6. `shutdown()` future completes

The client sees:
- Streaming RPCs receive cancellation
- Unary RPCs in-flight receive `CANCELLED`
- New RPCs fail with `UNAVAILABLE` until reconnection

### Backoff Strategy

The default exponential backoff:

| Attempt | Delay (approx) |
|---------|----------------|
| 1 | 1.0s |
| 2 | 1.6s |
| 3 | 2.6s |
| 4 | 4.1s |
| 5 | 6.6s |
| ... | ... |
| max | 120s |

Each delay includes random jitter to prevent thundering herd when multiple
clients reconnect simultaneously.

Custom backoff:

```dart
ChannelOptions(
  backoffStrategy: (Duration? lastDelay) {
    if (lastDelay == null) return Duration(milliseconds: 100);
    return lastDelay * 2; // Simple doubling
  },
)
```

---

## Multiple Clients, One Server

### Architecture

```
  ┌──────────┐
  │ Client 1 │──┐
  └──────────┘  │
  ┌──────────┐  │    ┌────────┐
  │ Client 2 │──┼───>│ Server │
  └──────────┘  │    └────────┘
  ┌──────────┐  │    (UDS or named pipe)
  │ Client N │──┘
  └──────────┘
```

Each client creates its own `ClientChannel`. Each channel maintains one
HTTP/2 connection to the server. HTTP/2 multiplexes many concurrent RPCs
over that single connection.

### Server-Side Connection Tracking

Use `ServerInterceptor` to track per-connection state:

```dart
class ConnectionTracker extends ServerInterceptor {
  final _activeConnections = <String, int>{};

  @override
  Stream<R> intercept<Q, R>(
    ServiceCall call,
    ServiceMethod<Q, R> method,
    Stream<Q> requests,
    ServerStreamingInvoker<Q, R> invoker,
  ) {
    final clientId = call.clientMetadata?['x-client-id'] ?? 'unknown';
    _activeConnections.update(clientId, (v) => v + 1, ifAbsent: () => 1);

    return invoker(call, method, requests).handleError(
      (error) { /* handle */ },
      test: (_) {
        _activeConnections.update(clientId, (v) => v - 1);
        return false; // don't consume the error
      },
    );
  }
}

final server = Server.create(
  services: [MyServiceImpl()],
  serverInterceptors: [ConnectionTracker()],
);
```

### Client-Side: Reuse the Channel

Create **one channel per target server** and reuse it across your
application. Don't create a new channel per RPC.

```dart
// Good: one channel, many stubs
final channel = NamedPipeClientChannel('myapp-grpc');
final greeterStub = GreeterClient(channel);
final healthStub = HealthClient(channel);

// All stubs share the same HTTP/2 connection
await greeterStub.sayHello(request);
await healthStub.check(HealthCheckRequest());

// Bad: new channel per RPC (connection overhead)
for (final request in requests) {
  final ch = NamedPipeClientChannel('myapp-grpc'); // Don't do this
  final stub = GreeterClient(ch);
  await stub.sayHello(request);
  await ch.shutdown(); // Wasteful
}
```

---

## Message Size Limits

By default, there is no inbound message size limit. For production, set one
on both sides:

```dart
// Server
final server = Server.create(
  services: [MyServiceImpl()],
  maxInboundMessageSize: 4 * 1024 * 1024, // 4 MB
);

// Or for named pipes
final server = NamedPipeServer.create(
  services: [MyServiceImpl()],
  maxInboundMessageSize: 4 * 1024 * 1024,
);

// Client
final channel = ClientChannel(
  address,
  options: ChannelOptions(
    maxInboundMessageSize: 4 * 1024 * 1024,
    credentials: ChannelCredentials.insecure(),
  ),
);
```

Oversized messages are rejected with `GrpcError.resourceExhausted` before
the buffer is allocated — no OOM risk.

---

## Server Keepalive (Abuse Prevention)

The server can enforce ping behavior to prevent misbehaving clients:

```dart
final server = Server.create(
  services: [MyServiceImpl()],
  keepAliveOptions: ServerKeepAliveOptions(
    maxBadPings: 5,                                  // Tolerate 5 pings without data
    minIntervalBetweenPingsWithoutData: Duration(seconds: 10), // Min gap between pings
  ),
);
```

If a client sends too many pings without data, the server sends
`ENHANCE_YOUR_CALM` (HTTP/2 GOAWAY with error code 11) and closes the
connection.

---

## Platform Differences

| Feature | UDS (macOS/Linux) | Named Pipes (Windows) |
|---------|-------------------|----------------------|
| Address format | Filesystem path | Pipe name string |
| Stale cleanup | Manual (delete socket file) | Automatic (kernel cleanup) |
| Security | Filesystem permissions | `PIPE_REJECT_REMOTE_CLIENTS` |
| Max connections | OS file descriptor limit | `PIPE_UNLIMITED_INSTANCES` |
| Server architecture | Single process | Two-isolate (accept + I/O) |
| Read mechanism | Async socket I/O | Polling via `PeekNamedPipe` |
| Timer resolution | Sub-millisecond | ~15.6ms (Windows timer tick) |

### Named Pipe Polling

Named pipes on Windows don't support async I/O in the same way as sockets.
The server polls for data using `PeekNamedPipe` with an adaptive backoff:

- Active data: poll every ~1ms (quantized to Windows timer tick)
- Idle: backoff to 50ms polls
- Resets to 1ms on data receipt

This means named pipe latency has a floor of ~1 Windows timer tick
(~15.6ms) for the first byte of a new message after an idle period.

---

## Checklist for Production

- [ ] **Choose a stable, well-known address** — don't generate random names
      unless you have a discovery mechanism
- [ ] **Clean up stale UDS socket files** on server startup
- [ ] **Set `maxInboundMessageSize`** on both client and server
- [ ] **Set `connectTimeout`** on the client to fail fast
- [ ] **Use `ChannelCredentials.insecure()`** — TLS is unnecessary for
      same-machine IPC
- [ ] **Reuse channels** — one channel per server, shared across stubs
- [ ] **Handle `GrpcError`** in client code — `UNAVAILABLE` means the
      server is down, `CANCELLED` means the RPC was interrupted
- [ ] **Call `channel.shutdown()`** when done — prevents resource leaks
- [ ] **Call `server.shutdown()`** for graceful drain — don't just
      `exit()` the process
- [ ] **Set server keepalive options** if clients are untrusted
- [ ] **Test with concurrent clients** — verify your service handles
      parallel RPCs correctly
- [ ] **Monitor the connection state** if you need health reporting:
      ```dart
      channel.onConnectionStateChanged.listen((state) {
        print('Connection: $state');
      });
      ```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `SocketException: Connection refused` | Server not running, or wrong socket path | Verify server is up and paths match |
| `NamedPipeException: File not found` | Pipe doesn't exist yet | Ensure server `serve()` completes before client connects |
| `NamedPipeException: Pipe busy` | All pipe instances in use | Increase `maxInstances` or reduce concurrent connections |
| `GrpcError(UNAVAILABLE)` | Server crashed or network issue | Client will auto-reconnect; check server logs |
| `GrpcError(DEADLINE_EXCEEDED)` | RPC took too long | Increase deadline or optimize server handler |
| `GrpcError(RESOURCE_EXHAUSTED)` | Message too large | Increase `maxInboundMessageSize` or send smaller messages |
| `ENHANCE_YOUR_CALM` | Client sending too many pings | Increase `pingInterval` or server's `maxBadPings` |
| Stale `.sock` file | Previous server crashed | Delete the file before `serve()` |
| 15ms+ latency on Windows | Named pipe timer resolution | Expected; use TCP if sub-ms latency is critical |
