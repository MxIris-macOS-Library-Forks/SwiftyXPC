#if os(macOS) || targetEnvironment(macCatalyst)
import Darwin
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
#endif
