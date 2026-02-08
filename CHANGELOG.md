## 5.1.0

- Added `protos.dart` library.
- Require `protobuf:6.0.0`.

## 5.0.0

- Upgrading protos with new `googleapis` and `protobuf` versions.

## [5.2.3](https://github.com/open-runtime/grpc-dart/compare/v5.2.2...v5.2.3) (2025-11-30)


### 🐛 Bug Fixes

* add final check before Release Please to prevent race conditions ([4c7557e](https://github.com/open-runtime/grpc-dart/commit/4c7557e01f2ccc13a2ad5c76c78034249695791c))
* add workflow_dispatch trigger to release-please workflow ([c64e6b3](https://github.com/open-runtime/grpc-dart/commit/c64e6b3753edc14e6f419e9a7e8a9af36f83210c))

## [5.2.2](https://github.com/open-runtime/grpc-dart/compare/v5.2.1...v5.2.2) (2025-11-30)

### 🚀 Release Highlights

This release refines the automated release workflow to ensure AI-enhanced release notes are generated reliably before creating GitHub releases. The fork's critical race condition and null connection fixes remain fully intact, providing continued production stability for high-concurrency gRPC servers.

### 🐛 Bug Fixes

* reorder release-please jobs and fix enhance-release-pr workflow ([#15](https://github.com/open-runtime/grpc-dart/issues/15)) ([beaf529](https://github.com/open-runtime/grpc-dart/commit/beaf5297c8bdc3fa6dcc704b736f3179103c80aa))

## [5.2.1](https://github.com/open-runtime/grpc-dart/compare/v5.2.0...v5.2.1) (2025-11-30)


### 🔧 Chores

* make chore commits visible in release-please ([9c725f5](https://github.com/open-runtime/grpc-dart/commit/9c725f570216b5de9fe8c8ca1ed34cb2b901ec8b))
* make chore commits visible in release-please ([549de7e](https://github.com/open-runtime/grpc-dart/commit/549de7ec1769f673b20aea972bbd88497c4b83fb))

## [5.2.0](https://github.com/open-runtime/grpc-dart/compare/v5.1.1...v5.2.0) (2025-11-27)


### ✨ Features

* Upgrade to protobuf ^6.0.0 ([9142172](https://github.com/open-runtime/grpc-dart/commit/9142172fa577f607410c45b615d0eae32ccedfa2))


### 🐛 Bug Fixes

* **grpc:** Address P1 code review issues - restore error_details export and fix deprecated Server constructor ([bcd9ffb](https://github.com/open-runtime/grpc-dart/commit/bcd9ffb973fc22f57b2dd1e6531a04766f3957b6))
* Remove unnecessary import in client_test.dart ([73fba90](https://github.com/open-runtime/grpc-dart/commit/73fba90a36c4a1ab82e9fa6d3594894999eb508b))


### 📚 Documentation

* **grpc:** Add PR [#8](https://github.com/open-runtime/grpc-dart/issues/8) resolution summary ([e9d5789](https://github.com/open-runtime/grpc-dart/commit/e9d5789a692788a161464978daeb8ac82b83d8af))

## [5.1.1](https://github.com/open-runtime/grpc-dart/compare/v5.1.0...v5.1.1) (2025-11-26)

### 🚀 Release Highlights

This maintenance release improves the reliability of our automated release system with better YAML handling and comprehensive embedded CI instructions. The fork's critical race condition and null connection fixes remain fully intact, ensuring continued production stability for high-concurrency gRPC servers in the AOT monorepo.

### 🐛 Bug Fixes

* Format all Dart files and add fallback release handler ([b201913](https://github.com/open-runtime/grpc-dart/commit/b201913e9dfeb7f8e73b6747096ebada1f79cc4b))
* Replace heredoc with echo statements for YAML compatibility ([289c7e4](https://github.com/open-runtime/grpc-dart/commit/289c7e4b2c9dc0d1e16cf009d23e4f34eab50b3e))
* Use heredoc and notes-file for release creation ([b03923e](https://github.com/open-runtime/grpc-dart/commit/b03923e8c929b7f04f3bc6b7f0ff3a80181acb7e))


### 📚 Documentation

* Embed comprehensive Claude CI instructions in workflow ([58057a1](https://github.com/open-runtime/grpc-dart/commit/58057a1a344e2a57265bad7c8743c19136082810))

## [5.1.0](https://github.com/open-runtime/grpc-dart/compare/v5.0.0...v5.1.0) (2025-11-26)

### 🚀 Release Highlights

This release enhances the open-runtime fork with automated release management through Release Please and Claude Code Action integration. It also improves observability of race condition fixes with platform-specific stderr logging, making it easier to diagnose and prevent production issues. The fork continues to maintain critical stability fixes from upstream 5.0.0 while adding developer-friendly automation for future releases.

### ✨ Features

* Add Release Please + Claude Code Action for automated releases ([c75c76a](https://github.com/open-runtime/grpc-dart/commit/c75c76abb9bac1747ba0e53bf7398fe6cc8e5bfc))
* fix hang that occurs when hot restarting ([#718](https://github.com/open-runtime/grpc-dart/issues/718)) ([b999b64](https://github.com/open-runtime/grpc-dart/commit/b999b64502508177811e7316580230b8afef780d))
* **grpc:** Add stderr logging to race condition catch blocks per PR [#7](https://github.com/open-runtime/grpc-dart/issues/7) review ([a267004](https://github.com/open-runtime/grpc-dart/commit/a267004f67e09154090e31a8c98da54ab88e9197))
* Initial testing & debugging of _UnixNamedLock ([a04061b](https://github.com/open-runtime/grpc-dart/commit/a04061bff1afc08045aaf6c45bd89a4f0e22246f))
* support client interceptors ([#338](https://github.com/open-runtime/grpc-dart/issues/338)) ([9f83e12](https://github.com/open-runtime/grpc-dart/commit/9f83e124e98425152200042d97ebaaf1d22922f9))


### 🐛 Bug Fixes

* Configure Release Please to use target-branch dynamically ([9f517a9](https://github.com/open-runtime/grpc-dart/commit/9f517a9cdb4e0c73bb8f4f4606546beb17cca386))
* fix headers not completing when call is terminated ([#728](https://github.com/open-runtime/grpc-dart/issues/728)) ([4f6fe9b](https://github.com/open-runtime/grpc-dart/commit/4f6fe9b1114aa5bd9d97e5d3b5ae2cb354804a1f)), closes [#727](https://github.com/open-runtime/grpc-dart/issues/727)
* **grpc:** Add platform-specific logging for race condition fixes ([e313336](https://github.com/open-runtime/grpc-dart/commit/e3133369593c174a3f0cece93d4f15a03ba9c8a0))
* **grpc:** Restore critical null connection fix and apply race condition fixes after upstream 5.0.0 merge ([dedce7a](https://github.com/open-runtime/grpc-dart/commit/dedce7a6441c8b155e0dd86daa62696c5277a9f8))
* keep alive timeout finishes transport instead of connection shutdown ([#722](https://github.com/open-runtime/grpc-dart/issues/722)) ([071ebc5](https://github.com/open-runtime/grpc-dart/commit/071ebc5f31a18ab52e82c09558f3dcb85f41fdbd))
* Migrate off legacy JS/HTML APIs ([#750](https://github.com/open-runtime/grpc-dart/issues/750)) ([8406614](https://github.com/open-runtime/grpc-dart/commit/840661415df7d335cee98a28514de0bc02f7667e))
* update grpc_web_server.dart envoy config to support newer envoy version ([#760](https://github.com/open-runtime/grpc-dart/issues/760)) ([ebc838b](https://github.com/open-runtime/grpc-dart/commit/ebc838b66d5b02e8d46675bae06a75bbd153eb6c))
* Updates the grpc-web example to avoid dart:html ([#748](https://github.com/open-runtime/grpc-dart/issues/748)) ([6dfb4b4](https://github.com/open-runtime/grpc-dart/commit/6dfb4b43f39649cb324d9f132fff9e65bc48ed2b))
* Use ANTHROPIC_API_KEY instead of ANTHROPIC_API_KEY_GLOBAL_CLOUD_RUNTIME ([01c9086](https://github.com/open-runtime/grpc-dart/commit/01c90861d16ca65411d158d4852b317dcda195f2))
* Use ANTHROPIC_API_KEY_GLOBAL_CLOUD_RUNTIME secret ([a7d7b3b](https://github.com/open-runtime/grpc-dart/commit/a7d7b3b9620463cbf75a3ad28b83386c60801409))
* Use package:web to get HttpStatus ([#749](https://github.com/open-runtime/grpc-dart/issues/749)) ([5ba28e3](https://github.com/open-runtime/grpc-dart/commit/5ba28e3a1c2744415b0d696301eef5e59de534fb))


### 📚 Documentation

* **grpc:** Add comprehensive documentation explaining why we use the fork ([e8b6d52](https://github.com/open-runtime/grpc-dart/commit/e8b6d5258ed4a5fb68136980d56e77a2618f025a))

## 4.3.1

- Downgrade `meta` dependency to `1.16.0`

## 4.3.0

- Require `package:protobuf` 5.0.0

## 4.2.0

- Export a protobuf generated symbol (`Any`)
- Simplify hierarchy of `ResponseFuture` (no longer have a private class in the
  type hierarchy)
- Require Dart 3.8.
- Require package:googleapis_auth
- Require package:http 1.4.0
- Require package:lints 6.0.0
- Require package:protobuf 4.1.0
- Dart format all files for the new 3.8 formatter.

## 4.1.0

* Add a `serverInterceptors` argument to `ConnectionServer`. These interceptors
  are acting as middleware, wrapping a `ServiceMethod` invocation.
* Make sure that `CallOptions.mergeWith` is symmetric: given `WebCallOptions`
  it should return `WebCallOptions`.

## 4.0.4

* Allow the latest `package:googleapis_auth`.

## 4.0.3

* Widen `package:protobuf` constraint to allow version 4.0.0.

## 4.0.2

* Internal optimization to client code.
* Small fixes, such as ports in testing and enabling `timeline_test.dart`.
* When the keep alive manager runs into a timeout, it will finish the transport
  instead of closing the connection, as defined in the gRPC spec.
* Upgrade to `package:lints` version 5.0.0 and Dart SDK version 3.5.0.
* Upgrade `example/grpc-web` code.
* Update xhr transport to migrate off legacy JS/HTML apis.
* Use `package:web` to get `HttpStatus`.
* Fix `package:web` deprecations.

## 4.0.1

* Fix header and trailing not completing if the call is terminated. Fixes [#727](https://github.com/grpc/grpc-dart/issues/727)

## 4.0.0

* Set compressed flag correctly for grpc-encoding = identity. Fixes [#669](https://github.com/grpc/grpc-dart/issues/669) (https://github.com/grpc/grpc-dart/pull/693)
* Remove generated status codes.
* Remove dependency on `package:archive`.
* Move `codec.dart`.
* Work around hang during Flutter hot restart by adding default case handler in _GrpcWebConversionSink.add.

## 3.2.4

* Forward internal `GrpcError` on when throwing while sending a request.
* Add support for proxies, see [#33](https://github.com/grpc/grpc-dart/issues/33).
* Remove canceled `ServerHandler`s from tracking list.
* Fix regression on fetching the remote address of a closed socket.

## 3.2.3

* Add const constructor to `GrpcError` fixing #606.
* Make `GrpcError` non-final to allow implementations.
* Only send keepalive pings on open connections.
* Fix interop tests.

## 3.2.2

* Remove `base` qualifier on `ResponseStream`.
* Add support for clients to send KEEPALIVE pings.

## 3.2.1

* `package:http` now supports more versions: `>=0.13.0 <2.0.0`.
* `package:protobuf` new supports more versions: `>=2.0.0 <4.0.0`.

## 3.2.0

* `ChannelOptions` now exposes `connectTimeout`, which is used on the
  socket connect. This is used to specify the maximum allowed time to wait
  for a connection to be established. If `connectTime` is longer than the system
  level timeout duration, a timeout may occur sooner than specified in
  `connectTimeout`. On timeout, a `SocketException` is thrown.
* Require Dart 2.17 or greater.
* Fix issue [#51](https://github.com/grpc/grpc-dart/issues/51), add support for custom error handling.
* Expose client IP address to server
* Add a `channelShutdownHandler` argument to `ClientChannel` and the subclasses.
  This callback can be used to react to channel shutdown or termination.
* Export the `Code` protobuf enum from the `grpc.dart` library.
* Require Dart 3.0.0 or greater.

## 3.1.0

* Expose a stream for connection state changes on ClientChannel to address
  [#428](https://github.com/grpc/grpc-dart/issues/428).
  This allows users to react to state changes in the connection.
* Fix [#576](https://github.com/grpc/grpc-dart/issues/576): set default
  `:authority` value for UDS connections to `localhost` instead of using
  UDS path. Using path triggers checks in HTTP2 servers which
  attempt to validate `:authority` value.

## 3.0.2

* Fix compilation on the Web with DDC.

## 3.0.1

* Require `package:googleapis_auth` `^1.1.0`
* Fix issues [#421](https://github.com/grpc/grpc-dart/issues/421) and
  [#458](https://github.com/grpc/grpc-dart/issues/458). Validate
  responses according to gRPC/gRPC-Web protocol specifications: require
  200 HTTP status and a supported `Content-Type` header to be present, as well
  as `grpc-status: 0` header. When handling malformed responses make effort
  to translate HTTP statuses into gRPC statuses.
* Add GrpcOrGrpcWebClientChannel which uses gRPC on all platforms except web,
  on which it uses gRPC-web.
* `GrpcError` now exposes response trailers via `GrpcError.trailers`.

## 3.0.0

* Migrate library and tests to null safety.
* Require Dart 2.12 or greater.

## 2.9.0

* Added support for compression/decompression, which can be configured through
  `ChannelOptions` constructor's `codecRegistry` parameter or adding the
  `grpc-accept-encoding` to `metadata` parameter of `CallOptions` on the client
  side and `codecRegistry` parameter to `Server` on the server side.
  Outgoing rpc can be compressed using the `compression` parameter on the
  `CallOptions`.
* Fix issue [#206](https://github.com/grpc/grpc-dart/issues/206). Prevent an
  exception to be thrown when a web connection stream is closed.
* Add XHR raw response to the GrpcError for a better debugging
  ([PR #423](https://github.com/grpc/grpc-dart/pulls/423)).

Note: this is the last release supporting SDK < 2.12. Next release will
be nullsafe and thus require SDK >= 2.12.

## 2.8.0

* Added support for client interceptors, which can be configured through
  `Client` constructor's `interceptors` parameter. Interceptors will be
  executed by `Client.$createStreamingCall` and `Client.$createUnaryCall`.
  Using interceptors requires regenerating client stubs using version 19.2.0 or
  newer of protobuf compiler plugin.
* `Client.$createCall` is deprecated because it does not invoke client
  interceptors.
* Fix issue [#380](https://github.com/grpc/grpc-dart/issues/380) causing
  incorrect duplicated headers in gRPC-Web requests.
* Change minimum required Dart SDK to 2.8 to enable access to Unix domain sockets.
* Add support for Unix domain sockets in `Socket.serve` and `ClientChannel`.
* Fix issue [#331](https://github.com/grpc/grpc-dart/issues/331) causing
  an exception in `GrpcWebClientChannel.terminate()`.

## 2.7.0

* Added decoding/parsing of `grpc-status-details-bin` to pass all response
  exception details to the `GrpcError` thrown in Dart, via
  [#349](https://github.com/grpc/grpc-dart/pull/349).
* Dart SDK constraint is bumped to `>=2.3.0 <3.0.0` due to language version
  in the generated protobuf code.

## 2.6.0

* Create gRPC servers and clients with [Server|Client]TransportConnection.
  This allows callers to provide their own transport configuration, such
  as their own implementation of streams and sinks instead of sockets.

## 2.5.0

* Expose a `validateClient` method for server credentials so gRPC server
  users may know when clients are loopback addresses.

## 2.4.1

* Plumb stacktraces through request / response stream error handlers.
* Catch and forward any errors decoding the response.

## 2.4.0

* Add the ability to bypass CORS preflight requests.

## 2.3.0

* Revert [PR #287](https://github.com/grpc/grpc-dart/pull/287), which allowed
using gRPC-web in native environments but also broke streaming.

## 2.2.0+1

* Relax `crypto` version dependency constraint from `^2.1.5` to `^2.1.4`.

## 2.2.0

* Added `applicationDefaultCredentialsAuthenticator` function for creating an
  authenticator using [Application Default Credentials](https://cloud.google.com/docs/authentication/production).
* Less latency by using the `tcpNoDelay` option for sockets.
* Support grpc-web in a non-web setting.

## 2.1.3

* Fix bug in grpc-web when receiving an empty trailer.
* Fix a state bug in the server.

## 2.1.2

* Fix bug introduced in 2.1.1 where the port would be added to the default authority when making a
  secure connection.

## 2.1.1

* Fix bug introduced in 2.1.0 where an explicit `authority` would not be used when making a secure
  connection.

## 2.1.0

* Do a health check of the http2-connection before making request.
* Introduce `ChannelOptions.connectionLimit` the longest time a single connection is used for new
  requests.
* Use Tcp.nodelay to improve client call speed.
* Use SecureSocket supportedProtocols to save a round trip when establishing a secure connection.
* Allow passing http2 `ServerSettings` to `Server.serve`.

## 2.0.3

* GrpcError now implements Exception to indicate it can be reasonably handled.

## 2.0.2

* Fix computation of the audience given to metadata providers to include the scheme.

## 2.0.1

* Fix computation of authority. This should fix authorization.

## 2.0.0+1

* Fix imports to ensure `grpc_web.dart` has no accidental transitive dependencies on dart:io.

## 2.0.0

* Add initial support for grpc-web.
  See `example/grpc-web` for an example of this working.
* **Breaking**: `grpc.dart` no longer exposes `ClientConnection`. It was supposed to be an internal
  abstraction.
* **Breaking**: `grpc.dart` no longer exposes the deprecated `ServerHandler`.
  It was supposed to be an internal abstraction.
* `service_api.dart` no longer exports Server - it has never been used by the generated code.

## 1.0.3

* Allow custom user agent with a `userAgent` argument for `ChannelOptions()`.
* Allow specifying `authority` for `ChannelCredentials.insecure()`.
* Add `userAgent` as an optional named argument for `clientConnection.createCallHeaders()`.

## 1.0.2

* Fix bug where the server would crash if the client would break the connection.

## 1.0.1

* Add `service_api.dart` that only contains the minimal imports needed by the code generated by
  protoc_plugin.

## 1.0.0+1

* Support package:http2  1.0.0.

## 1.0.0

* Graduate package to 1.0.

## 0.6.8+1

* Removes stray files that where published by accident in version 0.6.8.

## 0.6.8

* Calling `terminate()` or `shutdown()` on a channel doesn't throw error if the
channel is not yet open.

## 0.6.7

* Support package:test 1.5.

## 0.6.6

* Support `package:http` `>=0.11.3+17 <0.13.0`.
* Update `package:googleapis_auth` to `^0.2.5+3`.

## 0.6.5

* Interceptors are now async.

## 0.6.4

* Update dependencies to be compatible with Dart 2.

## 0.6.3

* Make fields of `StatusCode` const rather than final.

## 0.6.2

* Allow for non-ascii header values.

## 0.6.1

* More fixes to update to Dart 2 core library APIs.

## 0.6.0+1

* Updated implementation to use new Dart 2 APIs using
[dart2_fix](https://github.com/dart-lang/dart2_fix).

## 0.6.0

* Dart SDK upper constraint raised to declare compatibility with Dart 2.0 stable.

## 0.5.0

* Breaking change: The package now exclusively supports Dart 2.
* Fixed tests to pass in Dart 2.
* Added support for Interceptors ([issue #79](https://github.com/grpc/grpc-dart/issues/79)); thanks to [@mogol](https://github.com/mogol) for contributing!

## 0.4.1

* Fixes for supporting Dart 2.

## 0.4.0

* Moved TLS credentials for server into a separate class.
* Added support for specifying the address for the server, and support for
  serving on an ephemeral port.

## 0.3.1

* Split out TLS credentials to a separate class.

## 0.3.0

* Added authentication metadata providers, optimized for use with Google Cloud.
* Added service URI to metadata provider API, needed for Json Web Token generation.
* Added authenticated cloud-to-prod interoperability tests.
* Refactored connection logic to throw initial connection errors early.

## 0.2.1

* Updated generated code in examples using latest protoc compiler plugin.
* Dart 2.0 fixes.
* Changed license to Apache 2.0.

## 0.2.0

* Implemented support for per-RPC metadata providers. This can be used for
  authentication providers which may need to obtain or refresh a token before
  the RPC is sent.

## 0.1.0

* Core gRPC functionality is implemented and passes
[gRPC compliance tests](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md).

The API is shaping up, but may still change as more advanced features are implemented.

## 0.0.1

* Initial version.

This package is in a very early and experimental state. We do not recommend
using it for anything but experiments.
