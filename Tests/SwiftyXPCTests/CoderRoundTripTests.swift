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

    /// Three bytes read one at a time out of an unkeyed container, the way a hand-written conformance might.
    struct Color: Codable, Equatable, Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            self.red = try container.decode(UInt8.self)
            self.green = try container.decode(UInt8.self)
            self.blue = try container.decode(UInt8.self)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(self.red)
            try container.encode(self.green)
            try container.encode(self.blue)
        }
    }

    /// A shape as an older peer knows it.
    enum Shape: Codable, Equatable, Sendable {
        case circle(radius: Double)
        case square(side: Double)
    }

    /// The same shape as a newer peer knows it, with a case the older one has never heard of.
    enum NewerShape: Codable, Equatable, Sendable {
        case circle(radius: Double)
        case square(side: Double)
        case triangle(base: Double, height: Double)
    }

    /// A base class that encodes its own state and leaves the rest to subclasses.
    class Vehicle: Codable, @unchecked Sendable {
        let wheels: Int

        init(wheels: Int) {
            self.wheels = wheels
        }
    }

    /// A subclass that keeps its superclass's state under `superEncoder()`, as `Codable` class hierarchies do.
    final class Bicycle: Vehicle, @unchecked Sendable {
        let gears: Int

        private enum CodingKeys: String, CodingKey {
            case gears
        }

        init(wheels: Int, gears: Int) {
            self.gears = gears
            super.init(wheels: wheels)
        }

        required init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.gears = try container.decode(Int.self, forKey: .gears)
            try super.init(from: container.superDecoder())
        }

        override func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.gears, forKey: .gears)
            try super.encode(to: container.superEncoder())
        }
    }

    /// Keeps a nested value under a key of its own choosing through `superEncoder(forKey:)`.
    struct Labelled: Codable, Equatable, Sendable {
        let label: String
        let value: Int

        private enum CodingKeys: String, CodingKey {
            case label
            case value
        }

        init(label: String, value: Int) {
            self.label = label
            self.value = value
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.label = try container.decode(String.self, forKey: .label)
            self.value = try Int(from: container.superDecoder(forKey: .value))
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.label, forKey: .label)
            try self.value.encode(to: container.superEncoder(forKey: .value))
        }
    }

    /// An identifier that accepts either a bare string or a keyed form, trying the string first.
    struct FlexibleIdentifier: Decodable, Equatable, Sendable {
        let value: String

        private enum CodingKeys: String, CodingKey {
            case value
        }

        init(value: String) {
            self.value = value
        }

        init(from decoder: any Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                self.value = value
            } else {
                self.value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value)
            }
        }
    }

    struct KeyedIdentifier: Encodable {
        let value: String
    }

    /// Failures as an older peer knows them.
    enum OlderFailure: Error, Codable {
        case timedOut
    }

    /// The same failures as a newer peer knows them, with a case the older one has never heard of.
    enum NewerFailure: Error, Codable {
        case timedOut
        case quotaExceeded(limit: Int)
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

    /// Values that travel as XPC objects of their own cannot be encoded by other coders.
    ///
    /// `XPCFileDescriptor` used to have a synthesized conformance that any coder accepted, writing out a descriptor
    /// number that means nothing outside this process.
    @Test func `A file descriptor refuses to be encoded by another encoder`() throws {
        let fileDescriptor = open("/dev/null", O_RDONLY)
        try #require(fileDescriptor >= 0)

        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode([XPCFileDescriptor(fileDescriptor: fileDescriptor)])
        }
    }

    /// Regression test: `decodeNil()` on an unkeyed container used to throw for a value that was not null.
    ///
    /// The protocol requires it to return `false` and leave the value in place, which is what the standard
    /// `decodeIfPresent(_:)` relies on to read an optional value out of an unkeyed container.
    @Test func `Optional values in an unkeyed container round-trip`() throws {
        let pair = OptionalPair(first: 1, second: nil)

        #expect(try self.roundTrip(pair) == pair)
    }
    /// Regression test: reading one byte too many out of packed byte data used to crash the process.
    ///
    /// Consecutive `UInt8` values travel as a single `xpc_data` blob. The byte reader's bounds check let an index
    /// equal to the count through, so a peer that sent fewer bytes than the receiver expected made the receiver
    /// trap on an out-of-range subscript instead of failing to decode.
    @Test func `Reading past the end of packed bytes throws instead of crashing`() throws {
        let twoBytes = try XPCEncoder().encode([UInt8(1), 2])

        #expect(throws: DecodingError.self) {
            _ = try XPCDecoder().decode(type: Color.self, from: twoBytes)
        }
    }

    /// Regression test: a key the receiving type does not know used to crash the process.
    ///
    /// `allKeys` stopped at a precondition when a key could not be converted to the container's key type. A
    /// synthesized conformance for an enum with associated values reads `allKeys` to find the case, so a newer
    /// peer sending a case an older receiver lacks made the receiver trap instead of failing to decode.
    @Test func `An enumeration case the receiver does not know throws instead of crashing`() throws {
        let triangle = try XPCEncoder().encode(NewerShape.triangle(base: 3, height: 4))

        #expect(throws: DecodingError.self) {
            _ = try XPCDecoder().decode(type: Shape.self, from: triangle)
        }
    }

    @Test func `An enumeration case both sides know still decodes`() throws {
        let square = try XPCEncoder().encode(NewerShape.square(side: 2))

        #expect(try XPCDecoder().decode(type: Shape.self, from: square) == .square(side: 2))
    }
    /// Regression test: a value that needs a keyed container but arrives as something else used to crash.
    ///
    /// The keyed container did not check that it wrapped a dictionary before `allKeys` handed the object to
    /// `xpc_dictionary_apply`, which XPC treats as API misuse and traps on.
    @Test func `A keyed value that arrives as another type throws instead of crashing`() throws {
        #expect(throws: DecodingError.self) {
            _ = try XPCDecoder().decode(type: Shape.self, from: xpc_int64_create(7))
        }
    }

    /// Regression test: encoding a class hierarchy through `superEncoder()` used to stop at a precondition.
    @Test func `A class hierarchy encoded through superEncoder round-trips`() throws {
        let bicycle = Bicycle(wheels: 2, gears: 21)

        let roundTripped = try self.roundTrip(bicycle)

        #expect(roundTripped.wheels == 2)
        #expect(roundTripped.gears == 21)
    }

    /// Regression test: `superDecoder(forKey:)` used to read the `super` key instead of the key it was given.
    @Test func `A value kept under superEncoder(forKey:) round-trips`() throws {
        let labelled = Labelled(label: "answer", value: 42)

        #expect(try self.roundTrip(labelled) == labelled)
    }
    /// Regression test: asking the decoder for a second container used to stop at a precondition.
    ///
    /// Trying one representation and falling back to another is a common way to accept several formats.
    @Test func `A type that asks for a second container decodes`() throws {
        let encoded = try XPCEncoder().encode(KeyedIdentifier(value: "identifier"))

        #expect(try XPCDecoder().decode(type: FlexibleIdentifier.self, from: encoded) == FlexibleIdentifier(value: "identifier"))
    }

    /// Regression test: an error case that a newer peer added used to make the whole error undecodable.
    ///
    /// Before the coder skipped unknown keys, it trapped; once it threw instead, that error replaced the one the peer
    /// sent. The error now arrives as its domain and code.
    @Test func `An error case the receiver does not know arrives as its domain and code`() throws {
        let domain = "SwiftyXPCTests.CoderRoundTripTests.Failure"
        XPCErrorRegistry.shared.registerDomain(domain, forErrorType: OlderFailure.self)

        let encoded = try XPCErrorRegistry.shared.encodeError(NewerFailure.quotaExceeded(limit: 3), domain: domain)
        let decoded = try XPCErrorRegistry.shared.decodeError(encoded)

        let boxedError = try #require(decoded as? XPCErrorRegistry.BoxedError)
        #expect(boxedError.errorDomain == domain)
        #expect(boxedError.errorCode == NewerFailure.quotaExceeded(limit: 3)._code)
    }

    @Test func `An error case both sides know still arrives as itself`() throws {
        let domain = "SwiftyXPCTests.CoderRoundTripTests.KnownFailure"
        XPCErrorRegistry.shared.registerDomain(domain, forErrorType: OlderFailure.self)

        let encoded = try XPCErrorRegistry.shared.encodeError(NewerFailure.timedOut, domain: domain)

        #expect(try XPCErrorRegistry.shared.decodeError(encoded) is OlderFailure)
    }
}
#endif
