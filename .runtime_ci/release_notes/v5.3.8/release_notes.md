# grpc v5.3.8

# Version Bump Rationale

**Decision**: patch

**Reasoning**: 
The recent changes consist entirely of chore/maintenance tasks, style fixes, test improvements, and a development dependency bump. No public APIs were broken, modified, or introduced. This corresponds to a patch release in semantic versioning.

**Key Changes**:
- Fixed analyzer lint issues across the codebase (5 -> 0).
- Reordered export directives alphabetically in `lib/grpc.dart`.
- Added `ignore: close_sinks` comments to lifecycle-managed `StreamControllers` in `named_pipe_server.dart`.
- Removed an unnecessary import from `protos.dart` in `test/client_tests/client_test.dart`.
- Used `var` for local variable type inference in prompt scripts.
- Bumped `runtime_ci_tooling` dev dependency to `^0.9.0`.

**Breaking Changes**:
- None

**New Features**:
- None

**References**:
- Commit: chore: fix all analyzer lint issues (5 -> 0)


## Changelog

## [5.3.8] - 2026-02-22

### Changed
- Fixed analyzer lint issues across the codebase, including reordering export directives alphabetically, adding ignore: close_sinks for lifecycle-managed StreamControllers, removing an unnecessary import, and using var for local variable type inference in scripts.
- Bumped runtime_ci_tooling dev_dependency to ^0.9.0.

## 5.1.0

- Added `protos.dart` library.
- Require `protobuf:6.0.0`.

---
[Full Changelog](https://github.com/open-runtime/grpc/compare/v5.3.7...v5.3.8)
