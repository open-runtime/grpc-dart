# Claude Code Context: open-runtime/grpc-dart Fork

## What is This?

This is the **open-runtime fork** of the official [grpc/grpc-dart](https://github.com/grpc/grpc-dart) package.

| | |
|--|--|
| **Repository** | https://github.com/open-runtime/grpc-dart |
| **Upstream** | https://github.com/grpc/grpc-dart |
| **Version** | See `pubspec.yaml` |

## Why This Fork Exists

The AOT monorepo currently uses this fork (git/path dependency) so we can ship
fork-specific fixes and coordinate upgrades safely. Pub.dev may be sufficient
for generic grpc-dart usage, but it does not carry this fork's custom patches.
This fork contains:

### 1. 🔧 Race Condition Fixes (Production Critical)
- Maintained in this fork as production hardening
- Prevents "Cannot add event after closing" server crashes
- Safe error handling in `_onResponse()`, `sendTrailers()`, `_onDoneExpected()`
- **Location**: `lib/src/server/handler.dart`

### 2. 🛡️ Null Connection Exception Fix
- Maintained in this fork for clearer client connection failures
- Prevents cryptic null pointer exceptions during request startup
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
- Match CI formatting defaults (`line_length: 120` in `.runtime_ci/config.json`)
- Run `dart format --line-length 120 lib/` (or equivalent workspace formatting)
- Run `dart analyze` to check for issues

### Testing
```bash
dart test                  # All tests
dart test --platform vm    # VM tests only
dart test --platform chrome # Browser tests (Linux)
```

### Timing and Synchronization Hard Rules (Dart)

These are strict anti-flake and anti-regression rules.

1. Never use arbitrary `Future.delayed(...)` as synchronization.
   Use explicit barriers (`Completer`, `expectLater(..., completes)`,
   stream/state predicates, or deadline-bounded polling of concrete state).
2. Never "fix" race failures by only increasing timeouts/retries.
   Fix the missing readiness signal, ownership boundary, or cancel path.
3. Never weaken assertions to make flakes pass.
   Do not broaden exact checks (for example `equals` -> `greaterThan`,
   or exact sequence -> broad `anyOf`) unless there is a documented,
   behavior-level reason.
4. Never treat timeout as success.
   `onTimeout` must fail loudly with context, not normalize timeout into
   expected behavior.
5. Never swallow async errors or teardown failures.
   No `catch (_)`, no ignored futures, no `onError: (_)`.
   Capture and assert unexpected errors explicitly.
6. Never bypass deterministic lifecycle sequencing.
   Always await `shutdown()`, `cancel()`, and `done`.
   Use ordered phases: start -> ready -> action -> settle -> cleanup.
7. Never skip flaky tests without ownership metadata.
   Any `skip:` must include a tracking issue (`#123`) and explicit
   expiry (`expires: YYYY-MM-DD`).
8. Never introduce mock frameworks in this repository's tests.
   Use real integration paths, in-process harnesses, or minimal fakes.
9. Any race fix must include stability proof.
   Demonstrate repeated runs (for example looped execution or stress mode)
   so the fix is evidence-backed, not anecdotal.
10. Any exceptions to these rules must be explicit.
    Document the behavior-level rationale and link a tracking issue.

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
Push commits to `main` → CI passes → Release Pipeline runs → version/changelog/release notes are generated via `runtime_ci_tooling` → GitHub Release is created
```

Release and CI automation live in:
- `.github/workflows/ci.yaml`
- `.github/workflows/release.yaml`
- `.runtime_ci/config.json`

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
    version: ^5.3.8 # update to the current release in pubspec/changelog
```

**Direct tag reference:**
```yaml
dependencies:
  grpc:
    git:
      url: https://github.com/open-runtime/grpc-dart
      ref: v5.3.8 # pin to an exact fork tag
```

**Path dependency (monorepo/local development example):**
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
