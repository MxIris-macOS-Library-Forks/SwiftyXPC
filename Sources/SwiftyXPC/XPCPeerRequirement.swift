#if os(macOS) || targetEnvironment(macCatalyst)
import XPC

/// A requirement that the process on the other end of a connection must satisfy.
///
/// Pass one to `XPCConnection.init(type:requirement:)` or `XPCListener.init(type:requirement:)`. XPC then checks
/// every message: a listener drops requests from peers that fail, and a sender waiting for a reply from such a peer gets
/// an error instead. A connection takes one requirement; to combine several constraints, write them into one code
/// signing requirement string or one lightweight code requirement dictionary.
///
/// Everything but a code signing requirement needs macOS 14.4 or later.
///
/// If your file also imports the `XPC` module, which declares its own `XPCPeerRequirement`, spell this one
/// `SwiftyXPC.XPCPeerRequirement`.
public struct XPCPeerRequirement: Sendable {
    internal enum Kind: @unchecked Sendable {
        // Unchecked because of the XPC objects, which are copied when the requirement is made and never mutated.
        case codeSigning(String)
        case entitlementExists(String)
        case entitlementMatches(String, value: xpc_object_t)
        case teamIdentity(signingIdentifier: String?)
        case platformIdentity(signingIdentifier: String?)
        case lightweightCodeRequirement(xpc_object_t)
    }

    internal let kind: Kind

    private init(_ kind: Kind) {
        self.kind = kind
    }

    /// A code signing requirement, such as `anchor apple generic and identifier "com.example.helper"`.
    ///
    /// See Apple's Technote 3127, "Inside Code Signing: Requirements", for the language.
    ///
    /// - Parameter requirement: The requirement, in the code signing requirement language.
    public static func codeSigning(_ requirement: String) -> XPCPeerRequirement {
        Self(.codeSigning(requirement))
    }

    /// A requirement that the peer has an entitlement, whatever its value.
    ///
    /// - Parameter entitlement: The name of the entitlement.
    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func hasEntitlement(_ entitlement: String) -> XPCPeerRequirement {
        Self(.entitlementExists(entitlement))
    }

    /// A requirement that the peer has a Boolean entitlement with the given value.
    ///
    /// - Parameters:
    ///   - entitlement: The name of the entitlement.
    ///   - value: The value the entitlement must have.
    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func entitlement(_ entitlement: String, matches value: Bool) -> XPCPeerRequirement {
        Self(.entitlementMatches(entitlement, value: xpc_bool_create(value)))
    }

    /// A requirement that the peer has a string entitlement with the given value.
    ///
    /// - Parameters:
    ///   - entitlement: The name of the entitlement.
    ///   - value: The value the entitlement must have.
    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func entitlement(_ entitlement: String, matches value: String) -> XPCPeerRequirement {
        Self(.entitlementMatches(entitlement, value: xpc_string_create(value)))
    }

    /// A requirement that the peer has an integer entitlement with the given value.
    ///
    /// - Parameters:
    ///   - entitlement: The name of the entitlement.
    ///   - value: The value the entitlement must have.
    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func entitlement(_ entitlement: String, matches value: Int64) -> XPCPeerRequirement {
        Self(.entitlementMatches(entitlement, value: xpc_int64_create(value)))
    }

    /// A requirement that the peer is signed with the same team identifier as this process.
    ///
    /// The peer must be signed for the App Store or TestFlight, with an Apple-issued development certificate, or
    /// with a Developer ID certificate.
    ///
    /// - Parameter signingIdentifier: A signing identifier the peer must also have, or `nil` for any.
    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func isFromSameTeam(andMatchesSigningIdentifier signingIdentifier: String? = nil) -> XPCPeerRequirement {
        Self(.teamIdentity(signingIdentifier: signingIdentifier))
    }

    /// A requirement that the peer is signed by Apple as part of the operating system.
    ///
    /// - Parameter signingIdentifier: A signing identifier the peer must also have, or `nil` for any.
    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func isPlatformCode(andMatchesSigningIdentifier signingIdentifier: String? = nil) -> XPCPeerRequirement {
        Self(.platformIdentity(signingIdentifier: signingIdentifier))
    }

    /// A lightweight code requirement, which can combine several constraints.
    ///
    /// The dictionary uses the format of launch constraints; see "Defining launch environment and library constraints"
    /// in Apple's documentation. For example, this requires a peer signed with Team ID `8XCUU22SN2` or a peer that is
    /// part of the operating system:
    ///
    ///     let alternatives = xpc_dictionary_create_empty()
    ///     xpc_dictionary_set_string(alternatives, "team-identifier", "8XCUU22SN2")
    ///     xpc_dictionary_set_int64(alternatives, "validation-category", 1)
    ///     let requirement = xpc_dictionary_create_empty()
    ///     xpc_dictionary_set_value(requirement, "$or", alternatives)
    ///
    ///     let connection = try XPCConnection(type: type, requirement: .lightweightCodeRequirement(requirement))
    ///
    /// - Parameter requirement: An XPC dictionary. It is copied, so changing it later does not change the requirement.
    @available(macOS 14.4, macCatalyst 17.4, *)
    public static func lightweightCodeRequirement(_ requirement: xpc_object_t) -> XPCPeerRequirement {
        Self(.lightweightCodeRequirement(xpc_copy(requirement) ?? requirement))
    }

    /// Requires `connection`'s peer to satisfy this requirement.
    ///
    /// - Throws: `XPCError.invalidCodeSignatureRequirement` or `XPCError.invalidPeerRequirement` if XPC rejects it.
    internal func apply(to connection: xpc_connection_t) throws {
        if case .codeSigning(let requirement) = self.kind {
            guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else {
                throw XPCError.invalidCodeSignatureRequirement
            }

            return
        }

        guard #available(macOS 14.4, macCatalyst 17.4, *) else {
            preconditionFailure("Only code signing requirements can be made before macOS 14.4")
        }

        let status: Int32

        switch self.kind {
        case .codeSigning:
            preconditionFailure("Handled above")
        case .entitlementExists(let entitlement):
            status = xpc_connection_set_peer_entitlement_exists_requirement(connection, entitlement)
        case .entitlementMatches(let entitlement, let value):
            status = xpc_connection_set_peer_entitlement_matches_value_requirement(connection, entitlement, value)
        case .teamIdentity(let signingIdentifier):
            status = Self.withOptionalCString(signingIdentifier) {
                xpc_connection_set_peer_team_identity_requirement(connection, $0)
            }
        case .platformIdentity(let signingIdentifier):
            status = Self.withOptionalCString(signingIdentifier) {
                xpc_connection_set_peer_platform_identity_requirement(connection, $0)
            }
        case .lightweightCodeRequirement(let requirement):
            // Anything but a dictionary is API misuse, which crashes the process.
            guard xpc_get_type(requirement) == XPC_TYPE_DICTIONARY else {
                throw XPCError.invalidPeerRequirement
            }

            status = xpc_connection_set_peer_lightweight_code_requirement(connection, requirement)
        }

        guard status == 0 else {
            throw XPCError.invalidPeerRequirement
        }
    }

    private static func withOptionalCString<Result>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        if let string {
            return string.withCString { body($0) }
        } else {
            return body(nil)
        }
    }
}
#endif
