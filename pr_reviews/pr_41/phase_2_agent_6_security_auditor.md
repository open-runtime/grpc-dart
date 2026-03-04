# Phase 2 — Agent 6: Security Auditor

## Security Findings

### [SEC-1] Named Pipe Created with NULL SECURITY_ATTRIBUTES — Any Local User Can Connect
**Category:** Access Control
**Severity:** HIGH
**File:** `lib/src/server/named_pipe_server.dart:966-974`
**Description:**
The `CreateNamedPipe` call passes `nullptr` as the `lpSecurityAttributes` parameter:
```dart
final hPipe = CreateNamedPipe(
  pipePathPtr,
  PIPE_ACCESS_DUPLEX,
  PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
  config.maxInstances,
  kNamedPipeBufferSize,
  kNamedPipeBufferSize,
  0, // Default timeout
  nullptr, // Default security  <-- HERE
);
```
When `lpSecurityAttributes` is NULL, Windows applies the default DACL from the creating process's access token. On a default Windows installation, this grants `GENERIC_ALL` to `BUILTIN\Administrators` and the creator owner. However, depending on the security context of the process (e.g., a service running as LocalSystem, or a process with a modified default DACL), the effective permissions can be broader than intended. Any local user with matching ACL permissions can connect, read all gRPC traffic, and send arbitrary gRPC requests.

**Attack Scenario:**
On a multi-user Windows system where the server runs as a privileged account (e.g., LocalSystem service or an account with a permissive default DACL), a lower-privileged local user can open `\\.\pipe\{pipeName}` via `CreateFile` and establish a full duplex gRPC channel. The attacker can then invoke any service method the server exposes. Since named pipe names live in a global namespace, the attacker only needs to know or guess the pipe name.

**Recommendation:**
Construct explicit `SECURITY_ATTRIBUTES` with a restrictive DACL. At minimum, grant access only to the current user SID and `BUILTIN\Administrators`. Expose a configuration option in `NamedPipeServer.serve()` for callers to supply a custom `SECURITY_DESCRIPTOR` or a set of allowed SIDs. The gRPC C++ implementation provides `GRPC_ARG_SECURITY_DESCRIPTOR` for exactly this purpose.

---

### [SEC-2] No Pipe Name Validation — Potential Namespace Collision and Squatting
**Category:** Input Validation
**Severity:** MEDIUM
**File:** `lib/src/shared/named_pipe_io.dart:23`, `lib/src/server/named_pipe_server.dart:170`
**Description:**
The `namedPipePath` function performs simple string concatenation without any validation:
```dart
String namedPipePath(String pipeName) => r'\\.\pipe\' + pipeName;
```
The `serve()` method accepts the pipe name directly with no sanitization:
```dart
Future<void> serve({required String pipeName, ...}) async {
```
There is no check for:
- Empty strings
- Names containing backslashes (which would create sub-paths in the pipe namespace)
- Names containing null bytes (which could truncate the native UTF-16 string via `toNativeUtf16`)
- Excessively long names (Windows pipe names have a 256-character limit)
- Reserved names that could conflict with system pipes

**Attack Scenario:**
If an application constructs pipe names from user-controlled input (e.g., session ID, username), an attacker could inject backslash characters to target a different namespace path. A null byte in the name would truncate the native string, potentially connecting to an unintended pipe. More practically, an attacker who starts their own malicious server first (pipe squatting) on a predictable name can impersonate the real server.

**Recommendation:**
Add validation in `namedPipePath()` or `serve()` that rejects:
- Empty pipe names
- Names containing `\`, `/`, or null bytes
- Names exceeding 256 characters total path length
- Consider recommending or enforcing pipe names with random suffixes (e.g., PID + random token) to prevent squatting

---

### [SEC-3] Error Messages Expose Internal State to Clients via gRPC Status
**Category:** Information Disclosure
**Severity:** MEDIUM
**File:** `lib/src/server/handler.dart:259,367,400`
**Description:**
Several error paths include raw exception messages in gRPC error responses sent to clients:
```dart
// Line 259:
_sendError(GrpcError.internal('Error processing request: $error'));

// Line 367:
final grpcError = GrpcError.internal('Error deserializing request: $error');

// Line 400:
final grpcError = GrpcError.internal('Error sending response: $error');
```
The `$error` interpolation includes the full `toString()` of the caught exception, which may contain stack traces, file paths, class names, package versions, or other implementation details. These are sent to the client as the `grpc-message` trailer.

**Attack Scenario:**
A malicious client sends a crafted request (e.g., a malformed protobuf payload) that triggers a deserialization error. The error response includes the full exception message, revealing internal Dart types, package versions, and potentially file paths. This information helps an attacker fingerprint the server, identify specific library versions with known vulnerabilities, and craft targeted attacks.

**Recommendation:**
Replace raw exception interpolation in client-facing error messages with generic descriptions. Log the full details server-side via `logGrpcEvent` (which this PR already uses extensively) but send only sanitized messages to clients:
```dart
// Instead of:
GrpcError.internal('Error deserializing request: $error')
// Use:
GrpcError.internal('Failed to deserialize request')
// And log the full details:
logGrpcEvent('[gRPC] Deserialization error: $error', ...);
```

---

### [SEC-4] ENHANCE_YOUR_CALM Does Not Clean Up Connection From Server Tracking
**Category:** DoS / Resource Exhaustion
**Severity:** MEDIUM
**File:** `lib/src/server/server.dart:152-157`, `lib/src/server/server_keepalive.dart:110-112`
**Description:**
When `tooManyBadPings` triggers, it calls `connection.terminate(ErrorCode.ENHANCE_YOUR_CALM)`. However, `terminate()` on the http2 `ServerTransportConnection` sends a GOAWAY frame and closes the transport, but the connection cleanup in `serveConnection()` depends on the `incomingStreams` subscription's `onDone` or `onError` callback firing. If `terminate()` does not trigger stream closure in all edge cases (e.g., the transport is already half-closed), the connection may linger in `_connections` and `handlers` maps.

The `_tooManyBadPingsTriggered` flag prevents duplicate `terminate()` calls, which is good. But the ping listener (`pingNotifier.listen`) continues to run after terminate, consuming CPU on further pings from a misbehaving client until the OS-level connection actually closes.

**Attack Scenario:**
A malicious client floods pings, triggers ENHANCE_YOUR_CALM, but keeps the TCP connection half-open. The ping listener continues processing incoming pings (incrementing `_badPings` uselessly). If `terminate()` does not fully close the connection, the server retains the connection in memory. Repeat across many connections to accumulate leaked resources.

**Recommendation:**
Cancel the keepalive subscriptions (both `pingNotifier` and `dataNotifier`) when `tooManyBadPings` fires. Consider adding the `onDataReceivedController.close()` call inside the `tooManyBadPings` callback or the keepalive manager itself. Verify that `connection.terminate()` reliably triggers the `onDone` path in `serveConnection()` under all conditions.

---

### [SEC-5] Unbounded Server-Side Pipe Instance Creation (PIPE_UNLIMITED_INSTANCES Default)
**Category:** DoS / Resource Exhaustion
**Severity:** MEDIUM
**File:** `lib/src/server/named_pipe_server.dart:170,966-970`
**Description:**
The `serve()` method defaults to `PIPE_UNLIMITED_INSTANCES`:
```dart
Future<void> serve({required String pipeName, int maxInstances = PIPE_UNLIMITED_INSTANCES}) async {
```
Each client connection consumes a pipe instance, a 64KB read buffer, a 64KB write buffer (in the OS kernel), plus Dart-side allocations (StreamControllers, HTTP/2 connection state). With unlimited instances, a local attacker can open connections as fast as the server creates new pipe instances.

The accept loop creates a new pipe instance for every connection (line 966). The accept-loop isolate polls with 1ms delays between iterations, so the maximum accept rate is ~1000 connections/second. Each connection has at minimum 128KB of kernel buffer plus Dart heap overhead.

**Attack Scenario:**
A local attacker script opens `CreateFile` connections in a tight loop, consuming kernel memory (128KB per connection) and Dart heap (StreamController, HTTP/2 connection, handler tracking). At 1000 connections/second, the attacker accumulates ~128MB/s of kernel buffer allocations. Without connection limits or rate limiting, this exhausts system memory within minutes on a typical machine.

**Recommendation:**
- Default `maxInstances` to a sensible bounded value (e.g., 64 or 128) instead of `PIPE_UNLIMITED_INSTANCES`
- Add a configurable maximum concurrent connection limit in `ConnectionServer` that rejects new connections (via `DisconnectNamedPipe` + `CloseHandle`) when the limit is reached
- Consider a per-source rate limiter, though this is harder with named pipes since client identity requires `GetNamedPipeClientProcessId`

---

### [SEC-6] Isolate Message Channel Has No Type-Safe Validation
**Category:** Input Validation / Isolate Trust Boundary
**Severity:** LOW
**File:** `lib/src/server/named_pipe_server.dart:251-278`
**Description:**
The main isolate's message handler performs type checks via `is` but does not validate message contents:
```dart
void _handleIsolateMessage(dynamic message) {
  if (message is _ServerReady) { ... }
  else if (message is _PipeHandle) {
    if (_isRunning) {
      _handleNewConnection(message.handle);
    } else {
      DisconnectNamedPipe(message.handle);
      CloseHandle(message.handle);
    }
  } else if (message is _ServerError) { ... }
}
```
The `_PipeHandle.handle` is an `int` that is used directly as a Win32 handle. There is no validation that the handle value is within a valid range (non-zero, non-negative, not `INVALID_HANDLE_VALUE`). If the accept-loop isolate were compromised or sent a malformed message, an arbitrary integer would be passed to `ReadFile`/`WriteFile`/`CloseHandle`.

In practice, the accept loop isolate is spawned by the same process with `Isolate.spawn()`, and Dart's SendPort only accepts the message types that the accept loop actually sends. The `_PipeHandle`, `_ServerReady`, and `_ServerError` classes are private, so external code cannot construct them. The risk is therefore theoretical unless the isolate's memory is corrupted.

**Attack Scenario:**
If the accept-loop isolate's memory is corrupted (e.g., via an FFI bug), a crafted `_PipeHandle` with an arbitrary integer could cause `ReadFile`/`WriteFile` to operate on an unrelated handle (e.g., a file, registry key, or another pipe). However, Win32 handles are validated by the kernel, so invalid handles return errors rather than causing memory corruption. The practical impact is limited to operating on wrong resources within the same process.

**Recommendation:**
Add a validation check in `_handleNewConnection`:
```dart
if (hPipe == 0 || hPipe == INVALID_HANDLE_VALUE) {
  logGrpcEvent('Invalid pipe handle received from accept loop', ...);
  return;
}
```
This is defense-in-depth with minimal cost.

---

### [SEC-7] Shutdown Grace Period Allows 12+ Seconds of Continued Client Data Processing
**Category:** Shutdown Safety / DoS
**Severity:** LOW
**File:** `lib/src/server/server.dart:207-252,284-321`
**Description:**
The `shutdownActiveConnections()` method has multiple sequential timeout stages:
1. Cancel incoming subscriptions: 5s timeout
2. Wait for response cancel futures: 5s timeout
3. Finish each connection: 5s grace then 2s terminate timeout

Total worst-case: 5s + 5s + 5s + 2s = **17 seconds** before a single stubborn connection is fully terminated.

During stages 1-2, if timeout fires, the code returns `<void>[]` (treated as success) and proceeds. This means the subscription and response cancellation may not have actually completed, but shutdown continues. A connection that is actively receiving data may continue processing during this window.

The `_finishConnection` method uses `Timer` instead of `Future.timeout()` specifically because the event loop may be saturated. This is a sound defensive measure. However, the raw socket (`_connectionSockets[connection]?.destroy()`) is only called inside `forceTerminate()`, which runs after the 5s finish deadline. During those 5 seconds, a flooding client continues pumping data frames into the server.

**Attack Scenario:**
A client that is performing a server-side streaming RPC can continue sending data frames for up to 17 seconds after `shutdown()` is called. While the incoming subscription is *cancelled* in Step 1, the http2 FrameReader's socket subscription (which has a known missing `onCancel` handler per the code comments) continues processing raw TCP data. This is mitigated by the raw socket destroy in Step 4, but the delay allows a window for resource consumption.

**Recommendation:**
Consider destroying raw sockets immediately in Step 1 (alongside cancelling incoming subscriptions) for the most aggressive shutdown path. Alternatively, add a `forceShutdown()` method that skips grace periods for production emergencies. The current graduated approach is reasonable for normal shutdown, but a hard-kill path should be available.

---

### [SEC-8] Client Read Loop Polling Enables CPU Consumption by Peer
**Category:** DoS / Resource Consumption
**Severity:** LOW
**File:** `lib/src/server/named_pipe_server.dart:502-505` (server), `lib/src/client/named_pipe_transport.dart:411-418` (client)
**Description:**
Both the server and client named pipe read loops use `PeekNamedPipe` polling with 1ms delays when no data is available:
```dart
// When peekAvail.value == 0:
await Future.delayed(const Duration(milliseconds: 1));
continue;
```
On Windows, `Future.delayed(Duration(milliseconds: 1))` quantizes to ~15.6ms (the Windows timer resolution), so the actual CPU cost per idle connection is low. However, a peer that sends a single byte every 15ms (just above the peek threshold) forces the read loop into its highest-frequency polling mode — PeekNamedPipe returns data available, ReadFile reads 1 byte, loop continues. Each iteration involves FFI calls (PeekNamedPipe + ReadFile), native buffer allocation via `calloc`, and Dart heap allocation for the 1-byte `Uint8List`.

With `PIPE_UNLIMITED_INSTANCES` (SEC-5) and no connection limit, an attacker can open hundreds of connections, each trickling 1-byte writes to maximize CPU consumption on the server.

**Attack Scenario:**
A local attacker opens 100 named pipe connections. Each connection sends 1 byte every ~1ms via synchronous `WriteFile`. The server's main isolate spends most of its event loop time in PeekNamedPipe/ReadFile cycles across 100 connections, starving real client connections of CPU time and increasing latency.

**Recommendation:**
This is partially mitigated by the 1ms yield between poll iterations. Consider:
- Adaptive polling: increase delay when reads return small amounts of data
- Connection-level rate limiting: track bytes-per-second per connection
- Primarily, address SEC-5 (connection limits) to bound the total number of polling connections

---

### [SEC-9] Removed `print(response)` in Proxy Response — Information Disclosure Fix (Positive)
**Category:** Information Disclosure (FIXED)
**Severity:** INFORMATIONAL (Positive Finding)
**File:** `lib/src/client/http2_connection.dart` (diff line removing `print(response)`)
**Description:**
The diff removes a `print(response)` call in `_waitForResponse()` that was dumping the raw HTTP proxy response to stdout:
```dart
// REMOVED:
print(response);
```
This is a positive security fix. The proxy response could contain server headers, version information, or authentication challenge details that should not be logged to stdout in production.

---

### [SEC-10] Error Handler Exception Does Not Prevent Trailer Transmission
**Category:** Information Disclosure
**Severity:** LOW
**File:** `lib/src/server/handler.dart:569-588`
**Description:**
The `_sendError` method now catches exceptions from the error handler callback:
```dart
void _sendError(GrpcError error, [StackTrace? trace]) {
  try {
    _errorHandler?.call(error, trace);
  } catch (e) {
    logGrpcEvent('[gRPC] Error handler threw: $e', ...);
  }
  sendTrailers(status: error.code, message: error.message, ...);
}
```
This is correct defensive coding — the error handler throwing should not prevent trailers from being sent. However, if a custom `_errorHandler` intentionally throws to prevent the error details from being sent to the client (e.g., a security interceptor that strips sensitive error messages), this change bypasses that intention and sends the trailers anyway.

**Recommendation:**
Document that `_errorHandler` throwing does not prevent trailer transmission. If error suppression is a needed pattern, provide a separate mechanism (e.g., the error handler returns a modified `GrpcError` or null to suppress).

## Summary

| Severity | Count | Categories |
|----------|-------|------------|
| HIGH | 1 | Access Control (SEC-1: NULL DACL) |
| MEDIUM | 3 | Input Validation (SEC-2), Information Disclosure (SEC-3), DoS (SEC-4, SEC-5) |
| LOW | 4 | Isolate Trust (SEC-6), Shutdown Safety (SEC-7), CPU DoS (SEC-8), Error Handler (SEC-10) |
| INFORMATIONAL | 1 | Positive fix (SEC-9) |

**Critical Path Items:**
- **SEC-1** (NULL DACL) is the most impactful finding. On multi-user Windows systems or when the server runs as a service, any local user can connect to the pipe and invoke gRPC methods. This should be addressed before production deployment on shared Windows machines.
- **SEC-5** (unbounded instances) combined with **SEC-8** (polling CPU cost) creates a viable local DoS vector. Adding connection limits is straightforward defense.
- **SEC-3** (error information disclosure) is a common issue that should be addressed as a hardening pass across all `GrpcError.internal()` calls in handler.dart.

**Positive Security Observations:**
- `PIPE_REJECT_REMOTE_CLIENTS` is correctly used, preventing SMB-based remote pipe access
- The `_tooManyBadPingsTriggered` flag prevents duplicate terminate calls
- The keepalive comparison fix (`<` instead of `>`) correctly detects fast pings now, aligned with gRPC C++ reference implementation
- Shutdown uses `Timer` instead of `Future.timeout()` to handle event-loop saturation — sound defensive design
- The `print(response)` removal eliminates an information leak in the proxy path
- The `_trailersSent` guard prevents double-trailer races
- Connection generation counters prevent stale `socket.done` callbacks from corrupting new connections
