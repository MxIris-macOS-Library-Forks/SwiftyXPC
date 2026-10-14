#if os(macOS) || targetEnvironment(macCatalyst)
import Darwin
import Foundation
import Testing
import XPC

@testable import SwiftyXPC

/// Round-trip tests for `XPCEncoder` and `XPCDecoder` that need no XPC connection.
///
/// These deliberately do not use the helper-launching suite trait, so they run anywhere.
// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
struct CoderRoundTripTests {
    struct StructureWithData: Codable, Equatable, Sendable {
        let data: Data
    }

    struct StructureWithArray: Codable, Equatable, Sendable {
        let numbers: [Int]
    }

    struct StructureWithNestedStructure: Codable, Equatable, Sendable {
        let inner: StructureWithData
    }

    enum EnumerationWithPayload: Codable, Equatable, Sendable {
        case text(String)
        case pair(first: String, second: String)
        case data(Data)
        case numbers([Int])
        case dataAndText(data: Data, text: String)
    }

    indirect enum NestedEnumeration: Codable, Equatable, Sendable {
        case wrap(inner: NestedEnumeration)
        case leaf(data: Data, numbers: [Int])
    }

    struct StructureWithEnumerationArray: Codable, Equatable, Sendable {
        let items: [NestedEnumeration]
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        let encoded = try XPCEncoder().encode(value)
        return try XPCDecoder().decode(type: Value.self, from: encoded)
    }

    @Test func `Collections at the top level of a structure round-trip`() throws {
        let structureWithData = StructureWithData(data: Data([1, 2, 3]))
        #expect(try self.roundTrip(structureWithData) == structureWithData)

        let structureWithArray = StructureWithArray(numbers: [1, 2, 3])
        #expect(try self.roundTrip(structureWithArray) == structureWithArray)

        let structureWithNestedStructure = StructureWithNestedStructure(inner: StructureWithData(data: Data([1, 2, 3])))
        #expect(try self.roundTrip(structureWithNestedStructure) == structureWithNestedStructure)
    }

    /// Regression test: collections carried as an enum's associated values used to be lost.
    ///
    /// A synthesized `Codable` conformance for an enum with associated values is the one shape that
    /// reaches for `nestedContainer(keyedBy:forKey:)`. The encoder's finalization pass only descended
    /// one level into nested containers, so an unkeyed container underneath one — which is how `Data`
    /// and arrays encode — never got its `Contents` key written. Encoding reported success, and the
    /// far end then failed to decode with `NSCocoaErrorDomain` 4864, "The data couldn't be read
    /// because it isn't in the correct format."
    @Test(
        arguments: [
            EnumerationWithPayload.text("hello"),
            .pair(first: "first", second: "second"),
            .data(Data([1, 2, 3])),
            .numbers([1, 2, 3]),
            .dataAndText(data: Data([1, 2, 3]), text: "text"),
            .data(Data()),
        ]
    )
    func `Collections carried by enumeration cases round-trip`(value: EnumerationWithPayload) throws {
        #expect(try self.roundTrip(value) == value)
    }

    /// The same failure at greater depth, which one extra level of descent would still have missed.
    @Test func `Collections nested several containers deep round-trip`() throws {
        let nestedEnumeration = NestedEnumeration.wrap(inner: .wrap(inner: .leaf(data: Data([9, 8, 7]), numbers: [4, 5])))
        #expect(try self.roundTrip(nestedEnumeration) == nestedEnumeration)

        let structureWithEnumerationArray = StructureWithEnumerationArray(
            items: [
                .leaf(data: Data([1]), numbers: [2]),
                .leaf(data: Data([3]), numbers: [4]),
            ]
        )
        #expect(try self.roundTrip(structureWithEnumerationArray) == structureWithEnumerationArray)
    }

    /// Encodes and decodes the value it wraps by forwarding to it, the way property wrappers usually do.
    struct Forwarding<Wrapped: Codable>: Codable {
        let wrapped: Wrapped

        init(_ wrapped: Wrapped) {
            self.wrapped = wrapped
        }

        init(from decoder: any Decoder) throws {
            self.wrapped = try Wrapped(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try self.wrapped.encode(to: encoder)
        }
    }

    struct MessageWithForwardedDescriptor: Codable {
        let descriptor: Forwarding<XPCFileDescriptor>
    }

    struct MessageWithForwardedEndpoint: Codable {
        let endpoint: Forwarding<SwiftyXPC.XPCEndpoint>
    }

    /// Two optional integers in an unkeyed container, the way a hand-written conformance might store them.
    struct OptionalPair: Codable, Equatable, Sendable {
        let first: Int?
        let second: Int?

        init(first: Int?, second: Int?) {
            self.first = first
            self.second = second
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            self.first = try container.decodeIfPresent(Int.self)
            self.second = try container.decodeIfPresent(Int.self)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()

            for value in [self.first, self.second] {
                if let value {
                    try container.encode(value)
                } else {
                    try container.encodeNil()
                }
            }
        }
    }

    /// Regression test: a file descriptor behind a forwarding wrapper used to travel as a plain number.
    ///
    /// The coders recognized `XPCFileDescriptor` only when a container was handed one directly. Behind a wrapper
    /// that forwards `encode(to:)`, its synthesized conformance encoded the descriptor's number, and decoding
    /// produced a second object claiming to own the sender's descriptor number, which it would later close.
    @Test func `A file descriptor behind a forwarding wrapper travels as a file descriptor`() throws {
        let fileDescriptor = open("/dev/null", O_RDONLY)
        try #require(fileDescriptor >= 0)

        let message = MessageWithForwardedDescriptor(descriptor: Forwarding(XPCFileDescriptor(fileDescriptor: fileDescriptor)))

        withKnownIssue("XPCFileDescriptor is only recognized when a container encodes it directly") {
            let encoded = try XPCEncoder().encode(message)
            let descriptorObject = try #require(xpc_dictionary_get_value(encoded, "descriptor"))
            try #require(xpc_get_type(descriptorObject) == XPC_TYPE_FD)

            let decoded = try XPCDecoder().decode(type: MessageWithForwardedDescriptor.self, from: encoded)
            let decodedDescriptor = decoded.descriptor.wrapped.fileDescriptor

            var originalStatus = stat()
            var decodedStatus = stat()
            try #require(fstat(fileDescriptor, &originalStatus) == 0)
            try #require(fstat(decodedDescriptor, &decodedStatus) == 0)

            #expect(decodedDescriptor != fileDescriptor)
            #expect(decodedStatus.st_dev == originalStatus.st_dev && decodedStatus.st_ino == originalStatus.st_ino)
        }
    }

    /// Regression test: an endpoint behind a forwarding wrapper used to refuse to encode at all.
    ///
    /// `XPCEndpoint.encode(to:)` threw unconditionally, relying on the coders to intercept the type before
    /// calling it, which they cannot do once a wrapper sits in between.
    @Test func `An endpoint behind a forwarding wrapper still leads to its listener`() async throws {
        let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        listener.setMessageHandler(name: "ping") { _ in
            "pong"
        }
        listener.activate()
        defer { listener.cancel() }

        await withKnownIssue("XPCEndpoint.encode(to:) always throws") {
            let encoded = try XPCEncoder().encode(MessageWithForwardedEndpoint(endpoint: Forwarding(listener.endpoint)))
            let decoded = try XPCDecoder().decode(type: MessageWithForwardedEndpoint.self, from: encoded)

            let connection = try XPCConnection(
                type: .remoteServiceFromEndpoint(decoded.endpoint.wrapped),
                codeSigningRequirement: nil
            )
            connection.activate()
            defer { connection.cancel() }

            let pong: String = try await connection.sendMessage(name: "ping")
            #expect(pong == "pong")
        }
    }

    /// Regression test: `decodeNil()` on an unkeyed container used to throw for a value that was not null.
    ///
    /// The protocol requires it to return `false` and leave the value in place, which is what the standard
    /// `decodeIfPresent(_:)` relies on to read an optional value out of an unkeyed container.
    @Test func `Optional values in an unkeyed container round-trip`() throws {
        let pair = OptionalPair(first: 1, second: nil)

        withKnownIssue("decodeNil() throws instead of returning false for a value that is not null") {
            let roundTripped = try self.roundTrip(pair)
            #expect(roundTripped == pair)
        }
    }
}
#endif
