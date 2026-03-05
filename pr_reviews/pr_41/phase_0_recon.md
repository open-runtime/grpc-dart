# Phase 0: Recon — PR #41

**PR:** #41 — fix/named-pipe-race-condition -> main
**State:** OPEN
**Date:** 2026-03-03

## Scope

| Metric | Value |
|--------|-------|
| Files changed | 57 |
| Additions | +21,738 |
| Deletions | -1,130 |
| Net lines | +20,608 |
| Commits | 73 |

## Changed Files by Category

### Production Code (lib/) — 16 files

| File | Lines Changed | Category |
|------|--------------|----------|
| `lib/src/server/named_pipe_server.dart` | +1,044/-significant | Named pipe server (two-isolate architecture) |
| `lib/src/client/named_pipe_transport.dart` | +525/-significant | Named pipe client transport |
| `lib/src/server/handler.dart` | +354/-significant | Server handler lifecycle hardening |
| `lib/src/server/server.dart` | +318/-significant | Shutdown synchronization |
| `lib/src/client/http2_connection.dart` | +204/-significant | Client connection dispatch/refresh |
| `lib/src/shared/logging/logging_io.dart` | +122/-significant | Logging infrastructure |
| `lib/src/shared/named_pipe_io.dart` | +99 (new) | Shared named pipe constants/helpers |
| `lib/src/shared/logging/logging_web.dart` | +89/-significant | Web logging infrastructure |
| `lib/src/client/call.dart` | +61/-significant | Client call guarded callbacks |
| `lib/src/client/transport/http2_transport.dart` | +56/-significant | HTTP/2 transport guarded callbacks |
| `lib/src/server/server_keepalive.dart` | +34/-significant | Keepalive comparison fix |
| `lib/src/client/channel.dart` | +9 | Channel additions |
| `lib/src/client/named_pipe_channel.dart` | +9 | Named pipe channel |
| `lib/src/auth/auth.dart` | +11 | Token refresh logging |
| `lib/grpc.dart` | +2 | New logging exports |
| `pubspec.yaml` | +12 | Dependencies |

### Test Code (test/) — 30 files

**New test files (18):**
- `connection_lifecycle_test.dart` (+1,056)
- `handler_hardening_test.dart` (+2,460)
- `handler_regression_test.dart` (+518)
- `named_pipe_adversarial_test.dart` (+1,962)
- `named_pipe_large_payload_test.dart` (+642)
- `named_pipe_stress_test.dart` (+1,200)
- `rst_stream_stress_test.dart` (+965)
- `shutdown_propagation_test.dart` (+1,079)
- `tcp_adversarial_test.dart` (+2,350)
- `tcp_large_payload_test.dart` (+495)
- `transport_guard_test.dart` (+774)
- `dispatch_requeue_test.dart` (+820)
- `rocket_conditions_test.dart` (+789)
- `production_regression_test.dart` (+270)
- `connection_server_error_cleanup_test.dart` (+310)
- `http2_connection_refresh_test.dart` (+308)
- `src/echo_service.dart` (+287)
- `client_transport_connector_test.dart` (+59)

**Modified test files (12):**
- `transport_test.dart` (+1,328 significant expansion)
- `server_cancellation_test.dart` (+974 significant expansion)
- `client_handles_bad_connections_test.dart` (+144)
- `common.dart` (+229 — shared test utilities)
- `race_condition_test.dart` (+320 rewrite)
- `round_trip_test.dart` (+64)
- `keepalive_test.dart` (+42)
- `server_keepalive_manager_test.dart` (+46)
- `connection_server_test.dart` (+10)
- `server_test.dart` (+10)
- `client_tests/client_test.dart` (+6)
- `src/server_utils.dart` (+25)

### CI/Config — 11 files

- `.github/workflows/ci.yaml` (+81)
- `.runtime_ci/config.json` (+43)
- `.runtime_ci/template_versions.json` (+20)
- `.runtime_ci/autodoc.json` (+17)
- `CLAUDE.md` (+101)
- `CONTRIBUTING.md` (+23)
- `.gitignore` (+4)
- `.gemini/commands/triage.toml` (+45)
- `scripts/prompts/autodoc_*.dart` (3 files, minor)

## Key Production Files for Review

Priority reading order for reviewers:
1. `lib/src/server/server.dart` — shutdown rewrite
2. `lib/src/server/handler.dart` — handler lifecycle hardening
3. `lib/src/server/named_pipe_server.dart` — two-isolate architecture
4. `lib/src/client/http2_connection.dart` — dispatch/refresh fixes
5. `lib/src/client/named_pipe_transport.dart` — client transport
6. `lib/src/server/server_keepalive.dart` — keepalive comparison fix
7. `lib/src/client/transport/http2_transport.dart` — guarded callbacks
8. `lib/src/client/call.dart` — guarded callbacks

## PR Description Summary

- Shutdown synchronization: `shutdownActiveConnections()` phased approach with timeouts
- Error handling hardening: Guarded `addError`/`close` calls against already-closed controllers
- Test matcher tightening: Specific transport types replacing broad `isA<Exception>()`
- Named pipe transport: Two-isolate architecture, deterministic shutdown
- Keepalive fix: Inverted comparison corrected per gRPC C++ spec
