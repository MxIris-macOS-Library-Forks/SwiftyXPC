#if os(macOS) || targetEnvironment(macCatalyst)
//
//  XPCEndpoint.swift
//  SwiftyXPC
//
//  Created by Charles Srstka on 7/24/21.
//

import XPC

/// A reference to an `XPCListener` object.
///
/// An `XPCEndpoint` can be passed over an active XPC connection, allowing the process on the other end to initialize a new `XPCConnection`
/// to communicate with it.
///
/// An endpoint travels in a message as an XPC endpoint object, so only `XPCEncoder` and `XPCDecoder` can encode and decode it.
public struct XPCEndpoint: XPCObjectRepresentable, @unchecked Sendable {
    /// The XPC type of the object that represents an endpoint: `.endpoint`.
    public static var xpcType: XPCType { .endpoint }

    internal let endpoint: xpc_endpoint_t

    internal init(connection: xpc_connection_t) {
        self.endpoint = xpc_endpoint_create(connection)
    }

    /// Creates an endpoint from an XPC endpoint object.
    ///
    /// - Parameter xpcObject: An XPC object of type `XPC_TYPE_ENDPOINT`.
    ///
    /// - Throws: `XPCConnection.Error.typeMismatch` if `xpcObject` is not an endpoint.
    public init(xpcObject: xpc_object_t) throws {
        guard xpc_get_type(xpcObject) == XPC_TYPE_ENDPOINT else {
            throw XPCConnection.Error.typeMismatch(expected: .endpoint, actual: xpcObject.type)
        }

        self.endpoint = xpcObject
    }

    /// Returns the XPC endpoint object.
    public func makeXPCObject() -> xpc_object_t {
        self.endpoint
    }

    internal func makeConnection() -> xpc_connection_t {
        xpc_connection_create_from_endpoint(self.endpoint)
    }
}
#endif
