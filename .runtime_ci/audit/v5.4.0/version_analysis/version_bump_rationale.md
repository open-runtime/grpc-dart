# Version Bump Rationale

- **Decision**: minor
- **Why**: The commit introduces significant new features (local IPC, max message size handling, structured logging) and vendored dependencies while maintaining backwards compatibility. All additions to public constructors (like `ConnectionServer` and `Server`) are strictly optional or named parameters, preserving existing API contracts.

- **Key Changes**:
  - **Production Fixes**: Server shutdown lifecycle hardened with a deterministic 5-phase approach. Named pipe transport rewritten for cooperative shutdown and chunked writes. Client connection lifecycle guards against socket completion races.
  - **Vendored http2**: Removed `package:http2` dependency, moving its source directly into `lib/src/http2/` and resolving multiple connection and queueing bugs.
  - **New Features**: Added `LocalGrpcServer` and `LocalGrpcChannel` for a zero-config local IPC API. Threaded `maxInboundMessageSize` support through the entire stack. Introduced structured logging with `logGrpcEvent` for advanced transport diagnostics.

- **Breaking Changes**: None.
- **New Features**: `LocalGrpcServer`, `LocalGrpcChannel`, `maxInboundMessageSize`, and structured logging via `logGrpcEvent`.
- **References**: Commit 'fix: named pipe race conditions, production hardening, vendored http2, multi-process IPC tests'
