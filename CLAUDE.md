# Claude Code Context: open-runtime/grpc-dart Fork

## Project Overview

This is the **open-runtime fork** of the official [grpc/grpc-dart](https://github.com/grpc/grpc-dart) package.

**Repository**: https://github.com/open-runtime/grpc-dart  
**Upstream**: https://github.com/grpc/grpc-dart  
**Current Version**: See `pubspec.yaml`

## Why This Fork Exists

The AOT monorepo **cannot** use the pub.dev version. We maintain this fork with:

### 1. Race Condition Fixes (Production Critical)
- **NOT in upstream** - our production-specific fixes
- Prevents "Cannot add event after closing" server crashes
- Safe error handling in `_onResponse()`, `sendTrailers()`, `_onDoneExpected()`
- Location: `lib/src/server/handler.dart`

### 2. Null Connection Exception Fix
- **NOT in upstream/master** - proposed but never merged
- Prevents cryptic null pointer exceptions
- Provides actionable error messages
- Location: `lib/src/client/http2_connection.dart`

### 3. ServerInterceptor Support
- Available in upstream v4.1.0+, but combined with our fixes
- Powers the entire AOT security architecture
- Enables per-connection tracking, progressive delays, attack prevention

## Key Files

| File | Purpose |
|------|---------|
| `lib/src/server/handler.dart` | Server handler with race condition fixes |
| `lib/src/client/http2_connection.dart` | Client with null connection fix |
| `lib/src/server/interceptor.dart` | ServerInterceptor class |
| `WHY_USE_OPEN_RUNTIME_FORK.md` | Detailed justification document |
| `FORK_CHANGES.md` | Maintenance guide for fork changes |

## Development Guidelines

### Code Style
- Follow Dart style guide
- Keep lines under 80 characters (Dart default)
- Run `dart format .` before committing
- Run `dart analyze --fatal-infos .` to check for issues

### Testing
```bash
# Run all tests
dart test

# Run VM tests only
dart test --platform vm

# Run Chrome tests (Linux only)
dart test --platform chrome
```

### Commit Messages
Use [Conventional Commits](https://www.conventionalcommits.org/):
- `feat:` New features (→ MINOR version)
- `fix:` Bug fixes (→ PATCH version)
- `fix!:` or `feat!:` Breaking changes (→ MAJOR version)
- `docs:` Documentation only
- `chore:` Maintenance tasks
- `perf:` Performance improvements
- `refactor:` Code refactoring

## Release Process Overview

This repository uses **Release Please** + **Claude Code Action**:

```
1. Push commits with feat:/fix:/etc.
         ↓
2. Release Please creates Release PR
         ↓
3. Claude Code Action AUTOMATICALLY:
   - Reviews version appropriateness
   - Adds Release Highlights
   - Syncs documentation if needed
   - Closes fixed issues
   - Posts summary comment
         ↓
4. You review and merge
         ↓
5. GitHub Release created (vX.Y.Z)
         ↓
6. Dart packages can consume via tag_pattern
```

## Claude's Role as Release Manager

When enhancing Release PRs, Claude should:

### Version Review
- **MAJOR**: Breaking API changes, protocol incompatibilities
- **MINOR**: New features, significant upstream merges, new ServerInterceptor capabilities
- **PATCH**: Bug fixes, race condition fixes, docs, CI changes

**Important**: Internal workflow/CI changes are NEVER breaking changes for a library!

### Release Highlights
Add a concise summary focusing on:
- Stability improvements
- Upstream compatibility
- Security enhancements
- Developer impact

### Fork-Specific Considerations
- Note if changes affect upstream compatibility
- Document any new fork-specific fixes
- Update `FORK_CHANGES.md` if new fixes are added
- Update `WHY_USE_OPEN_RUNTIME_FORK.md` if justification changes

## Upstream Sync Strategy

- Monitor upstream releases monthly
- Merge major versions after testing
- **Always preserve our critical fixes** during merges
- Document all custom modifications in `FORK_CHANGES.md`

## Installation

**Dart 3.9+ with tag_pattern (recommended):**
```yaml
dependencies:
  grpc:
    git:
      url: https://github.com/open-runtime/grpc-dart
      tag_pattern: "^v"
    version: ^5.0.0
```

**Direct tag reference:**
```yaml
dependencies:
  grpc:
    git:
      url: https://github.com/open-runtime/grpc-dart
      ref: v5.0.0
```

**Path dependency (monorepo):**
```yaml
grpc:
  path: ../../external_dependencies/grpc
```

## Git Tag Resolution

Dart 3.9+ with `tag_pattern` automatically selects the highest semver tag matching your version constraint. No "latest" tag is needed - pub handles this automatically!

## Quick Reference

| Command | Purpose |
|---------|---------|
| `dart pub get` | Install dependencies |
| `dart format .` | Format code |
| `dart analyze` | Static analysis |
| `dart test` | Run tests |
| `dart test --platform vm` | VM tests only |
| `dart test --platform chrome` | Browser tests |

## Links

- [GitHub Repository](https://github.com/open-runtime/grpc-dart)
- [Upstream grpc-dart](https://github.com/grpc/grpc-dart)
- [gRPC Documentation](https://grpc.io/docs/)
- [Dart Package Documentation](https://dart.dev/guides/packages)

---

**Last Updated**: November 2025  
**Maintainer**: Pieces Development Team / Open Runtime

