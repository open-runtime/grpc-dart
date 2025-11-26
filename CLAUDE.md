# Claude Code Context: open-runtime/grpc-dart Fork

## What is This?

This is the **open-runtime fork** of the official [grpc/grpc-dart](https://github.com/grpc/grpc-dart) package.

| | |
|--|--|
| **Repository** | https://github.com/open-runtime/grpc-dart |
| **Upstream** | https://github.com/grpc/grpc-dart |
| **Version** | See `pubspec.yaml` |

## Why This Fork Exists

The AOT monorepo **cannot** use the pub.dev version. This fork contains:

### 1. 🔧 Race Condition Fixes (Production Critical)
- **NOT in upstream** - our production-specific fixes
- Prevents "Cannot add event after closing" server crashes
- Safe error handling in `_onResponse()`, `sendTrailers()`, `_onDoneExpected()`
- **Location**: `lib/src/server/handler.dart`

### 2. 🛡️ Null Connection Exception Fix
- **NOT in upstream/master** - proposed but never merged
- Prevents cryptic null pointer exceptions
- Provides actionable error messages
- **Location**: `lib/src/client/http2_connection.dart`

### 3. 🔒 ServerInterceptor Support
- Available in upstream v4.1.0+, but combined with our fixes
- Powers the entire AOT security architecture
- Enables per-connection tracking, progressive delays, attack prevention
- **Location**: `lib/src/server/interceptor.dart`

## Key Files

| File | Purpose |
|------|---------|
| `lib/src/server/handler.dart` | Server handler with race condition fixes |
| `lib/src/client/http2_connection.dart` | Client with null connection fix |
| `lib/src/server/interceptor.dart` | ServerInterceptor class |
| `WHY_USE_OPEN_RUNTIME_FORK.md` | Detailed justification document |
| `FORK_CHANGES.md` | Maintenance guide for fork changes |

## Development

### Code Style
- Follow Dart style guide
- Keep lines under 80 characters
- Run `dart format .` before committing
- Run `dart analyze --fatal-infos .` to check for issues

### Testing
```bash
dart test                  # All tests
dart test --platform vm    # VM tests only
dart test --platform chrome # Browser tests (Linux)
```

### Commit Messages (Conventional Commits)
```
feat:     New feature        → MINOR version
fix:      Bug fix            → PATCH version
feat!:    Breaking change    → MAJOR version
docs:     Documentation only
chore:    Maintenance tasks
perf:     Performance
refactor: Code refactoring
```

**⚠️ BREAKING CHANGE Rules:**
- ✅ Use for: Removing/renaming public API, changing method signatures
- ❌ NOT for: CI changes, docs, internal refactoring, adding new features

## Release Process

```
Push commits → Release Please creates PR → Claude enhances PR → Merge → GitHub Release → tag_pattern consumers auto-update
```

All Claude CI instructions are embedded in `.github/workflows/enhance-release-pr.yml`.

## Upstream Sync Strategy

- Monitor upstream releases monthly
- Merge major versions after testing
- **ALWAYS preserve our critical fixes** during merges
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

## Quick Reference

| Command | Purpose |
|---------|---------|
| `dart pub get` | Install dependencies |
| `dart format .` | Format code |
| `dart analyze` | Static analysis |
| `dart test` | Run tests |

## Links

- [GitHub Repository](https://github.com/open-runtime/grpc-dart)
- [Upstream grpc-dart](https://github.com/grpc/grpc-dart)
- [gRPC Documentation](https://grpc.io/docs/)

---

**Maintainer**: Pieces Development Team / Open Runtime
