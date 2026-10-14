# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftyXPC is a Swift Concurrency-first wrapper around Apple's `libxpc`. It is a Swift Package (`swift-tools-version:6.2`) that targets macOS 12+ / macCatalyst 15+ and links only against `XPC` and `Security` — there is no Foundation dependency in the library target itself. The codebase deliberately avoids Foundation/Objective-C bridging so that code signing verification is done through `libxpc` / Security rather than `NSXPCConnection`.

### Language mode

The test, helper, and shared targets build in the Swift 6 language mode. The library target builds in the Swift 5 mode with every Swift 6 upcoming feature enabled *except* `ImportObjcForwardDeclarations` (see `Package.swift`): with that feature on, Swift 6.4 crashes in IRGen whenever a module that does not import Foundation needs type metadata for an XPC object type (a stored `xpc_object_t`, an array or optional of one handed to generic code, a cast to one). All targets also enable `NonisolatedNonsendingByDefault`. Do not move the library to `.v6` until that compiler crash is fixed; the full Swift 6 data-race checking is already on.

## Build, Test, Format

Per user global guidance (Xcode three-level fallback), prefer in order: `xcodebuildmcp` CLI → `xcodebuild`/`swift` piped through `xcsift` → raw commands. Always run `swift package update` before `swift build` / `swift test`.

```bash
swift package update
swift build 2>&1 | xcsift
swift test  2>&1 | xcsift
```

Run a single test (tests use Swift Testing; filter by the test's display name):

```bash
swift test --filter "Simple request and response" 2>&1 | xcsift
```

Format:

```bash
swift format --in-place --recursive --configuration .swift-format Sources Tests
```

`.swift-format` enforces 125-column width, 4-space indentation, `AllPublicDeclarationsHaveDocumentation`, `BeginDocumentationCommentWithOneLineSummary`, and `ValidateDocumentationComments` — all public symbols in `Sources/SwiftyXPC/` must carry doc comments with a one-line summary.

## Test Topology (important)

The tests use Swift Testing. Suites that need no other process (`CoderRoundTripTests`, `MessageDeliveryTests`) run against an anonymous listener in the test process. `SwiftyXPCTests` exercises a real Mach service, not a mock: the `LaunchedTestHelper` suite trait in `Tests/SwiftyXPCTests/HelperLauncher.swift` writes a launchd plist to the temporary directory pointing at the `TestHelper` executable produced by SPM, then invokes `/bin/launchctl load` before the suite and `unload` after it. Consequences:

- Tests must run on real macOS with permission to `launchctl load`. They will not pass in a sandbox / CI without launchd privileges.
- If a test leaves the helper loaded (crash, debugger abort), the next run's `load` fails with "Load failed:" and `HelperLauncher` self-heals by issuing an `unload` first. If that also fails, check `launchctl list | rg SwiftyXPC` and `launchctl unload` the stale plist manually.
- The Mach service name is `com.charlessoft.SwiftyXPC.TestHelper` (`Sources/TestShared/HelperID.swift`). Message names are centralized in `Sources/TestShared/CommandSet.swift` and shared between helper and test so that compile-time typos can't occur.
- Code signature verification tests derive the expected requirement from the built helper binary at runtime (`SecCodeCopyDesignatedRequirement`), so they adapt to whatever identity signs the test build.

## Architecture — What You Must Understand Before Editing

### Request/response is string-name routing over Codable payloads

The public surface is `XPCConnection` and `XPCListener`. Both expose `setMessageHandler(name:handler:)` variants that take `@Sendable async throws` closures whose first argument is an `XPCMessageContext` (the connection, the message name, and the sender's identity read from *this* message's audit token) and whose request is `Decodable` and passed as `sending`; the response is `Encodable`. Handler generic parameters are also `SendableMetatype`, because the closure decodes and encodes on the connection's executor. The response is deliberately *not* `sending`: Swift 6.4 refuses to convert a method reference such as `self.sayHello` to a function type with a `sending` result, even for a `Sendable` type. `sendMessage` is `nonisolated(nonsending)`, encodes the request in the caller's isolation, and decodes the reply there too, returning it as `sending`. A sent message is an `xpc_dictionary_t` with three well-known keys (private to `XPCConnection`):

- `MessageKeys.name` — the handler name string
- `MessageKeys.body` — the `XPCEncoder`-encoded request (or response)
- `MessageKeys.error` — a `BoxedError` payload when the handler threw
- `MessageKeys.protocolVersion` — `int64` 1 on every message and reply that 1.0 sends; never required on receipt

**The wire format is a contract with SwiftyXPC 0.5 peers** (helpers are often updated separately from their apps): do not rename keys, change how existing types encode, or rely on the protocol version being present. A nameless, versionless, body-only message without a reply context is the stray answer a 0.5 receiver sends for every one-way message — `receive(_:)` drops it silently; a nameless message with an `error` key is a 0.5 receiver reporting its one-way handler's error and is passed to `errorHandler`. New `XPCError` / `XPCConnection.Error` cases are visible to 0.5 peers, whose decoder traps on a case it does not know — avoid sending new cases to them. `WireCompatibilityTests` pins the format in-process; `Tests/Interop/` has two clients and a README for checking it end to end against a real 0.5.105 build.

The type-erased handler storage is `XPCConnection.MessageHandler`, which captures the concrete `Request`/`Response` types inside a `RawHandler` closure. Handlers live in a `HandlerTable` (locked). When a message arrives, `XPCConnection.handleEvent` hands it to `receive(_:)`, which routes it by name and dispatches a job to the connection's `MessageDispatcher` (below); when the handler finishes, `complete(_:with:reportingUnansweredFailure:)` answers it. Only a message whose sender waits for a reply (`xpc_dictionary_create_reply` returns non-`NULL`) is ever answered:

- a handler's result or error goes back on the reply dictionary; errors are funneled through `XPCErrorRegistry.shared.encodeError(_:)`, and an error that fails to encode is sent as its domain and code alone while the encoding failure goes to this side's `errorHandler`;
- a message with no name, or no handler for its name, is answered with `XPCConnection.Error.missingMessageName` / `.unexpectedMessage` (and also reported to this side's `errorHandler`), so the sender never mistakes it for `connectionInterrupted`;
- a one-way message is never answered; its handler's error goes to this side's `errorHandler`. Never send anything "back" for a one-way message: the old code did, as a nameless message the sender could only report as `missingMessageName`.

### Message dispatch: one serial executor per connection, handlers start in arrival order

Each `XPCConnection` owns a `MessageDispatcher` (`Sources/SwiftyXPC/Internal/MessageDispatcher.swift`), an actor whose executor is a serial dispatch queue that is also the connection's XPC target queue. `dispatch(_:)` appends the job to a locked FIFO and starts a task on the actor (`Task.immediate` on macOS 26+, `Task(operation: self.startOldestJob)` before); the task pops the *oldest* pending job and runs it synchronously until its first suspension point. Because popping and starting happen atomically on the actor, jobs start in arrival order whatever order the tasks run in; a job that awaits lets the next one start. Handler closures are `nonisolated(nonsending)` (the package enables `NonisolatedNonsendingByDefault`), so they run on the dispatcher's executor.

- Executors: `DispatchSerialQueue`'s own executor on macOS 14+, the in-house `QueueExecutor` on 12–13.
- Do **not** call `assumeIsolated` from the XPC event handler: before macOS 15 the runtime cannot recognize a dispatch block as running on an actor's queue and traps. Partial application (`self.startOldestJob`) is what puts the task straight onto the actor.
- Do **not** switch to a default actor: it runs jobs by priority, and XPC delivers each message at its sender's QoS.
- `MessageDispatcher.Strategy` forces the macOS 14–25 (`.serialQueueExecutor`) or 12–13 (`.queueExecutor`) path; `XPCConnection` / `XPCListener` take it through internal initializers so `DispatchTests` can run the ordering test on every path. Keep that test parameterized over `Strategy.allCases`.

### XPCListener: two backings, one shared handler table

`XPCListener.Backing` is `.xpcMain` (for `.service`) or `.connection(XPCConnection)` (for `.anonymous` and `.machService`). The listener's message handlers and error handler live in a `HandlerTable` that every accepted connection consults *after* its own table, at message time — so handlers set on the listener after a peer connected still reach that peer, and a peer without its own `errorHandler` uses the listener's.

1. `.service` → `.xpcMain`. Calls `xpc_main`. Cannot be cancelled/suspended/resumed (all are `fatalError`). Stores itself in a locked global (`xpcMainListener`) because `xpc_main` takes a C function pointer with no context.
2. `.machService(name:)` / `.anonymous` → `.connection`. The listener's own connection gets a `listenerEventHandler` (built by `makeConnectionAcceptor`) that turns each `XPC_TYPE_CONNECTION` event into an accepted `XPCConnection` and routes every other event to the listener's `errorHandler`. The acceptor captures the listener's parts, not the listener, which does not exist yet when its connection is made.

`XPCListener` is `Sendable`: every stored property is immutable or locked.

### Peer verification is done by libxpc

`XPCConnection.init(type:requirement:)` / `XPCListener.init(type:requirement:)` take an `XPCPeerRequirement`: `.codeSigning(_:)` (macOS 12+) or, from macOS 14.4, `.hasEntitlement`, `.entitlement(_:matches:)`, `.isFromSameTeam`, `.isPlatformCode`, `.lightweightCodeRequirement`. `XPCPeerRequirement.apply(to:)` calls the matching `xpc_connection_set_peer_*_requirement` once per connection (XPC forbids a second call). A listener applies its requirement to its own connection and to every accepted one. If XPC rejects the requirement, init throws `XPCError.invalidCodeSignatureRequirement` / `.invalidPeerRequirement` — after setting a no-op handler, activating, and cancelling the connection, because releasing a never-activated connection is API misuse that crashes. At run time libxpc drops requests from peers that fail and answers a waiting sender with `XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT` (surfaced as `XPCError.unknown("Peer Forbidden")`). The old `init(type:codeSigningRequirement:)` initializers remain, deprecated, for all of 1.x.

`XPCMessageContext.senderSatisfies(_:)` (macOS 26+) checks one received message: code signing requirements through Security (`SecCodeCreateWithXPCMessage`), everything else through the macOS 26 `xpc_peer_requirement_*` functions. Those are `XPC_SWIFT_NOEXPORT` in the SDK and absent before macOS 26, so `PeerRequirementFunctions` looks them up with `dlsym` — never declare them with `@_silgen_name`, which would make the library fail to load on macOS 12–25.

`XPCError.connectionInvalid(reason:)` carries `xpc_connection_copy_invalidation_reason` when the connection that delivered the error is known (`XPCConnection.error(fromEvent:)`). The macOS 10.15 / 11 fallback that checked each message with Security.framework is gone with the macOS 12 deployment floor; `XPCConnection.Error.callerFailedCredentialCheck` remains only as a deprecated case.

### Error transport via XPCErrorRegistry

Custom error types only round-trip across the wire if **both** sides register them:

```swift
XPCErrorRegistry.shared.registerDomain(forErrorType: MyError.self)
```

`BoxedError` stores either a `.codable(Error & Codable)` payload (when the domain was registered) or a `.uncodable(code: Int)` fallback that mirrors `NSError` shape without requiring Foundation. The registry's domain map lives in a `LockedState` (`Sources/SwiftyXPC/Internal/LockedState.swift`), which uses `Mutex` on macOS 15+ and a heap-allocated `os_unfair_lock` below that. Two error types are pre-registered: `XPCError` and `XPCConnection.Error`.

### Codable ↔ xpc_object_t encoding

`XPCEncoder`/`XPCDecoder` (roughly 24k / 30k lines of generated-ish container code) bridge Swift `Codable` to the XPC type system (`XPC_TYPE_INT64`, `XPC_TYPE_UINT64`, `XPC_TYPE_DOUBLE`, `XPC_TYPE_STRING`, `XPC_TYPE_ARRAY`, `XPC_TYPE_DICTIONARY`, `XPC_TYPE_NULL`, `XPC_TYPE_FD`, `XPC_TYPE_UUID`, `XPC_TYPE_DATA`, `XPC_TYPE_DATE`, `XPC_TYPE_ENDPOINT`). Values that must travel as XPC objects of their own conform to the public `XPCObjectRepresentable` protocol (`XPCEndpoint`, `XPCFileDescriptor`, `XPCNull`):

- The protocol's default `encode(to:)` / `init(from:)` recognize the coders' internal `_XPCEncoder` / `_XPCDecoder` and put / take the raw object, so the value survives any number of wrappers that forward `encode(to:)` (property wrappers do). Any other coder gets an `EncodingError` / `DecodingError` — never a silently encoded descriptor number.
- The containers also short-circuit `any XPCObjectRepresentable` (and System's `FileDescriptor`, which cannot conform) through `standaloneObject(for:)` / `decodeStandaloneObject(_:xpc:)`; both paths must keep producing the same object.
- `XPCFileDescriptor` is an owned wrapper that calls `close()` in `deinit`; decoding always `xpc_fd_dup`s. Avoid copying the raw fd out.

The decoder reads data from other processes, so it must throw, never trap, on anything a peer can send: wrong types (a keyed container checks for a dictionary when it is created), keys the receiving type does not know (`allKeys` skips them — this is how a newer peer's enum case arrives), and reads past the end of packed bytes. A `BoxedError` whose payload cannot be decoded falls back to its domain and code. When adding new Codable container support, keep both coders symmetric and update `XPCType` if you introduce a new XPC type surface.

### Activation discipline

Every `XPCConnection` and `XPCListener` starts inactive. The public API requires `.activate()` before any send/receive. Tests, the example app, and `TestHelper` all follow this ordering: configure handlers → set `errorHandler` → `.activate()`.

## Conventions and Gotchas

- **No Foundation in library sources.** `Sources/SwiftyXPC/` imports `XPC`, `Security`, `System`, `Darwin`, `Dispatch`, `os`, `Synchronization`. Adding `import Foundation` to the library target reverses a deliberate design choice; put Foundation-dependent helpers in an extension target or in clients instead.
- **`@unchecked Sendable` on `XPCConnection`, `XPCEndpoint`, and `XPCMessageContext`** is load-bearing — they hold XPC objects whose thread-safety is guaranteed by libxpc, not the Swift compiler. All their other state is immutable or behind `LockedState`. Do not add unlocked mutable state.
- **libxpc functions without a Swift declaration** live only in `Sources/SwiftyXPC/Internal/PrivateXPCInterfaces.swift`, each with its source and the systems it was checked on. `@_silgen_name` is a hard undefined symbol: a function missing from macOS 12's libxpc would stop every client from launching, so check the macOS 12 shared cache (`/Volumes/DyldSharedCaches/macOS/12.0.1`) before adding one, and use `dlsym` for anything newer than the deployment floor.
- **Name clashes with Apple's `XPC` module.** `XPCListener`, `XPCEndpoint`, and `XPCPeerRequirement` also exist in Apple's Swift `XPC` overlay. A file that imports both `XPC` and `SwiftyXPC` must spell them `SwiftyXPC.XPCListener` and so on (the tests do).
- **Message handler task lifetime.** There is no cancellation propagation from the remote side — a cancelled connection does not cancel in-flight handler tasks, and cancelling a task that awaits `sendMessage` does not cancel the XPC message. If adding cooperative cancellation, add it explicitly; do not assume it exists.
- **Removed API:** `XPCConnection.sendOnewayMessage(message:name:)` is gone, and `sendOnewayMessage(name:message:)` requires a name: a message without one cannot be routed.
- **`SwiftyXPC/Extensions/` at the repo root (not under `Sources/`) is empty** and exists only because the Xcode project references it. The SPM-visible extension lives at `Sources/SwiftyXPC/Extensions/String+SwiftyXPC.swift`.
- **The example app is a separate Xcode project** at `Example App/Example App.xcodeproj` with its own embedded XPC service target. It's not built by `swift build`, uses a different bundle ID (`com.charlessoft.SwiftyXPC.Example-App.xpc`) from the test helper, references this package through a local package reference (`relativePath = ..`), and builds in the Swift 6 language mode. Check it compiles after any public API change: `xcodebuild -project "Example App/Example App.xcodeproj" -scheme "Example App" -derivedDataPath <agent path> CODE_SIGNING_ALLOWED=NO build`.
- **Thread Sanitizer.** After touching dispatch, locking, or handler storage, run the suite once with `swift test --sanitize=thread` (use a separate scratch path; it rebuilds everything).
- **Design history.** Why the dispatcher, the language mode, the peer requirement plumbing, and the 0.5 compatibility rules look the way they do is recorded in `Documentations/Internal/Version1Implementation.md`; the decision record is the evolution proposal it links to.

## Reference for XPC Internals

If you need to reverse-engineer libxpc or verify runtime behavior (code signing peer checks, event handler semantics, mach service lookup), route through IDA MCP headless per the user's global guidance before attempting `otool`/`nm`/`jtool2` fallbacks.
