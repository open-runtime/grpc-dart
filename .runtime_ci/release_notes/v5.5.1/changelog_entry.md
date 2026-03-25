## [5.5.1] - 2026-03-25

### Added
- Enabled Windows long paths in the CI workflow (fixes #48)

### Changed
- Updated `runtime_ci_tooling` to `v0.23.13` in all GitHub Actions workflows
- Updated CI workflow to always run on manual `workflow_dispatch` triggers
- Updated release workflow to checkout the `main` branch instead of `workflow_run.head_sha`

### Fixed
- Fixed `create-release` push failure on detached HEAD