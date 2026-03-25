# grpc-dart v5.5.1

# Version Bump Rationale

**Decision**: `patch`

The current release is being updated based on the changes since the `v5.5.0` tag. The commits introduced since the last release are purely related to Continuous Integration (CI) configuration, specifically the dependency version pinning for workflow tools.

**Key Changes**:
- Pinned `runtime_ci_tooling` to `v0.23.13` across all GitHub Actions workflows (`ci.yaml`, `release.yaml`, `issue-triage.yaml`).
- Fixed an issue where the `create-release` job was checking out a detached HEAD state by modifying the checkout target to the `main` branch.
- Added support for Windows long paths within the CI pipeline.
- Improved the logic for running manual CI workflow dispatches.

**Breaking Changes**:
- None. There are no changes to the public API or library codebase.

**New Features**:
- None.

**References**:
- Commits since `v5.5.0` tag (e.g. `chore(ci): pin runtime_ci_tooling to v0.23.13 in all workflows`)

## Changelog

## [5.5.1] - 2026-03-25

### Added
- Enabled Windows long paths in the CI workflow (fixes #48)

### Changed
- Updated `runtime_ci_tooling` to `v0.23.13` in all GitHub Actions workflows
- Updated CI workflow to always run on manual `workflow_dispatch` triggers
- Updated release workflow to checkout the `main` branch instead of `workflow_run.head_sha`

### Fixed
- Fixed `create-release` push failure on detached HEAD

---
[Full Changelog](https://github.com/open-runtime/grpc-dart/compare/v5.5.0...v5.5.1)
