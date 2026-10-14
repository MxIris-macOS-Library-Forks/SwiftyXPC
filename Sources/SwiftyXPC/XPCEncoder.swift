#if os(macOS) || targetEnvironment(macCatalyst)
//
//  XPCEncoder.swift
//
//  Created by Charles Srstka on 11/2/21.
//

import System
import XPC

private protocol XPCEncodingContainer {
    var childContainers: [XPCEncodingContainer] { get }
    var childEncoders: [XPCEncoder._XPCEncoder] { get }
    func finalize()
}

extension XPCEncodingContainer {
    /// Returns the XPC object that stands for `value` itself, for a value that travels as an XPC object of its own.
    ///
    /// - Returns: `nil` for a value that is encoded the ordinary way, through `encode(to:)`.
    fileprivate func standaloneObject(for value: some Encodable, codingPath: [CodingKey]) throws -> xpc_object_t? {
        switch value {
        case let representable as any XPCObjectRepresentable:
            return try representable.makeXPCObject()
        case let fileDescriptor as FileDescriptor:
            guard let object = xpc_fd_create(fileDescriptor.rawValue) else {
                let reason = Errno(rawValue: errno)
                let description = "Could not put file descriptor \(fileDescriptor.rawValue) in a message: \(reason)"
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(codingPath: codingPath, debugDescription: description)
                )
            }

            return object
        default:
            return nil
        }
    }

    fileprivate func encodeNil() -> xpc_object_t { xpc_null_create() }
    fileprivate func encodeBool(_ flag: Bool) -> xpc_object_t { xpc_bool_create(flag) }
    fileprivate func encodeInteger<I: SignedInteger>(_ i: I) -> xpc_object_t { xpc_int64_create(Int64(i)) }
    fileprivate func encodeInteger<I: UnsignedInteger>(_ i: I) -> xpc_object_t { xpc_uint64_create(UInt64(i)) }
    fileprivate func encodeFloat<F: BinaryFloatingPoint>(_ f: F) -> xpc_object_t { xpc_double_create(Double(f)) }
    fileprivate func encodeString(_ string: String) -> xpc_object_t { xpc_string_create(string) }

    fileprivate func finalize() {}

    /// Finalizes this container and everything encoded beneath it.
    ///
    /// Containers form a tree: `nestedContainer(keyedBy:forKey:)` and `nestedUnkeyedContainer(forKey:)`
    /// add to `childContainers`, while encoding an arbitrary `Encodable` adds to `childEncoders`.
    /// Only `UnkeyedContainer` does real work in `finalize()` — writing its accumulated elements under
    /// the `Contents` key — but it can sit at any depth, so the entire tree has to be visited.
    /// Descending only one level leaves deeper unkeyed containers without their `Contents` key, and
    /// `XPCDecoder` then rejects the message with "Missing contents for unkeyed container".
    fileprivate func finalizeRecursively() {
        self.finalize()
        self.childContainers.forEach { $0.finalizeRecursively() }
        self.childEncoders.forEach { $0.finalize() }
    }
}

/// An implementation of `Encoder` that can encode values to be sent over an XPC connection.
public class XPCEncoder {
    internal enum Key: CodingKey {
        case arrayIndex(Int)
        case `super`

        var stringValue: String {
            switch self {
            case .arrayIndex(let int):
                return "Index: \(int)"
            case .super:
                return "super"
            }
        }

        var intValue: Int? {
            switch self {
            case .arrayIndex(let int):
                return int
            case .super:
                return nil
            }
        }

        init?(stringValue: String) { return nil }
        init(intValue: Int) { self = .arrayIndex(intValue) }
    }

    internal struct UnkeyedContainerDictionaryKeys {
        static let contents = "Contents"
        static let `super` = "Super"
    }

    private class KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol, XPCEncodingContainer {
        let dict: xpc_object_t
        var codingPath: [CodingKey] = []
        var childContainers: [XPCEncodingContainer] = []
        var childEncoders: [_XPCEncoder] = []

        init(wrapping dict: xpc_object_t, codingPath: [CodingKey]) {
            precondition(xpc_get_type(dict) == XPC_TYPE_DICTIONARY, "Keyed container is not wrapping a dictionary")

            self.dict = dict
            self.codingPath = codingPath
        }

        private func encode(xpcValue: xpc_object_t, for key: Key) {
            key.stringValue.withCString {
                precondition(xpc_dictionary_get_value(self.dict, $0) == nil, "Value already keyed for \(key)")

                xpc_dictionary_set_value(self.dict, $0, xpcValue)
            }
        }

        func encodeNil(forKey key: Key) throws { self.encode(xpcValue: self.encodeNil(), for: key) }
        func encode(_ value: Bool, forKey key: Key) throws { self.encode(xpcValue: self.encodeBool(value), for: key) }
        func encode(_ value: String, forKey key: Key) throws { self.encode(xpcValue: self.encodeString(value), for: key) }
        func encode(_ value: Double, forKey key: Key) throws { self.encode(xpcValue: self.encodeFloat(value), for: key) }
        func encode(_ value: Float, forKey key: Key) throws { self.encode(xpcValue: self.encodeFloat(value), for: key) }
        func encode(_ value: Int, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }
        func encode(_ value: Int8, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }
        func encode(_ value: Int16, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }
        func encode(_ value: Int32, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }
        func encode(_ value: Int64, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }
        func encode(_ value: UInt, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }
        func encode(_ value: UInt8, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }
        func encode(_ value: UInt16, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }
        func encode(_ value: UInt32, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }
        func encode(_ value: UInt64, forKey key: Key) throws { self.encode(xpcValue: self.encodeInteger(value), for: key) }

        func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            if let object = try self.standaloneObject(for: value, codingPath: self.codingPath + [key]) {
                self.encode(xpcValue: object, for: key)
            } else {
                let encoder = _XPCEncoder(parentXPC: self.dict, codingPath: self.codingPath + [key])

                self.childEncoders.append(encoder)

                try value.encode(to: encoder)
            }
        }

        func nestedContainer<NestedKey: CodingKey>(
            keyedBy keyType: NestedKey.Type,
            forKey key: Key
        ) -> KeyedEncodingContainer<NestedKey> {
            let dict = xpc_dictionary_create(nil, nil, 0)
            self.encode(xpcValue: dict, for: key)

            let container = KeyedContainer<NestedKey>(wrapping: dict, codingPath: self.codingPath + [key])

            self.childContainers.append(container)

            return KeyedEncodingContainer(container)
        }

        func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            self.encode(xpcValue: dictionary, for: key)

            let container = UnkeyedContainer(wrapping: dictionary, codingPath: self.codingPath + [key])

            self.childContainers.append(container)

            return container
        }

        func superEncoder() -> Encoder {
            let encoder = _XPCEncoder(parentXPC: self.dict, codingPath: self.codingPath + [XPCEncoder.Key.super])

            self.childEncoders.append(encoder)

            return encoder
        }

        func superEncoder(forKey key: Key) -> Encoder {
            let encoder = _XPCEncoder(parentXPC: self.dict, codingPath: self.codingPath + [key])

            self.childEncoders.append(encoder)

            return encoder
        }
    }

    private class UnkeyedContainer: UnkeyedEncodingContainer, XPCEncodingContainer {
        private enum Storage {
            class ByteStorage {
                var bytes: ContiguousArray<UInt8>
                let isSigned: Bool

                init(bytes: ContiguousArray<UInt8>) {
                    self.bytes = bytes
                    self.isSigned = false
                }

                init(bytes: ContiguousArray<Int8>) {
                    self.bytes = ContiguousArray<UInt8>.init(unsafeUninitializedCapacity: bytes.count) { buffer, count in
                        _ = buffer.withMemoryRebound(to: Int8.self) { $0.initialize(fromContentsOf: bytes) }
                        count = bytes.count
                    }

                    self.isSigned = true
                }
            }

            case empty
            case array(xpc_object_t)
            case bytes(ByteStorage)
            case finalized(Int)
        }

        var childContainers: [XPCEncodingContainer] = []
        var childEncoders: [XPCEncoder._XPCEncoder] = []

        private let dict: xpc_object_t
        private var storage: Storage

        let codingPath: [CodingKey]
        var count: Int {
            switch self.storage {
            case .empty:
                return 0
            case .array(let array):
                return xpc_array_get_count(array)
            case .bytes(let byteStorage):
                return byteStorage.bytes.count
            case .finalized(let count):
                return count
            }
        }

        init(wrapping dict: xpc_object_t, codingPath: [CodingKey]) {
            precondition(xpc_get_type(dict) == XPC_TYPE_DICTIONARY, "Unkeyed container is not wrapping dictionary")

            self.dict = dict
            self.storage = .empty
            self.codingPath = codingPath
        }

        private func encode(xpcValue: xpc_object_t) {
            switch self.storage {
            case .empty:
                var value = xpcValue
                self.storage = .array(xpc_array_create(&value, 1))
            case .array(let array):
                xpc_array_append_value(array, xpcValue)
            case .bytes(let byteStorage):
                var byteArray: [xpc_object_t]
                if byteStorage.isSigned {
                    byteArray = byteStorage.bytes.map { self.encodeInteger(Int8(bitPattern: $0)) }
                } else {
                    byteArray = byteStorage.bytes.map { self.encodeInteger($0) }
                }

                byteArray.append(xpcValue)

                self.storage = .array(byteArray.withUnsafeBufferPointer { xpc_array_create($0.baseAddress, $0.count) })
            case .finalized:
                preconditionFailure("UnkeyedContainer encoded to after being finalized")
            }
        }

        private func encodeByte(_ byte: Int8) {
            switch self.storage {
            case .empty:
                self.storage = .bytes(.init(bytes: [byte]))
            case .bytes(let byteStorage) where byteStorage.isSigned:
                byteStorage.bytes.append(UInt8(bitPattern: byte))
            default:
                self.encode(xpcValue: self.encodeInteger(byte))
            }
        }

        private func encodeByte(_ byte: UInt8) {
            switch self.storage {
            case .empty:
                self.storage = .bytes(.init(bytes: [byte]))
            case .bytes(let byteStorage) where !byteStorage.isSigned:
                byteStorage.bytes.append(byte)
            default:
                self.encode(xpcValue: self.encodeInteger(byte))
            }
        }

        func encodeNil() { self.encode(xpcValue: self.encodeNil()) }
        func encode(_ value: Bool) throws { self.encode(xpcValue: self.encodeBool(value)) }
        func encode(_ value: String) throws { self.encode(xpcValue: self.encodeString(value)) }
        func encode(_ value: Double) throws { self.encode(xpcValue: self.encodeFloat(value)) }
        func encode(_ value: Float) throws { self.encode(xpcValue: self.encodeFloat(value)) }
        func encode(_ value: Int) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: Int8) throws { self.encodeByte(value) }
        func encode(_ value: Int16) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: Int32) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: Int64) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: UInt) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: UInt8) throws { self.encodeByte(value) }
        func encode(_ value: UInt16) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: UInt32) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: UInt64) throws { self.encode(xpcValue: self.encodeInteger(value)) }

        func encode(contentsOf sequence: some Sequence<UInt8>) throws {
            switch self.storage {
            case .empty:
                self.storage = .bytes(.init(bytes: ContiguousArray(sequence)))
            case .bytes(let byteStorage) where !byteStorage.isSigned:
                byteStorage.bytes.append(contentsOf: sequence)
            default:
                for eachByte in sequence {
                    self.encode(xpcValue: self.encodeInteger(eachByte))
                }
            }
        }

        func encode<T: Encodable>(_ value: T) throws {
            let codingPath = self.nextCodingPath()

            if let object = try self.standaloneObject(for: value, codingPath: codingPath) {
                self.encode(xpcValue: object)
            } else if let byte = value as? Int8 {
                self.encodeByte(byte)
            } else if let byte = value as? UInt8 {
                self.encodeByte(byte)
            } else {
                self.encodeNil()  // leave placeholder which will be overwritten later

                guard case .array(let array) = self.storage else {
                    preconditionFailure("encodeNil() should have converted storage to array")
                }

                let encoder = _XPCEncoder(parentXPC: array, codingPath: codingPath)

                self.childEncoders.append(encoder)

                try value.encode(to: encoder)
            }
        }

        func nestedContainer<NestedKey: CodingKey>(
            keyedBy keyType: NestedKey.Type
        ) -> KeyedEncodingContainer<NestedKey> {
            let dict = xpc_dictionary_create(nil, nil, 0)
            self.encode(xpcValue: dict)

            let container = KeyedContainer<NestedKey>(wrapping: dict, codingPath: self.nextCodingPath())

            self.childContainers.append(container)

            return KeyedEncodingContainer(container)
        }

        func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            let dict = xpc_dictionary_create(nil, nil, 0)
            self.encode(xpcValue: dict)

            let container = UnkeyedContainer(wrapping: dict, codingPath: self.nextCodingPath())

            self.childContainers.append(container)

            return container
        }

        func superEncoder() -> Encoder {
            let encoder = _XPCEncoder(parentXPC: self.dict, codingPath: self.codingPath + [XPCEncoder.Key.super])

            self.childEncoders.append(encoder)

            return encoder
        }

        func finalize() {
            let value: xpc_object_t?
            switch self.storage {
            case .empty:
                value = xpc_array_create(nil, 0)
            case .array(let array):
                value = array
            case .bytes(let byteStorage):
                value = byteStorage.bytes.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
            case .finalized:
                preconditionFailure("UnkeyedContainer finalized twice")
            }

            xpc_dictionary_set_value(self.dict, UnkeyedContainerDictionaryKeys.contents, value)
        }

        private func nextCodingPath() -> [CodingKey] {
            self.codingPath + [XPCEncoder.Key.arrayIndex(self.count)]
        }
    }

    private class SingleValueContainer: SingleValueEncodingContainer, XPCEncodingContainer {
        // We can use `unowned` here, because `SingleValueContainer` should only be created under these circumstances:
        // 1. Created by `XPCEncoder.encode(_:)`, which keeps the encoder alive until after encoding is done, and:
        // 2. Created by an `Encodable` in its implementation of `encode(to:)`, during which the encoder will remain
        //    alive for the duration of the method, after which the `SingleValueContainer` will no longer be used.
        unowned let encoder: _XPCEncoder
        var hasBeenEncoded = false

        var codingPath: [CodingKey] { self.encoder.codingPath }
        var childContainers: [XPCEncodingContainer] { [] }
        var childEncoders: [XPCEncoder._XPCEncoder] = []

        init(encoder: _XPCEncoder) {
            self.encoder = encoder
        }

        private func encode(xpcValue: xpc_object_t) {
            precondition(!self.hasBeenEncoded, "Cannot encode to SingleValueContainer twice")
            defer { self.hasBeenEncoded = true }

            self.encoder.setEncodedValue(value: xpcValue)
        }

        func encodeNil() throws { self.encode(xpcValue: self.encodeNil()) }
        func encode(_ value: Bool) throws { self.encode(xpcValue: self.encodeBool(value)) }
        func encode(_ value: String) throws { self.encode(xpcValue: self.encodeString(value)) }
        func encode(_ value: Double) throws { self.encode(xpcValue: self.encodeFloat(value)) }
        func encode(_ value: Float) throws { self.encode(xpcValue: self.encodeFloat(value)) }
        func encode(_ value: Int) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: Int8) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: Int16) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: Int32) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: Int64) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: UInt) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: UInt8) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: UInt16) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: UInt32) throws { self.encode(xpcValue: self.encodeInteger(value)) }
        func encode(_ value: UInt64) throws { self.encode(xpcValue: self.encodeInteger(value)) }

        func encode<T: Encodable>(_ value: T) throws {
            if let object = try self.standaloneObject(for: value, codingPath: self.codingPath) {
                self.encode(xpcValue: object)
            } else {
                let encoder = _XPCEncoder(parentXPC: nil, codingPath: self.codingPath)
                try value.encode(to: encoder)

                self.childEncoders.append(encoder)

                guard let encoded = encoder.encodedValue else {
                    preconditionFailure("XPCEncoder did not set encoded value")
                }

                self.encode(xpcValue: encoded)
            }
        }
    }

    internal final class _XPCEncoder: Encoder {
        let codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        private(set) var encodedValue: xpc_object_t? = nil

        private let parentXPC: xpc_object_t?
        private var topLevelContainer: XPCEncodingContainer? = nil

        init(parentXPC: xpc_object_t?, codingPath: [CodingKey]) {
            self.parentXPC = parentXPC
            self.codingPath = codingPath
        }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            precondition(self.topLevelContainer == nil, "Can only have one top-level container")

            let dict = xpc_dictionary_create(nil, nil, 0)
            self.setEncodedValue(value: dict)

            let container = KeyedContainer<Key>(wrapping: dict, codingPath: self.codingPath)

            self.topLevelContainer = container

            return KeyedEncodingContainer(container)
        }

        func unkeyedContainer() -> UnkeyedEncodingContainer {
            precondition(self.topLevelContainer == nil, "Can only have one top-level container")

            let dict = xpc_dictionary_create(nil, nil, 0)
            self.setEncodedValue(value: dict)

            let container = UnkeyedContainer(wrapping: dict, codingPath: self.codingPath)

            self.topLevelContainer = container

            return container
        }

        func singleValueContainer() -> SingleValueEncodingContainer {
            precondition(self.topLevelContainer == nil, "Can only have one top-level container")

            let container = SingleValueContainer(encoder: self)

            self.topLevelContainer = container

            return container
        }

        /// Puts `object` at this encoder's position, for a value that travels as an XPC object of its own.
        func encode(xpcObject object: xpc_object_t) {
            precondition(self.topLevelContainer == nil && self.encodedValue == nil, "Can only encode one value")

            self.setEncodedValue(value: object)
        }

        func setEncodedValue(value: xpc_object_t) {
            self.encodedValue = value

            if let parentXPC = self.parentXPC {
                guard let key = self.codingPath.last else {
                    preconditionFailure("No coding key with parent XPC object")
                }

                if case .arrayIndex(let index)? = key as? XPCEncoder.Key {
                    precondition(xpc_get_type(parentXPC) == XPC_TYPE_ARRAY, "Index passed to non-array")

                    xpc_array_set_value(parentXPC, index, value)
                } else {
                    // Every other key, including the `super` key of `superEncoder()`, names a dictionary entry.
                    precondition(xpc_get_type(parentXPC) == XPC_TYPE_DICTIONARY, "Key passed to non-dictionary")

                    key.stringValue.withCString { xpc_dictionary_set_value(parentXPC, $0, value) }
                }
            }
        }

        func finalize() {
            self.topLevelContainer?.finalizeRecursively()
        }
    }

    private let original: xpc_object_t?

    /// Create an `XPCEncoder`.
    ///
    /// - Parameter original: An optional incoming XPC event object to which the encoded value should be a reply. This event must be a dictionary.
    public init(replyingTo original: xpc_object_t? = nil) {
        if let original = original {
            precondition(xpc_get_type(original) == XPC_TYPE_DICTIONARY, "XPC replies must be to dictionaries")
        }

        self.original = original
    }

    /// Encode a value to an XPC object.
    ///
    /// If this encoder was created with a message to reply to, the value must encode as a keyed container, and its
    /// entries are copied into a reply dictionary for that message.
    ///
    /// - Parameter value: The value to be encoded.
    ///
    /// - Returns: The encoded value, as an `xpc_object_t`.
    ///
    /// - Throws: Any errors that come up in the process of encoding the value, or `EncodingError.invalidValue` if a
    ///   reply was requested but the value does not encode as a keyed container or the message does not expect a reply.
    public func encode<T: Encodable>(_ value: T) throws -> xpc_object_t {
        let encoder = _XPCEncoder(parentXPC: nil, codingPath: [])

        // Everything has to go through containers so that custom catchers in the container classes will catch things like
        // file descriptors.

        var container = encoder.singleValueContainer()
        try container.encode(value)

        encoder.finalize()

        guard let encoded = encoder.encodedValue else {
            preconditionFailure("XPCEncoder did not set encoded value")
        }

        guard let original = self.original else {
            return encoded
        }

        guard xpc_get_type(encoded) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(original) else {
            let description = "A reply must encode as a keyed container, to a message that expects a reply."
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: description))
        }

        xpc_dictionary_apply(encoded) { key, entry in
            xpc_dictionary_set_value(reply, key, entry)
            return true
        }

        return reply
    }
}
#endif
