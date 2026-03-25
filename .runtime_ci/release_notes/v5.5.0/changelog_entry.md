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