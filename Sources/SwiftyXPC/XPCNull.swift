#if os(macOS) || targetEnvironment(macCatalyst)
//
//  XPCNull.swift
//
//
//  Created by Charles Srstka on 12/27/21.
//

import XPC

/// A class representing a null value in XPC.
public struct XPCNull: XPCObjectRepresentable, Sendable {
    /// The shared `XPCNull` instance.
    public static let shared = Self()

    /// The XPC type of the object that represents a null value: `.null`.
    public static var xpcType: XPCType { .null }

    /// Creates a null value.
    public init() {}

    /// Creates a null value from an XPC null object.
    ///
    /// - Parameter xpcObject: An XPC object of type `XPC_TYPE_NULL`.
    ///
    /// - Throws: `XPCConnection.Error.typeMismatch` if `xpcObject` is not a null object.
    public init(xpcObject: xpc_object_t) throws {
        guard xpc_get_type(xpcObject) == XPC_TYPE_NULL else {
            throw XPCConnection.Error.typeMismatch(expected: .null, actual: xpcObject.type)
        }
    }

    /// Returns an XPC null object.
    public func makeXPCObject() -> xpc_object_t {
        xpc_null_create()
    }
}
#endif
