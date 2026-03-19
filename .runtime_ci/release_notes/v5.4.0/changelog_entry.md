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