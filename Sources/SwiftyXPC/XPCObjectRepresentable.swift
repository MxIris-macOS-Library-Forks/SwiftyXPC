#if os(macOS) || targetEnvironment(macCatalyst)
import XPC

/// A type whose values travel inside `Codable` messages as XPC objects of their own, rather than as encoded data.
///
/// Some values only make sense as native XPC objects: the kernel has to duplicate a file descriptor into the receiving
/// process, and an endpoint has to stay a live reference to its listener. A conforming type describes how to convert
/// its values to and from such an object, and gets its `Codable` conformance from this protocol: `XPCEncoder` and
/// `XPCDecoder` put the object itself into the message, wherever the value sits and however many wrappers that forward
/// `encode(to:)` and `init(from:)` stand between it and its container.
///
/// Only `XPCEncoder` and `XPCDecoder` can encode and decode a conforming type. Any other coder, such as `JSONEncoder`,
/// gets an error.
///
/// `XPCEndpoint`, `XPCFileDescriptor`, and `XPCNull` conform to this protocol.
public protocol XPCObjectRepresentable: Codable {
    /// The XPC type of the objects that represent values of this type.
    static var xpcType: XPCType { get }

    /// Creates a value from an XPC object.
    ///
    /// When `XPCDecoder` calls this initializer, it has already checked that the object's type is `xpcType`.
    ///
    /// - Parameter xpcObject: An XPC object of type `xpcType`.
    ///
    /// - Throws: Any error that prevents the value from being created.
    init(xpcObject: xpc_object_t) throws

    /// Returns an XPC object of type `xpcType` that represents this value.
    ///
    /// - Throws: Any error that prevents the object from being created.
    func makeXPCObject() throws -> xpc_object_t
}

extension XPCObjectRepresentable {
    /// Creates a value from the XPC object at the decoder's current position.
    ///
    /// - Parameter decoder: A decoder that `XPCDecoder` created.
    ///
    /// - Throws: `DecodingError.typeMismatch` if `decoder` does not come from `XPCDecoder`, or if the object at its
    ///   position is not of type `xpcType`; otherwise any error from `init(xpcObject:)`.
    public init(from decoder: any Decoder) throws {
        guard let xpcDecoder = decoder as? XPCDecoder._XPCDecoder else {
            let description = "\(Self.self) can only be decoded by SwiftyXPC's XPCDecoder."
            throw DecodingError.typeMismatch(
                Self.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: description)
            )
        }

        try self.init(xpcObject: xpcDecoder.object(ofType: Self.xpcType, decoding: Self.self))
    }

    /// Puts this value's XPC object at the encoder's current position.
    ///
    /// - Parameter encoder: An encoder that `XPCEncoder` created.
    ///
    /// - Throws: `EncodingError.invalidValue` if `encoder` does not come from `XPCEncoder`; otherwise any error from
    ///   `makeXPCObject()`.
    public func encode(to encoder: any Encoder) throws {
        guard let xpcEncoder = encoder as? XPCEncoder._XPCEncoder else {
            let description = "\(Self.self) can only be encoded by SwiftyXPC's XPCEncoder."
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: description)
            )
        }

        xpcEncoder.encode(xpcObject: try self.makeXPCObject())
    }
}
#endif
