# Version Bump Rationale

**Decision**: `patch`

The changes introduced in this release fix a bug in the server handler's cancellation logic and update the documentation. It does not introduce any new public APIs or modify existing signatures, so a major or minor bump is not warranted. 

**Key Changes**:
* **Fix server cancellation response**: When `cancel()` is called on a handler that has already sent response headers, the server will now attempt to send proper gRPC trailers (with `grpc-status: 1 CANCELLED`) before falling back to `RST_STREAM`. This provides a typed status to clients instead of an opaque network failure, improving retry logic and error diagnostics.
* Module documentation in `autodoc.json` and various markdown files was regenerated.

**Breaking Changes**:
None

**New Features**:
None

**References**:
* PR #52: `fix/cancel-sends-grpc-trailers`
* Issue ref: `open-runtime/aot_monorepo#448`
