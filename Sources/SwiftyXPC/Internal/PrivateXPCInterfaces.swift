#if os(macOS) || targetEnvironment(macCatalyst)
import Darwin
import XPC

// Every libxpc function that SwiftyXPC calls without an SDK declaration visible to Swift lives in this file.
//
// Each entry records where its signature comes from, what it does, and the systems it was checked on. A
// `@_silgen_name` declaration is an ordinary undefined symbol, so a function missing from the system's libxpc would
// stop every client of this library from launching: confirm a new entry exists on the deployment floor (macOS 12)
// before adding it.

// MARK: - Unpublished SPI

/// Reads the audit token of the peer process that most recently sent a message over `connection`.
///
/// - Source: exported by libxpc since macOS 10.8 but declared in no SDK header; present in the macOS 12.0.1, 13.0,
///   27.0 and 27.2 shared caches.
/// - Behavior: libxpc overwrites the cached token each time a message arrives on the connection
///   (`_xpc_connection_set_creds`, called from `_xpc_connection_mach_event`), so the token can belong to a message
///   that arrived after the one being handled. Use `swiftyxpc_xpc_dictionary_get_audit_token` for a particular message.
@_silgen_name("xpc_connection_get_audit_token")
internal func swiftyxpc_xpc_connection_get_audit_token(
    _ connection: xpc_connection_t,
    _ token: UnsafeMutablePointer<audit_token_t>
)

/// Reads the audit token that the kernel attached to a message when it arrived.
///
/// - Source: exported by libxpc but declared in no SDK header; signature recovered by reverse engineering libxpc
///   3298.1.1 (macOS 27.0). Present in the macOS 12.0.1, 13.0, 27.0 and 27.2 shared caches.
/// - Behavior: for a dictionary that was not received from a peer, it writes an invalid token (every field `0xFFFFFFFF`
///   but the process identifier, which is 0). Passing anything but a dictionary is API misuse that crashes the process.
@_silgen_name("xpc_dictionary_get_audit_token")
internal func swiftyxpc_xpc_dictionary_get_audit_token(
    _ message: xpc_object_t,
    _ token: UnsafeMutablePointer<audit_token_t>
)

// MARK: - Published functions that the SDK hides from Swift

/// The peer requirement functions that macOS 26 added to libxpc.
///
/// - Source: `xpc/peer_requirement.h` in the macOS 27.2 SDK. The header marks every function `XPC_SWIFT_NOEXPORT`, which
///   hides it from Swift; the `XPC` module's own `XPCPeerRequirement` keeps the underlying object private.
/// - Why `dlsym`: these functions do not exist before macOS 26, and a `@_silgen_name` declaration is a strong reference
///   that dyld resolves when the library loads, so on an older system no client of this library could launch.
@available(macOS 26.0, macCatalyst 26.0, *)
internal enum PeerRequirementFunctions {
    // `xpc_peer_requirement_t` and `xpc_rich_error_t` are Objective-C objects; they cross as raw pointers. Every
    // `error_out` argument is `NULL`.
    private typealias CreateFromOptionalString = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer?
    private typealias CreateFromStringAndValue = @convention(c) (
        UnsafePointer<CChar>,
        UnsafeMutableRawPointer,
        UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer?
    private typealias CreateFromObject = @convention(c) (
        UnsafeMutableRawPointer,
        UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer?
    private typealias MatchReceivedMessage = @convention(c) (
        UnsafeMutableRawPointer,
        UnsafeMutableRawPointer,
        UnsafeMutableRawPointer?
    ) -> Bool

    private static func lookUp<Function>(_ name: String, as type: Function.Type) -> Function? {
        // RTLD_DEFAULT, which is `((void *) -2)` and does not reach Swift as a constant.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }

        return unsafeBitCast(symbol, to: type)
    }

    private static func pointer(to object: xpc_object_t) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(object as AnyObject).toOpaque()
    }

    /// Creates an `xpc_peer_requirement_t` for `kind`, or returns `nil` if libxpc rejects it.
    ///
    /// Code signing requirements have no `xpc_peer_requirement_t` constructor; `kind` must be something else.
    static func makeRequirement(for kind: XPCPeerRequirement.Kind) -> AnyObject? {
        let requirement: UnsafeMutableRawPointer?

        switch kind {
        case .codeSigning:
            preconditionFailure("libxpc has no peer requirement for a code signing requirement")
        case .entitlementExists(let entitlement):
            guard
                let create = Self.lookUp(
                    "xpc_peer_requirement_create_entitlement_exists",
                    as: CreateFromOptionalString.self
                )
            else {
                return nil
            }

            requirement = entitlement.withCString { create($0, nil) }
        case .entitlementMatches(let entitlement, let value):
            guard
                let create = Self.lookUp(
                    "xpc_peer_requirement_create_entitlement_matches_value",
                    as: CreateFromStringAndValue.self
                )
            else {
                return nil
            }

            requirement = withExtendedLifetime(value) {
                entitlement.withCString { create($0, Self.pointer(to: value), nil) }
            }
        case .teamIdentity(let signingIdentifier), .platformIdentity(let signingIdentifier):
            let name: String

            if case .teamIdentity = kind {
                name = "xpc_peer_requirement_create_team_identity"
            } else {
                name = "xpc_peer_requirement_create_platform_identity"
            }

            guard let create = Self.lookUp(name, as: CreateFromOptionalString.self) else {
                return nil
            }

            if let signingIdentifier {
                requirement = signingIdentifier.withCString { create($0, nil) }
            } else {
                requirement = create(nil, nil)
            }
        case .lightweightCodeRequirement(let lightweightCodeRequirement):
            guard
                xpc_get_type(lightweightCodeRequirement) == XPC_TYPE_DICTIONARY,
                let create = Self.lookUp("xpc_peer_requirement_create_lwcr", as: CreateFromObject.self)
            else {
                return nil
            }

            requirement = withExtendedLifetime(lightweightCodeRequirement) {
                create(Self.pointer(to: lightweightCodeRequirement), nil)
            }
        }

        // The constructors return a retained object.
        return requirement.map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
    }

    /// Returns whether the sender of `message`, a dictionary received from a peer, satisfies `requirement`.
    static func message(_ message: xpc_object_t, satisfies requirement: AnyObject) -> Bool {
        guard
            let match = Self.lookUp(
                "xpc_peer_requirement_match_received_message",
                as: MatchReceivedMessage.self
            )
        else {
            return false
        }

        return withExtendedLifetime((message, requirement)) {
            match(Unmanaged.passUnretained(requirement).toOpaque(), Self.pointer(to: message), nil)
        }
    }
}
#endif
