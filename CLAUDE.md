# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftyXPC is a Swift Concurrency-first wrapper around Apple's `libxpc`. It is a Swift Package (`swift-tools-version:5.7`) that targets macOS 10.15+ / macCatalyst 13+ and links only against `XPC` and `Security` — there is no Foundation dependency in the library target itself. The codebase deliberately avoids Foundation/Objective-C bridging so that code signing verification is done through `libxpc` / Security rather than `NSXPCConnection`.

## Build, Test, Format

Per user global guidance (Xcode three-level fallback), prefer in order: `xcodebuildmcp` CLI → `xcodebuild`/`swift` piped through `xcsift` → raw commands. Always run `swift package update` before `swift build` / `swift test`.

```bash
swift package update
swift build 2>&1 | xcsift
swift test  2>&1 | xcsift
```

Run a single test:

```bash
swift test --filter SwiftyXPCTests.testSimpleRequestAndResponse 2>&1 | xcsift
```

Format:

```bash
swift format --in-place --recursive --configuration .swift-format Sources Tests
```

`.swift-format` enforces 125-column width, 4-space indentation, `AllPublicDeclarationsHaveDocumentation`, `BeginDocumentationCommentWithOneLineSummary`, and `ValidateDocumentationComments` — all public symbols in `Sources/SwiftyXPC/` must carry doc comments with a one-line summary.

## Test Topology (important)

The test target exercises a real Mach service, not a mock. `Tests/SwiftyXPCTests/HelperLauncher.swift` writes a launchd plist to `/tmp` pointing at the `TestHelper` executable produced by SPM, then invokes `/bin/launchctl load` / `unload` around each test run. Consequences:

- Tests must run on real macOS with permission to `launchctl load`. They will not pass in a sandbox / CI without launchd privileges.
- If a test leaves the helper loaded (crash, debugger abort), the next run's `load` fails with "Load failed:" and `HelperLauncher` self-heals by issuing an `unload` first. If that also fails, check `launchctl list | rg SwiftyXPC` and `launchctl unload` the stale plist manually.
- The Mach service name is `com.charlessoft.SwiftyXPC.TestHelper` (`Sources/TestShared/HelperID.swift`). Message names are centralized in `Sources/TestShared/CommandSet.swift` and shared between helper and test so that compile-time typos can't occur.
- Code signature verification tests derive the expected requirement from the built helper binary at runtime (`SecCodeCopyDesignatedRequirement`), so they adapt to whatever identity signs the test build.

## Architecture — What You Must Understand Before Editing

### Request/response is string-name routing over Codable payloads

The public surface is `XPCConnection` and `XPCListener`. Both expose `setMessageHandler(name:handler:)` variants that take `async throws` closures with `Codable` request and response types. A sent message is an `xpc_dictionary_t` with three well-known keys (private to `XPCConnection`):

- `MessageKeys.name` — the handler name string
- `MessageKeys.body` — the `XPCEncoder`-encoded request (or response)
- `MessageKeys.error` — a `BoxedError` payload when the handler threw

The type-erased handler storage is `XPCConnection.MessageHandler`, which captures the concrete `Request`/`Response` types inside a `RawHandler` closure. When a message arrives, `XPCConnection.handleEvent` dispatches through `respond(to:)`, which spins a `Task` to call the handler, then calls `sendOnewayRawMessage(...)` to reply. Errors thrown from the handler are funneled through `XPCErrorRegistry.shared.encodeError(_:)` and sent on the reply dictionary.

### XPCListener has three backings — know which one you're dealing with

`XPCListener.Backing` is a private enum with three cases driven by `ListenerType`:

1. `.service` → `.xpcMain`. Calls `xpc_main`. Cannot be cancelled/suspended/resumed (all are `fatalError`). Stores itself in a global (`xpcMainListenerStorage`) because `xpc_main` takes a C function pointer with no context. Message handlers are copied into each incoming `XPCConnection`.
2. `.machService(name:)` → `.connection(..., isMulti: true)`. Uses `XPC_CONNECTION_MACH_SERVICE_LISTENER`. Each incoming peer becomes a new `XPCConnection` wired with copies of the listener's handlers.
3. `.anonymous` → `.connection(..., isMulti: false)`. The listener *is* the single connection; handlers are stored directly on that connection, not on the listener's `_messageHandlers` dictionary.

The `isMulti` flag determines whether `setMessageHandler` on the listener writes to `_messageHandlers` (case 1, 2) or forwards to `connection.messageHandlers` (case 3). Getters for `messageHandlers`/`errorHandler` do the same routing. Any new listener-level state must preserve this split.

### Code-signing verification has two code paths

- macOS 12+: `xpc_connection_set_peer_code_signing_requirement` is called at connection init. If the requirement string fails to parse, init throws `XPCError.invalidCodeSignatureRequirement`. Runtime verification is handled inside libxpc.
- macOS 10.15 / 11: `XPCConnection.checkCallerCredentials(event:)` runs on every incoming event. On 11+ it uses `SecCodeCreateWithXPCMessage`; on 10.15 it falls back to building a guest attributes dictionary keyed by PID and calling `SecCodeCopyGuestWithAttributes`. Failures surface as `XPCConnection.Error.callerFailedCredentialCheck(OSStatus)`.

Do not collapse these into one path without preserving both behaviors — the whole reason this library exists instead of `NSXPCConnection` is trustworthy peer code signing across OS versions.

### Error transport via XPCErrorRegistry

Custom error types only round-trip across the wire if **both** sides register them:

```swift
XPCErrorRegistry.shared.registerDomain(forErrorType: MyError.self)
```

`BoxedError` stores either a `.codable(Error & Codable)` payload (when the domain was registered) or a `.uncodable(code: Int)` fallback that mirrors `NSError` shape without requiring Foundation. The registry itself uses `Mutex` on macOS 15+ and a `DispatchSemaphore`-backed `LegacyWrapper` below that, selected at init time via `#available`. Two error types are pre-registered: `XPCError` and `XPCConnection.Error`.

### Codable ↔ xpc_object_t encoding

`XPCEncoder`/`XPCDecoder` (roughly 24k / 30k lines of generated-ish container code) bridge Swift `Codable` to the XPC type system (`XPC_TYPE_INT64`, `XPC_TYPE_UINT64`, `XPC_TYPE_DOUBLE`, `XPC_TYPE_STRING`, `XPC_TYPE_ARRAY`, `XPC_TYPE_DICTIONARY`, `XPC_TYPE_NULL`, `XPC_TYPE_FD`, `XPC_TYPE_UUID`, `XPC_TYPE_DATA`, `XPC_TYPE_DATE`, `XPC_TYPE_ENDPOINT`). Two types have special encode/decode behavior that bypasses the public `Encoder`/`Decoder` protocol:

- `XPCEndpoint` — its `init(from:)` / `encode(to:)` unconditionally throw, so it may only round-trip through `XPCEncoder`/`XPCDecoder`, which detect the type and insert/extract the raw `xpc_endpoint_t`.
- `XPCFileDescriptor` — owned wrapper that calls `close()` in `deinit`. Avoid copying the raw fd out.

When adding new Codable container support, keep both coders symmetric and update `XPCType` if you introduce a new XPC type surface.

### Activation discipline

Every `XPCConnection` and `XPCListener` starts inactive. The public API requires `.activate()` before any send/receive. Tests, the example app, and `TestHelper` all follow this ordering: configure handlers → set `errorHandler` → `.activate()`. The only exception is `MessageSender` in the example app, which calls `.resume()` (legacy pattern); new code should prefer `.activate()`.

## Conventions and Gotchas

- **No Foundation in library sources.** `Sources/SwiftyXPC/` imports `XPC`, `Security`, `System`, `Darwin`, `os`, `Synchronization`. Adding `import Foundation` to the library target reverses a deliberate design choice; put Foundation-dependent helpers in an extension target or in clients instead.
- **`@unchecked Sendable` on `XPCConnection` and `XPCEndpoint`** is load-bearing — the underlying `xpc_connection_t` / `xpc_endpoint_t` are ObjC objects whose thread-safety is guaranteed by libxpc, not the Swift compiler. Do not remove the annotation without an alternative isolation strategy.
- **Message handler Task lifetime.** `respond(to:)` wraps incoming dispatch in an unstructured `Task {}`. There is no cancellation propagation from the remote side — a cancelled connection does not cancel in-flight handler tasks. If adding cooperative cancellation, add it explicitly; do not assume it exists.
- **Deprecated API:** `XPCConnection.sendOnewayMessage(message:name:)` (argument order reversed) is deprecated in favor of `sendOnewayMessage(name:message:)`. New call sites should use the named-first form.
- **`SwiftyXPC/Extensions/` at the repo root (not under `Sources/`) is empty** and exists only because the Xcode project references it. The SPM-visible extension lives at `Sources/SwiftyXPC/Extensions/String+SwiftyXPC.swift`.
- **The example app is a separate Xcode project** at `Example App/Example App.xcodeproj` with its own embedded XPC service target. It's not built by `swift build` and uses a different bundle ID (`com.charlessoft.SwiftyXPC.Example-App.xpc`) from the test helper.

## Reference for XPC Internals

If you need to reverse-engineer libxpc or verify runtime behavior (code signing peer checks, event handler semantics, mach service lookup), route through IDA MCP headless per the user's global guidance before attempting `otool`/`nm`/`jtool2` fallbacks.
