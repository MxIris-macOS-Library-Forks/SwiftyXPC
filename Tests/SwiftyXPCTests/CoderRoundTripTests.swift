#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Testing

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
}
#endif
