# grpc v5.4.0

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


## Changelog

## [5.4.0] - 2026-03-19

### Added
- LocalGrpcServer and LocalGrpcChannel for zero-config local IPC API (#41)
- Threaded maxInboundMessageSize through the entire stack (#41)
- Structured logging via logGrpcEvent for transport diagnostics (#41)
- 48 multi-process integration scenarios across TCP, UDS, named pipes and 129 http2 internal tests (#41)

### Changed
- Vendored http2 by removing package:http2 dependency into lib/src/http2/ (#41)
- Rewrote server shutdownActiveConnections() with deterministic 5-phase lifecycle (#41)
- Refactored named pipe transport to a two-isolate architecture with cooperative shutdown and write queue chunking (#41)

### Removed
- Removed package:http2 dependency (vendored instead) (#41)

### Fixed
- Fixed server shutdown races and lifecycle issues (#41)
- Fixed client connection lifecycle by adding connectTransport() shutdown guard and dispatch loop re-queue fix (#41)
- Preserved GrpcError status codes in handler error preservation (_onError) (#41)
- Fixed isCanceled setter to respect the value parameter (#41)
- Fixed vendored http2 Bug #1: ConnectionMessageQueueIn.onTerminated assert to defensive clear (#41)
- Fixed vendored http2 Bug #2: _pingReceived/_frameReceived closed in _terminate() (#41)
- Fixed vendored http2 Bug #3: BufferedBytesWriter._closed guard (#41)

---
[Full Changelog](https://github.com/open-runtime/grpc/compare/v5.3.8...v5.4.0)
