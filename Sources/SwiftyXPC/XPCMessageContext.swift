#if os(macOS) || targetEnvironment(macCatalyst)
import Darwin
import Security
import XPC

/// Information about the message that a handler is processing.
///
/// Every message handler receives one as its first argument. Its identity properties describe the process that sent
/// this particular message: they are read from the audit token that the kernel attached to the message when it
/// arrived, so they stay correct while the handler runs, even after later messages have arrived on the connection.
/// Prefer them to the connection's own `auditToken` and `processIdentifier`, which follow the most recent message.
public struct XPCMessageContext: @unchecked Sendable {
    // Unchecked because of `message`, an XPC dictionary that is only read after it arrives, which is safe from any
    // thread.

    /// The connection on which the message arrived.
    ///
    /// Use it to send messages back to the sender, or to send messages that do not answer this one.
    public let connection: XPCConnection

    /// The name the sender gave the message, which selected the handler.
    public let messageName: String

    /// The audit token of the process that sent this message.
    ///
    /// The audit token identifies a process in a way that a reused process identifier cannot, which makes it the
    /// identity to check against a code signing requirement, for instance through `SecCodeCopyGuestWithAttributes`
    /// with `kSecGuestAttributeAudit`.
    public let auditToken: audit_token_t

    /// Whether the sender is waiting for a reply.
    ///
    /// `false` for a message sent with `sendOnewayMessage(name:message:)`. Whatever the handler of such a message
    /// returns is discarded, and an error it throws goes to the receiving connection's `errorHandler`.
    public let expectsReply: Bool

    /// The message as it arrived.
    internal let message: xpc_object_t

    internal init(connection: XPCConnection, message: xpc_object_t, messageName: String, expectsReply: Bool) {
        var auditToken = audit_token_t()
        swiftyxpc_xpc_dictionary_get_audit_token(message, &auditToken)

        self.connection = connection
        self.message = message
        self.messageName = messageName
        self.auditToken = auditToken
        self.expectsReply = expectsReply
    }

    /// The process identifier of the sender, read from `auditToken`.
    public var processIdentifier: pid_t {
        pid_t(bitPattern: self.auditToken.val.5)
    }

    /// The effective user identifier of the sender, read from `auditToken`.
    public var effectiveUserIdentifier: uid_t {
        self.auditToken.val.1
    }

    /// The effective group identifier of the sender, read from `auditToken`.
    public var effectiveGroupIdentifier: gid_t {
        self.auditToken.val.2
    }

    /// The audit session identifier of the sender, read from `auditToken`.
    public var auditSessionIdentifier: au_asid_t {
        au_asid_t(bitPattern: self.auditToken.val.6)
    }
}

extension XPCMessageContext {
    /// Returns whether the process that sent this message satisfies `requirement`.
    ///
    /// The check is made against this message, so it cannot be fooled by a process identifier that a new process has
    /// taken over. It complements the requirement a connection enforces: use it to accept only some messages from a
    /// connection that admits a wider group of peers.
    ///
    /// - Parameter requirement: The requirement to check.
    ///
    /// - Returns: `true` if the sender satisfies `requirement`, and `false` if it does not or cannot be checked.
    ///
    /// - Throws: `XPCError.invalidCodeSignatureRequirement` or `XPCError.invalidPeerRequirement` if `requirement` is
    ///   not valid, or a `BoxedError` in the Security domain if the sender's code cannot be examined.
    @available(macOS 26.0, macCatalyst 26.0, *)
    public func senderSatisfies(_ requirement: XPCPeerRequirement) throws -> Bool {
        if case .codeSigning(let requirementString) = requirement.kind {
            return try self.senderSatisfies(codeSigningRequirement: requirementString)
        }

        guard let peerRequirement = PeerRequirementFunctions.makeRequirement(for: requirement.kind) else {
            throw XPCError.invalidPeerRequirement
        }

        return PeerRequirementFunctions.message(self.message, satisfies: peerRequirement)
    }

    /// Checks the sender against a code signing requirement with Security, which has no `xpc_peer_requirement_t` form.
    private func senderSatisfies(codeSigningRequirement requirementString: String) throws -> Bool {
        var requirement: SecRequirement?
        let requirementCreated = requirementString.withCString { cString in
            CFStringCreateWithCString(kCFAllocatorDefault, cString, CFStringBuiltInEncodings.UTF8.rawValue).map {
                SecRequirementCreateWithString($0, [], &requirement) == errSecSuccess
            } ?? false
        }

        guard requirementCreated, let requirement else {
            throw XPCError.invalidCodeSignatureRequirement
        }

        // Identifies the sender by the audit token that the kernel attached to this message.
        var code: SecCode?
        let codeStatus = SecCodeCreateWithXPCMessage(self.message, [], &code)
        guard codeStatus == errSecSuccess, let code else {
            throw XPCErrorRegistry.BoxedError(domain: "NSOSStatusErrorDomain", code: Int(codeStatus))
        }

        let validityStatus = SecCodeCheckValidity(code, [], requirement)

        switch validityStatus {
        case errSecSuccess:
            return true
        case errSecCSReqFailed:
            return false
        default:
            throw XPCErrorRegistry.BoxedError(domain: "NSOSStatusErrorDomain", code: Int(validityStatus))
        }
    }
}
#endif
