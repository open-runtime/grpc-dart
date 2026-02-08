# Fork Changes Documentation

This document tracks all custom modifications, patches, and deviations from the upstream `grpc/grpc-dart` repository.

## Fork Information

- **Fork Repository**: `https://github.com/open-runtime/grpc-dart`
- **Upstream Repository**: `https://github.com/grpc/grpc-dart`
- **Current Branch**: `chore/unify-dependencies`
- **Last Upstream Sync**: February 2026 (cherry-picked protos.dart from upstream #816)
- **Fork Status**: 0 commits behind upstream (fully synced)

## Custom Modifications

### 1. Repository URL
- **Change**: Updated `pubspec.yaml` repository field to point to fork
- **Reason**: Maintains correct attribution and allows for custom releases
- **Location**: `pubspec.yaml`

### 2. Analysis Options
- **Change**: Excluded `example/**` and `interop/**` directories from analyzer
- **Reason**: Reduces noise from generated code and example files
- **Location**: `analysis_options.yaml`
```yaml
analyzer:
  exclude:
    - 'example/**'
    - 'interop/**'
```

### 3. Code Formatting
- **Change**: Minor formatting differences (line breaks, indentation) to match monorepo style
- **Reason**: Consistency with monorepo code style guidelines
- **Location**: Various files (formatting-only changes)

### 4. Null Connection Exception Fix
- **Change**: Added null check in `makeRequest()` method to throw `ArgumentError` when connection is null
- **Reason**: Prevents null pointer exceptions when making requests on uninitialized connections
- **Location**: `lib/src/client/http2_connection.dart`
- **Original Commit**: `fbee4cd` (August 18, 2023) - "Add exception to null connection"
- **Status**: ✅ **RESTORED** - This fix was lost during upstream merges between v4.0.2 and v5.0.0 and has been restored
- **History**: 
  - Originally added in commit `fbee4cd` (Aug 2023)
  - Lost during upstream merges (was not present in `9a61c6c` or `f952d38`)
  - Restored in December 2025 after comprehensive audit

## Known Issues & Pending Fixes

### Race Condition Fix (✅ Merged)
Race condition fixes from `origin/hiro/race_condition_fix` have been merged into `aot_monorepo_compat`:

**Issues Addressed**:
- "Cannot add event after closing" errors when streams are closed concurrently
- Race conditions in error handling paths
- Safer stream manipulation with null checks and try-catch blocks

**Changes Applied**:
1. Enhanced error handling in `_onResponse()` method with null checks and try-catch
2. Safer `sendTrailers()` implementation with try-catch for closed streams
3. Improved error handling in `_onDoneExpected()` with null checks

**Status**: ✅ Merged and tested - all tests passing

**Implementation Date**: December 2025 (after upstream 5.0.X merge)

## Upstream Sync History

### February 2026 - Cherry-pick protos.dart Export (upstream #816)
- **Cherry-picked Commit**: `fa87a0d` from `upstream/master`
- **Changes**:
  - Added `lib/protos.dart` -- re-exports protobuf `Duration` and error detail types (`RetryInfo`, `DebugInfo`, `QuotaFailure`, `ErrorInfo`, `PreconditionFailure`, `BadRequest`, `RequestInfo`, `ResourceInfo`, `Help`, `LocalizedMessage`, etc.)
  - Avoids naming conflicts between `dart:core Duration` and proto `Duration`
  - CHANGELOG updated with upstream 5.1.0 entry
- **Skipped Commit**: `f3ff3a7` (CI-only `actions/checkout` bump -- fork has different CI setup)
- **Conflicts Resolved**: `pubspec.yaml` (kept fork metadata), `test/client_tests/client_test.dart` (kept new `protos.dart` import)
- **Status**: ✅ Successfully applied, `dart analyze` clean
- **Result**: Fork is now **0 commits behind upstream** (fully synced)

### December 2025 - Race Condition Fixes Applied & Null Connection Fix Restored
- **Changes**: 
  - Applied race condition fixes from `origin/hiro/race_condition_fix` branch
  - Enhanced error handling in `_onResponse()`, `sendTrailers()`, and `_onDoneExpected()`
  - Prevents "Cannot add event after closing" errors
  - **RESTORED**: Null connection exception fix (commit `fbee4cd`) that was lost during upstream merges
  - Added null check in `makeRequest()` to throw `ArgumentError` when connection is null
- **Status**: ✅ Successfully applied, all tests passing (169 passed, 3 skipped)

### November 25, 2025 - v5.0.0 Merge
- **Merge Commit**: `f952d38`
- **Changes**: 
  - Upgraded `protobuf` from ^4.0.0 to ^5.1.0
  - Updated all generated protobuf files
  - Re-added `ServerInterceptor` class and functionality
  - Downgraded `meta` package from 1.17.0 to 1.16.0
- **Status**: ✅ Successfully merged, all tests passing

### Previous Syncs
- Multiple dependency updates and protobuf version migrations
- Formatting standardization across the codebase
- CI/CD workflow updates

## Why This Fork Exists

### Monorepo Integration
This fork is maintained as part of the Pieces AOT monorepo to:
- Enable path-based dependencies via `pubspec_overrides.yaml`
- Ensure consistent dependency versions across all packages
- Support local development without network dependencies
- Integrate with Melos dependency management

### Development Workflow
- Full control over when upstream changes are merged
- Ability to test upstream changes before integration
- Capability to apply emergency fixes without waiting for upstream
- Custom patches for Pieces-specific requirements

## Maintenance Guidelines

### When to Sync with Upstream
- Monthly reviews of upstream changes
- Before major version releases
- When critical security patches are released
- When new features are needed from upstream

### Before Merging Upstream Changes
1. Review upstream changelog and commit history
2. Run full test suite: `dart test`
3. Run static analysis: `dart analyze`
4. Check for conflicts with custom modifications
5. Verify compatibility with monorepo dependencies
6. Update this document with merge details

### Testing After Changes
Always run:
```bash
dart pub get
dart analyze
dart test
```

## Other Notable Branches

### `origin/hiro/publish_to_package_repository`
- **Purpose**: CloudSmith package publishing configuration
- **Changes**: 
  - Adds `publish_to: https://dart.cloudsmith.io/pieces-for-developers/pieces-dart-package/`
  - Adds GitHub Actions workflow step for `dart pub publish -f`
- **Status**: On separate branch, not merged to `aot_monorepo_compat`
- **Note**: Not needed for monorepo development (uses path dependencies)

### `upstream/addExceptionToNullConnection`
- **Purpose**: Upstream branch with the null connection fix
- **Status**: Proposed to upstream but never merged into `upstream/master`
- **Note**: We maintain this fix in our fork

## Comprehensive Audit Results (December 2025)

### All Fork Commits Since v4.0.2 Reviewed
- **Total Fork Commits**: 53 unique commits (including branches)
- **Commits on `aot_monorepo_compat`**: 18 custom commits
- **Files Modified**: 72 source/config files (excluding generated protobuf)
- **Functional Changes Verified**: ✅ All accounted for

### What Was Checked
1. ✅ Every commit between v4.0.2 and current HEAD
2. ✅ All files in `lib/src/client` and `lib/src/server`
3. ✅ All configuration files (`pubspec.yaml`, `analysis_options.yaml`, `build.yaml`)
4. ✅ All test files (40 test files, 169 tests passing)
5. ✅ All branches (`aot_monorepo_compat`, `hiro/race_condition_fix`, `hiro/publish_to_package_repository`)
6. ✅ Upstream branches with potential fixes (`addExceptionToNullConnection`, `reproDeadlineError`)

### Functional Changes Preserved
1. **Null connection exception** - ✅ Restored (was lost, now back)
2. **Race condition fixes** - ✅ Applied (3 critical error handling improvements)
3. **Analysis options excludes** - ✅ Preserved
4. **Repository URL** - ✅ Preserved
5. **ServerInterceptor** - ✅ Re-added during 5.0.0 merge (was in upstream)
6. **Code formatting** - ✅ Preserved (589 formatting-only lines differ from upstream)

## Future Considerations

1. **protobuf 6.0.0**: Monitor compatibility; will require coordinated update across entire monorepo
2. **CloudSmith Publishing**: Branch `origin/hiro/publish_to_package_repository` available if needed for package releases
3. **Regular Sync Schedule**: Establish monthly or per-major-version sync cadence
4. **Upstream Contributions**: Consider contributing race condition fixes back to upstream (they're valuable for the community)

## Contact

For questions about this fork or to request changes, contact the Pieces development team.

