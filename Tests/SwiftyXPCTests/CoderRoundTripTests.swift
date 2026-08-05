#if os(macOS) || targetEnvironment(macCatalyst)
import XCTest

@testable import SwiftyXPC

/// Round-trip tests for `XPCEncoder` and `XPCDecoder` that need no XPC connection.
///
/// These deliberately do not subclass the helper-launching test case, so they run anywhere.
// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
final class CoderRoundTripTests: XCTestCase {
    private func assertRoundTrips<Value: Codable & Equatable>(
        _ value: Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try XPCEncoder().encode(value)
        let decoded = try XPCDecoder().decode(type: Value.self, from: encoded)

        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    private struct StructureWithData: Codable, Equatable {
        let data: Data
    }

    private struct StructureWithArray: Codable, Equatable {
        let numbers: [Int]
    }

    private struct StructureWithNestedStructure: Codable, Equatable {
        let inner: StructureWithData
    }

    private enum EnumerationWithPayload: Codable, Equatable {
        case text(String)
        case pair(first: String, second: String)
        case data(Data)
        case numbers([Int])
        case dataAndText(data: Data, text: String)
    }

    private indirect enum NestedEnumeration: Codable, Equatable {
        case wrap(inner: NestedEnumeration)
        case leaf(data: Data, numbers: [Int])
    }

    private struct StructureWithEnumerationArray: Codable, Equatable {
        let items: [NestedEnumeration]
    }

    func testCollectionsAtTheTopLevelOfAStructureRoundTrip() throws {
        try self.assertRoundTrips(StructureWithData(data: Data([1, 2, 3])))
        try self.assertRoundTrips(StructureWithArray(numbers: [1, 2, 3]))
        try self.assertRoundTrips(StructureWithNestedStructure(inner: StructureWithData(data: Data([1, 2, 3]))))
    }

    /// Regression test: collections carried as an enum's associated values used to be lost.
    ///
    /// A synthesized `Codable` conformance for an enum with associated values is the one shape that
    /// reaches for `nestedContainer(keyedBy:forKey:)`. The encoder's finalization pass only descended
    /// one level into nested containers, so an unkeyed container underneath one — which is how `Data`
    /// and arrays encode — never got its `Contents` key written. Encoding reported success, and the
    /// far end then failed to decode with `NSCocoaErrorDomain` 4864, "The data couldn't be read
    /// because it isn't in the correct format."
    func testCollectionsCarriedByEnumerationCasesRoundTrip() throws {
        try self.assertRoundTrips(EnumerationWithPayload.text("hello"))
        try self.assertRoundTrips(EnumerationWithPayload.pair(first: "first", second: "second"))
        try self.assertRoundTrips(EnumerationWithPayload.data(Data([1, 2, 3])))
        try self.assertRoundTrips(EnumerationWithPayload.numbers([1, 2, 3]))
        try self.assertRoundTrips(EnumerationWithPayload.dataAndText(data: Data([1, 2, 3]), text: "text"))
        try self.assertRoundTrips(EnumerationWithPayload.data(Data()))
    }

    /// The same failure at greater depth, which one extra level of descent would still have missed.
    func testCollectionsNestedSeveralContainersDeepRoundTrip() throws {
        try self.assertRoundTrips(
            NestedEnumeration.wrap(inner: .wrap(inner: .leaf(data: Data([9, 8, 7]), numbers: [4, 5])))
        )
        try self.assertRoundTrips(
            StructureWithEnumerationArray(
                items: [
                    .leaf(data: Data([1]), numbers: [2]),
                    .leaf(data: Data([3]), numbers: [4]),
                ]
            )
        )
    }
}
#endif
