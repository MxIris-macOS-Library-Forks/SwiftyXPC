# SwiftyXPC

## Hmm, what’s this?

SwiftyXPC is a wrapper for Apple’s XPC interprocess communication library that gives it an easy-to-use, idiomatic Swift interface.

## But there’s already `NSXPCConnection`!

Well, yes, but with its protocol-and-proxy-based interface, it’s far better suited to Objective-C than Swift.
Using `NSXPCConnection` from Swift has always felt somewhat awkward, and with the advent of Swift Concurrency, it’s even worse, given that everything has to be wrapped in `withCheckedThrowingContinuation` blocks.
`NSXPCConnection` has also tended to be behind `libxpc` in certain important ways—notably, in the ability to verify the code signature of a remote process via an audit token.

By contrast, SwiftyXPC:
- Offers a fully Swift Concurrency-aware interface. Use `try` and `await` to call your helper code with no closures necessary, and pass values that aren’t `Sendable` without the compiler objecting.
- Gives you a straightforward interface for your helper functions; take an argument, return a value async. No fussing around with Objective-C selectors and reply blocks.
- Built around the `Codable` protocol, so you can use any types you want for the argument and return value, as long as both types conform to `Codable`, and it Just Works™. Error types are preserved as well, if they are `Codable` and you register their domains with the shared `XPCErrorRegistry` object.
- Lets XPC itself check who is on the other end — by code signing requirement, entitlement, team, or lightweight code requirement — and tells each handler which process sent its message.
- Only links against XPC and Security (the latter for the code signature validation), so there’s no need to link Foundation into your app, deal with Objective-C bridging magic, or involve the Objective-C runtime at all (excluding any places where XPC or the Security framework may be using it internally).

## Requirements

- macOS 12 or Mac Catalyst 15, or later.
- Swift 6.2 (Xcode 26) or later.

Some features need a newer system: peer requirements other than code signing requirements need macOS 14.4, and checking the sender of an individual message needs macOS 26.

## Getting started

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC", from: "1.0.0")
```

In the helper — an XPC service, a launchd agent, or a daemon — set up a listener:

```swift
import SwiftyXPC

let listener = try XPCListener(
    type: .machService(name: "com.example.helper"),
    requirement: .codeSigning(#"anchor apple generic and identifier "com.example.app""#)
)

listener.setMessageHandler(name: "com.example.capitalize") { (context, text: String) in
    text.uppercased()
}

listener.activate()
dispatchMain()
```

In the app, connect and send:

```swift
let connection = try XPCConnection(
    type: .remoteMachService(serviceName: "com.example.helper", isPrivilegedHelperTool: true),
    requirement: .codeSigning(#"anchor apple generic and identifier "com.example.helper""#)
)
connection.activate()

let shout: String = try await connection.sendMessage(name: "com.example.capitalize", request: "hello")
```

A request needs to be `Encodable` where it is sent and `Decodable` where it is handled, and a response the other way round. Use `sendOnewayMessage(name:message:)` for a message that needs no answer.

An error that a handler throws reaches the sender. It arrives as its own type if it is `Codable` and both sides register its domain:

```swift
XPCErrorRegistry.shared.registerDomain(forErrorType: MyError.self)
```

Otherwise it arrives as an `XPCErrorRegistry.BoxedError` with the original error’s domain and code.

## How handlers run

- Every connection has a serial executor of its own. The handlers for the messages that arrive on a connection *start in the order the messages arrive*, and run on that executor until they suspend: while one handler awaits, the handler for the next message can start, just as with `NSXPCConnection`. A handler that must not overlap with others should not suspend, or should coordinate through an actor of its own.
- Handlers and error handlers are `@Sendable`, because XPC calls them on its own threads. A request reaches its handler as a `sending` value, so its type does not need to be `Sendable`.
- `sendMessage` runs in the caller’s isolation domain and returns its response as a `sending` value, so you can call it from an actor and pass values that are not `Sendable`.
- A one-way message gets no answer. Whatever its handler returns is discarded, and an error it throws goes to the *receiving* connection’s `errorHandler`.
- A message whose name no handler is registered for is answered with `XPCConnection.Error.unexpectedMessage`.
- Cancelling the task that awaits `sendMessage` does not cancel the message.
- Handlers can be set at any time, also after activation. Handlers set on a listener apply to every connection it has accepted or will accept.

## Who sent this message?

Every handler receives an `XPCMessageContext`:

- `processIdentifier`, `effectiveUserIdentifier`, `effectiveGroupIdentifier`, `auditSessionIdentifier`, and `auditToken` describe the process that sent *this* message. The connection’s own properties of the same names follow the most recent message on the connection, which may be a later one by the time the handler reads them.
- `connection` is the connection the message arrived on, to send messages back.
- `expectsReply` tells a request from a one-way message.
- On macOS 26, `senderSatisfies(_:)` checks the sender of this message against an `XPCPeerRequirement`.

## Peer requirements

Pass an `XPCPeerRequirement` when you create a connection or a listener, and XPC checks every message against it. A listener drops requests from peers that fail it; a sender that waits for a reply from such a peer gets `XPCError.unknown("Peer Forbidden")`.

| Requirement | Available |
|---|---|
| `.codeSigning(_:)` — a [code signing requirement](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) | macOS 12 |
| `.hasEntitlement(_:)`, `.entitlement(_:matches:)` | macOS 14.4 |
| `.isFromSameTeam(andMatchesSigningIdentifier:)` | macOS 14.4 |
| `.isPlatformCode(andMatchesSigningIdentifier:)` | macOS 14.4 |
| `.lightweightCodeRequirement(_:)` — a [launch constraint](https://developer.apple.com/documentation/security/defining_launch_environment_and_library_constraints) dictionary | macOS 14.4 |

A connection takes one requirement. To combine several constraints, write them into one code signing requirement or one lightweight code requirement. A requirement that XPC rejects makes the initializer throw `XPCError.invalidCodeSignatureRequirement` or `XPCError.invalidPeerRequirement`.

## Values that travel as XPC objects

Some values only make sense as native XPC objects. `XPCFileDescriptor` (and `FileDescriptor` from the System module) gives the receiving process its own duplicate of a file descriptor; `XPCEndpoint` lets the receiver connect back to a listener. Make your own types travel this way by conforming them to `XPCObjectRepresentable`. Such values work wherever they sit in a message, including behind property wrappers, but only `XPCEncoder` and `XPCDecoder` can encode and decode them.

## Name clashes with Apple’s `XPC` module

Apple’s `XPC` module has its own `XPCListener`, `XPCEndpoint`, and `XPCPeerRequirement`, and Foundation makes that module visible. In a file that imports Foundation or XPC as well as SwiftyXPC, spell these types `SwiftyXPC.XPCListener` and so on where a type is expected, such as in a type annotation. Calls like `XPCListener(type: .anonymous)` and members like `.codeSigning(_:)` need no prefix.

## Migrating from 0.5

| 0.5 | 1.0 |
|---|---|
| `XPCConnection(type: t, codeSigningRequirement: s)` | `XPCConnection(type: t, requirement: .codeSigning(s))` — the old initializer is deprecated and stays through 1.x |
| `XPCListener(type: t, codeSigningRequirement: s)` | `XPCListener(type: t, requirement: .codeSigning(s))` — likewise |
| `setMessageHandler(name: n) { (connection: XPCConnection, request: R) in … }` | `setMessageHandler(name: n) { (context: XPCMessageContext, request: R) in … }`, with `context.connection` for the connection |
| Handlers and error handlers that capture non-`Sendable` state | Make the captured state `Sendable`, or move it into an actor |
| `sendOnewayMessage(message: m, name: n)` | `sendOnewayMessage(name: n, message: m)` |
| `sendOnewayMessage(name: nil, message: m)` | A name is required |
| `case .connectionInvalid` | Still matches; `case .connectionInvalid(let reason)` also gets XPC’s reason |
| `XPCFileDescriptor` encoded by another encoder | Throws an error instead of encoding a meaningless descriptor number |
| macOS 10.15 / Mac Catalyst 13 | macOS 12 / Mac Catalyst 15 |

## Talking to peers that still use 0.5

A 1.0 app can talk to a 0.5 helper and the other way round; the message format is unchanged. The differences:

- A 1.0 receiver no longer answers a one-way message with a stray message of its own, which a 0.5 sender reported as `missingMessageName`; and it answers an unknown message name with `unexpectedMessage`, where a 0.5 sender used to see `connectionInterrupted`.
- A 1.0 sender ignores the stray answer that a 0.5 receiver still sends for every one-way message.
- A 0.5 peer crashes when it decodes a case of `XPCError` or `XPCConnection.Error` that it does not know, such as `invalidPeerRequirement`. Do not let such errors escape a handler that a 0.5 peer calls.

## What happened to macOS 10.15 support?

SwiftyXPC 0.5 supported macOS 10.15 “Catalina”, but current Xcode releases cannot build for anything older than macOS 12, and SwiftyXPC 1.0 requires it.

## What’s the license on this?

MIT.
