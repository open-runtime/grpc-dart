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
