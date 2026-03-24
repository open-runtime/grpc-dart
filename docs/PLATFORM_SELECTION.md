# gRPC-Dart Platform Selection Logic

This document describes **all** platform checks and transport selection logic in the grpc-dart package. The package uses a mix of **compile-time conditional imports** and **runtime `Platform` checks** to select the appropriate transport per target.

---

## Summary: No `kIsWeb` or `Platform.isLinux`/`Platform.isMacOS` for Transport Choice

The package does **not** use `kIsWeb` (from `package:flutter/foundation.dart`). Web vs native is determined entirely by **conditional imports** (`dart.library.js_interop`, `dart.library.ffi`). Runtime `Platform` checks are used only for **local IPC** (Unix domain sockets vs named pipes) and for **UDS directory path selection** on Linux vs macOS.

---

## 1. Explicit Platform Checks

### 1.1 `Platform.isWindows` — Local IPC Transport Selection

| File | Line(s) | Purpose |
|------|--------|---------|
| `lib/src/client/local_channel.dart` | 100 | In `LocalGrpcChannel` factory: choose `NamedPipeClientChannel` (Windows) vs `ClientChannel` with UDS (macOS/Linux) |
| `lib/src/server/local_server.dart` | 119 | In `LocalGrpcServer.serve()`: choose `NamedPipeServer` (Windows) vs `Server` with UDS (macOS/Linux) |

**Logic:**

```dart
// local_channel.dart
if (Platform.isWindows) {
  delegate = NamedPipeClientChannel(serviceName, ...);
} else {
  delegate = http2.ClientChannel(
    InternetAddress(udsSocketPath(serviceName), type: InternetAddressType.unix),
    port: 0,
    ...
  );
}

// local_server.dart
if (Platform.isWindows) {
  final pipe = NamedPipeServer.create(...);
  await pipe.serve(pipeName: serviceName);
  _delegate = pipe;
} else {
  final socketPath = udsSocketPath(serviceName);
  final server = Server.create(...);
  await server.serve(address: InternetAddress(socketPath, type: InternetAddressType.unix), port: 0);
  _delegate = server;
}
```

### 1.2 `Platform.isLinux` and `Platform.isMacOS` — UDS Directory Path

| File | Line(s) | Purpose |
|------|--------|---------|
| `lib/src/shared/local_ipc.dart` | 30–42 | In `defaultUdsDirectory()`: choose base directory for Unix domain socket files |

**Logic:**

```dart
String defaultUdsDirectory() {
  if (Platform.isLinux) {
    final xdgRuntime = Platform.environment['XDG_RUNTIME_DIR'];
    if (xdgRuntime != null && xdgRuntime.isNotEmpty) {
      return '$xdgRuntime/grpc-local';
    }
  }
  if (Platform.isMacOS) {
    final tmpDir = Platform.environment['TMPDIR'];
    if (tmpDir != null && tmpDir.isNotEmpty) {
      final base = tmpDir.endsWith('/') ? tmpDir.substring(0, tmpDir.length - 1) : tmpDir;
      return '$base/grpc-local';
    }
  }
  return '/tmp/grpc-local';  // Fallback (Linux without XDG, macOS without TMPDIR, etc.)
}
```

- **Linux**: Prefer `$XDG_RUNTIME_DIR/grpc-local` (tmpfs, cleaned on logout)
- **macOS**: Prefer `$TMPDIR/grpc-local` (per-user temp)
- **Fallback**: `/tmp/grpc-local`

---

## 2. Conditional Imports (Compile-Time Selection)

These use `if (dart.library.xxx)` to select implementations at compile time. No runtime platform checks.

### 2.1 `dart.library.js_interop` — Web vs Native

| File | Condition | When true (web) | When false (native) |
|------|-----------|-----------------|----------------------|
| `lib/grpc_or_grpcweb.dart` | `if (dart.library.js_interop)` | `grpc_or_grpcweb_channel_web.dart` → `GrpcWebClientChannel` (XHR) | `grpc_or_grpcweb_channel_grpc.dart` → `ClientChannel` (HTTP/2 TCP) |
| `lib/src/shared/io_bits/io_bits.dart` | `if (dart.library.js_interop)` | `io_bits_web.dart` | `io_bits_io.dart` |
| `lib/src/shared/codec.dart` | `if (dart.library.js_interop)` | `codec/codec_web.dart` | `codec/codec_io.dart` |
| `lib/src/shared/logging/logging.dart` | `if (dart.library.js_interop)` | `logging_web.dart` | `logging_io.dart` |

**GrpcOrGrpcWebClientChannel** is the main factory-like entry point:

- **Web** (`dart.library.js_interop` true): Uses `GrpcWebClientChannel` with XHR transport (`XhrClientConnection`).
- **Native** (`dart.library.js_interop` false): Uses `ClientChannel` with HTTP/2 over TCP (`SocketTransportConnector` → `Http2ClientConnection`).

### 2.2 `dart.library.ffi` — Named Pipes (Windows) vs Stub

| File | Condition | When true (FFI available) | When false (e.g. web) |
|------|-----------|----------------------------|------------------------|
| `lib/grpc.dart` | `if (dart.library.ffi)` | `named_pipe_channel.dart` | `named_pipe_channel_stub.dart` (throws `UnsupportedError`) |
| `lib/grpc.dart` | `if (dart.library.ffi)` | `named_pipe_transport.dart` | `named_pipe_transport_stub.dart` |
| `lib/grpc.dart` | `if (dart.library.ffi)` | `named_pipe_server.dart` | `named_pipe_server_stub.dart` |
| `lib/src/client/local_channel.dart` | `if (dart.library.ffi)` | `named_pipe_channel.dart` | `named_pipe_channel_stub.dart` |
| `lib/src/server/local_server.dart` | `if (dart.library.ffi)` | `named_pipe_server.dart` | `named_pipe_server_stub.dart` |

On platforms without FFI (e.g. web), named pipe types are stubs that throw `UnsupportedError`. `LocalGrpcChannel` and `LocalGrpcServer` are not intended for web; they use `dart:io` and thus are not compiled for web targets.

---

## 3. Transport Selection Flow

### 3.1 Client Channel Types

| Channel Type | Selection | Transport |
|--------------|-----------|-----------|
| `GrpcOrGrpcWebClientChannel` | Conditional import (`dart.library.js_interop`) | Web: XHR; Native: HTTP/2 TCP |
| `ClientChannel` | Direct use | HTTP/2 TCP via `SocketTransportConnector` |
| `ClientTransportConnectorChannel` | Direct use | Pluggable `ClientTransportConnector` |
| `LocalGrpcChannel` | Runtime `Platform.isWindows` | Windows: `NamedPipeTransportConnector`; else: `SocketTransportConnector` (UDS) |
| `NamedPipeClientChannel` | Conditional import (`dart.library.ffi`) | `NamedPipeTransportConnector` (Windows only) |
| `GrpcWebClientChannel` | Direct use (web) | XHR via `XhrClientConnection` |

### 3.2 Client Transport Connectors

| Connector | Used By | Platform |
|-----------|---------|----------|
| `SocketTransportConnector` | `ClientChannel`, `LocalGrpcChannel` (non-Windows) | Native (dart:io) |
| `NamedPipeTransportConnector` | `NamedPipeClientChannel`, `LocalGrpcChannel` (Windows) | Windows (dart:ffi) |
| `XhrClientConnection` (not a connector) | `GrpcWebClientChannel` | Web |

### 3.3 Server Types

| Server Type | Selection | Transport |
|-------------|-----------|-----------|
| `Server` | Direct use | TCP or UDS via `dart:io` |
| `LocalGrpcServer` | Runtime `Platform.isWindows` | Windows: `NamedPipeServer`; else: `Server` (UDS) |
| `NamedPipeServer` | Conditional import (`dart.library.ffi`) | Windows named pipes |

---

## 4. Decision Diagram

```
User creates channel
        │
        ├─ GrpcOrGrpcWebClientChannel
        │       │
        │       ├─ dart.library.js_interop? ──► Web: GrpcWebClientChannel (XHR)
        │       └─ else ────────────────────► Native: ClientChannel (TCP)
        │
        ├─ LocalGrpcChannel
        │       │
        │       ├─ Platform.isWindows? ────► NamedPipeClientChannel (named pipe)
        │       └─ else ────────────────────► ClientChannel (UDS)
        │
        ├─ ClientChannel(host, port)
        │       └─ SocketTransportConnector (TCP or UDS if host is InternetAddress.unix)
        │
        └─ NamedPipeClientChannel(pipeName)
                └─ NamedPipeTransportConnector (Windows; stub on web)
```

---

## 5. Files Reference

| File | Platform Logic |
|------|----------------|
| `lib/grpc.dart` | Conditional exports: named pipe channel/transport/server (`dart.library.ffi`) |
| `lib/grpc_or_grpcweb.dart` | Conditional import: grpc vs grpc-web channel (`dart.library.js_interop`) |
| `lib/src/client/grpc_or_grpcweb_channel_grpc.dart` | Native: extends `ClientChannel` |
| `lib/src/client/grpc_or_grpcweb_channel_web.dart` | Web: extends `GrpcWebClientChannel` |
| `lib/src/client/local_channel.dart` | `Platform.isWindows` + conditional named pipe import |
| `lib/src/client/http2_channel.dart` | Uses `SocketTransportConnector` for TCP/UDS |
| `lib/src/client/http2_connection.dart` | Defines `SocketTransportConnector`; accepts any `ClientTransportConnector` |
| `lib/src/client/named_pipe_channel.dart` | Windows named pipe client (FFI) |
| `lib/src/client/named_pipe_channel_stub.dart` | Stub for non-FFI platforms |
| `lib/src/client/named_pipe_transport.dart` | `NamedPipeTransportConnector` (FFI) |
| `lib/src/client/web_channel.dart` | `GrpcWebClientChannel` with XHR |
| `lib/src/server/local_server.dart` | `Platform.isWindows` + conditional named pipe import |
| `lib/src/server/named_pipe_server.dart` | Windows named pipe server (FFI) |
| `lib/src/server/named_pipe_server_stub.dart` | Stub for non-FFI platforms |
| `lib/src/shared/local_ipc.dart` | `Platform.isLinux`, `Platform.isMacOS` for UDS directory |
| `lib/src/shared/io_bits/io_bits.dart` | `dart.library.js_interop` for io vs web |
| `lib/src/shared/codec.dart` | `dart.library.js_interop` for codec |
| `lib/src/shared/logging/logging.dart` | `dart.library.js_interop` for logging |

---

## 6. No `kIsWeb` Usage

The package does **not** import `package:flutter/foundation.dart` or use `kIsWeb`. Web detection is done via `dart.library.js_interop`, which is the standard approach for non-Flutter Dart packages.
