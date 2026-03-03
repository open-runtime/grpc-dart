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

## CRITICAL: Fork-Only Issue & PR Management

**NEVER create issues, comments, labels, or PRs on the upstream `grpc/grpc-dart` repository.**

All issue triage, bug reports, enhancement requests, PR comments, and project management
must ONLY target `open-runtime/grpc-dart`. This is a hard rule with no exceptions.

**Always use `--repo open-runtime/grpc-dart` on every `gh` command** to prevent
accidental upstream leakage. Never rely on git remote auto-detection.

```bash
# CORRECT - always explicit
gh issue create --repo open-runtime/grpc-dart --title "..."
gh issue comment 42 --repo open-runtime/grpc-dart --body "..."
gh pr comment 23 --repo open-runtime/grpc-dart --body "..."

# WRONG - may resolve to upstream
gh issue create --title "..."
```

**Rationale**: This is a fork. Upstream issues/PRs are managed by the gRPC team.
Our fork-specific bugs, features, and named pipe work belong exclusively on our fork.

### Named Pipe Transport (Windows)

Key files for the Windows named pipe transport:

| File | Purpose |
|------|---------|
| `lib/src/server/named_pipe_server.dart` | Server with two-isolate architecture |
| `lib/src/client/named_pipe_transport.dart` | Client transport connector |
| `lib/src/shared/named_pipe_io.dart` | Shared constants and buffer helpers |
| `test/named_pipe_adversarial_test.dart` | 10 adversarial race condition tests |
| `test/named_pipe_stress_test.dart` | Lifecycle, concurrency, error handling tests |
| `test/transport_test.dart` | Cross-transport protocol tests (TCP, UDS, pipes) |

**Copyright**: All named pipe code is copyright Tsavo Knott, Mesh Intelligent Technologies, Inc. dba., Pieces.app

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

### Timing and Synchronization Hard Rules (Dart)

These are strict anti-flake rules for tests and implementations.

1. Never use arbitrary `Future.delayed(...)` as synchronization.
   Use explicit barriers (`Completer`, `expectLater(..., completes)`,
   or polling concrete state with a deadline).
2. Never "fix" races by only increasing timeouts or retries.
   Find and fix the missing signal, ownership, or cancel path first.
3. Never weaken assertions to make flakes pass.
   Do not replace exact checks with broad checks (for example,
   `equals` -> `greaterThan`, broad `anyOf`, or accepting
   `TimeoutException` as success).
4. Never swallow async errors or teardown failures.
   Do not use `catch (_) {}`, ignored `Future`s, or `onError: (_) {}`.
   Fail loudly with context.
5. Never bypass deterministic lifecycle coordination.
   Always await `shutdown()`, `cancel()`, and `done`.
   Prefer ordered phases: start -> ready barrier -> action ->
   settlement barrier -> cleanup barrier.

Common masking shortcuts (code smells):
- Adding `skip:` to hide flaky behavior.
- Replacing event-driven checks with sleep-driven checks.
- Treating timeout as expected success in stress/race tests.
- Making assertions approximate where exact behavior is expected.
- Moving cleanup to best effort and ignoring failures.

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
