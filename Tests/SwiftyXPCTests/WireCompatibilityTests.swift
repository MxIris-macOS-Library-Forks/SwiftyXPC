#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Testing

@testable import SwiftyXPC

/// Tests that SwiftyXPC 1.0 and 0.5 understand each other's messages.
///
/// Peers are often updated separately — a privileged helper outlives several versions of its app — so the wire format
/// that 0.5 produces and expects is a contract. These tests pin it down without a 0.5 build at hand.
// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
struct WireCompatibilityTests {
    /// `XPCError` as SwiftyXPC 0.5 declares it. Its synthesized `Codable` conformance is the format 0.5 peers use.
    enum LegacyXPCError: Error, Codable, Equatable {
        case connectionInterrupted
        case connectionInvalid
        case terminationImminent
        case invalidCodeSignatureRequirement
        case unknown(String)
    }

    private func reencode<Source: Encodable, Destination: Decodable>(
        _ value: Source,
        as destinationType: Destination.Type
    ) throws -> Destination {
        try XPCDecoder().decode(type: destinationType, from: XPCEncoder().encode(value))
    }

    @Test func `An invalid connection from a 0.5 peer arrives without a reason`() throws {
        let error = try self.reencode(LegacyXPCError.connectionInvalid, as: XPCError.self)

        #expect(error.isConnectionInvalid)
        #expect(error.invalidationReason == nil)
    }

    @Test(arguments: ["xpc_connection_cancel()", nil] as [String?])
    func `An invalid connection reaches a 0.5 peer as plain connectionInvalid`(reason: String?) throws {
        #expect(try self.reencode(XPCError.connectionInvalid(reason: reason), as: LegacyXPCError.self) == .connectionInvalid)
    }

    @Test func `Unchanged cases decode the same in both directions`() throws {
        #expect(try self.reencode(LegacyXPCError.unknown("Peer Forbidden"), as: XPCError.self).unknownDescription == "Peer Forbidden")
        #expect(try self.reencode(XPCError.unknown("Peer Forbidden"), as: LegacyXPCError.self) == .unknown("Peer Forbidden"))
        #expect(try self.reencode(XPCError.connectionInterrupted, as: LegacyXPCError.self) == .connectionInterrupted)
    }

    /// The registry finds `XPCError` by this domain on both sides, so it must not change.
    @Test func `XPCError keeps its error domain`() {
        #expect(String(reflecting: XPCError.self) == "SwiftyXPC.XPCError")
        #expect(String(reflecting: XPCConnection.Error.self) == "SwiftyXPC.XPCConnection.Error")
    }
}
#endif
