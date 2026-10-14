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
#endif
