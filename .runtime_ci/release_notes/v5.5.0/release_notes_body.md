# grpc-dart v5.5.0

- **Decision**: minor
  The update expands the public API surface with an additive, backward-compatible change (`NamedPipeServer.serve` taking `http2ServerSettings`), which falls under a minor version bump.
- **Key Changes**:
  - Add optional `http2ServerSettings` parameter to `NamedPipeServer.serve` to support custom HTTP/2 configuration (e.g., flow-control limits) on Windows named pipe connections.
  - Implement zero-delay read polling and coalesced writes (up to 32KB chunks) to drastically reduce latency and resolve microtask starvation on Windows named pipes.
  - Switch named pipe server data I/O to `PIPE_NOWAIT` mode to prevent the Dart event loop from stalling under heavy concurrency.
  - Remove synchronous `WaitNamedPipe` FFI calls that blocked the Dart isolate, replacing them with asynchronous exponential backoff and a wall-clock deadline.
  - Fix idle connector release, overlapped write spikes, and general pipeline resilience on Windows.
  - Fix git tracking of CI workflow logs (added to `.gitignore`).
  - Correct repository name resolution in CI configuration (`grpc-dart`).
  - Switch CI to WarpBuild runners for increased speed and upgrade `runtime_ci_tooling` templates to `v0.23.10`.
- **Breaking Changes**:
  - None. (Adding an optional named parameter is fully backward-compatible in Dart).
- **New Features**:
  - Expose `ServerSettings` tuning (e.g., stream window size, concurrent streams) for Windows named pipe deployments.
- **References**:
  - PR #50 (`fix/windows-named-pipe-ci-hardening`).
  - Commits `7228207`, `62d0325`, `cfb9248`, `7b87f49`, `e6c139e`, `0ca1b7b`.

## Changelog

## [5.5.0] - 2026-03-25

### Added
- Added `overlapped_named_pipe_spike.dart` as design anchor for future overlapped I/O (#49)
- Added 10MB and 30MB echo payload tests for sustained throughput validation (#50)
- Added 13 named pipe test variants achieving full parity with TCP/UDS (#50)

### Changed
- Switched CI to WarpBuild runners for faster CI and updated GitHub action templates (#50)
- Improved performance with zero-delay read polling and 32KB write chunks for Windows named pipes (#50)
- Improved performance with write queue coalescing for named pipes (#50)
- Aligned Dart workspace resolution and dependency constraints (#47)
- Used gemini-3-flash-preview for doc reviews
- Applied dart format --line-length 120 (#47)

### Removed
- Removed blocking WaitNamedPipe FFI in favor of wall-clock deadline
- Removed runtime_common_codestyle from dev_dependencies

### Fixed
- Fixed microtask starvation causing duplex stall on Windows named pipes by yielding to event queue
- Fixed PIPE_NOWAIT for server data I/O and non-blocking WriteFile retry to prevent deadlocks
- Fixed `_writeChunk` after yield against closed handle (#49)
- Fixed non-terminal connector OS releases to prevent early stream termination (#49)
- Fixed connector retry on ERROR_FILE_NOT_FOUND to handle heavy connection contention (#50)
- Fixed 0-based serverStream index to prevent data corruption at index 0 (#50)
- Fixed repository name in config.json to resolve tool failures
- Fixed Windows path length cloning issues by removing and git-ignoring workflow_logs
- Fixed tracking issue by updating runtime_ci_tooling and regenerating CI workflows (fixes #46)

---
[Full Changelog](https://github.com/open-runtime/grpc-dart/compare/v5.4.0...v5.5.0)
