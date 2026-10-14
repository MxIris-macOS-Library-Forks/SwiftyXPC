#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Security
import Testing
import XPC

@testable import SwiftyXPC

/// Tests of `XPCMessageContext.senderSatisfies(_:)`, run with this process as the sender.
// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
struct SenderRequirementTests {
    /// The designated requirement and signing identifier of this process, the test runner.
    struct OwnSignature {
        let designatedRequirement: String
        let signingIdentifier: String

        init() throws {
            var code: SecCode?
            try #require(SecCodeCopySelf([], &code) == errSecSuccess)

            var staticCode: SecStaticCode?
            try #require(SecCodeCopyStaticCode(try #require(code), [], &staticCode) == errSecSuccess)

            var requirement: SecRequirement?
            try #require(SecCodeCopyDesignatedRequirement(try #require(staticCode), [], &requirement) == errSecSuccess)

            var requirementString: CFString?
            try #require(SecRequirementCopyString(try #require(requirement), [], &requirementString) == errSecSuccess)

            var information: CFDictionary?
            try #require(
                SecCodeCopySigningInformation(
                    try #require(staticCode),
                    SecCSFlags(rawValue: kSecCSSigningInformation),
                    &information
                ) == errSecSuccess
            )

            self.designatedRequirement = try #require(requirementString) as String
            self.signingIdentifier = try #require((information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String)
        }
    }

    /// Sends one message to a listener in this process and returns what `senderSatisfies(_:)` said about each requirement.
    @available(macOS 26.0, macCatalyst 26.0, *)
    private func check(_ requirements: [SwiftyXPC.XPCPeerRequirement]) async throws -> [Result<Bool, XPCError>] {
        let results = Recorder<Result<Bool, XPCError>>()

        let listener = try SwiftyXPC.XPCListener(type: .anonymous)
        listener.setMessageHandler(name: "check") { context in
            for requirement in requirements {
                results.record(Result { () throws(XPCError) -> Bool in
                    do {
                        return try context.senderSatisfies(requirement)
                    } catch let error as XPCError {
                        throw error
                    } catch {
                        throw XPCError.unknown(String(describing: error))
                    }
                })
            }
        }
        listener.activate()
        defer { listener.cancel() }

        let connection = try XPCConnection(type: .remoteServiceFromEndpoint(listener.endpoint))
        connection.activate()
        defer { connection.cancel() }

        try await connection.sendMessage(name: "check")

        return results.values
    }

    private static func lightweightCodeRequirement(signingIdentifier: String) -> xpc_object_t {
        let requirement = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(requirement, "signing-identifier", signingIdentifier)
        return requirement
    }

    @available(macOS 26.0, macCatalyst 26.0, *)
    @Test func `The sender satisfies its own designated requirement`() async throws {
        let ownSignature = try OwnSignature()

        let results = try await self.check([.codeSigning(ownSignature.designatedRequirement)])

        #expect(try results.map { try $0.get() } == [true])
    }

    @available(macOS 26.0, macCatalyst 26.0, *)
    @Test func `The sender satisfies a lightweight code requirement for its own identifier`() async throws {
        let ownSignature = try OwnSignature()

        let results = try await self.check([
            .lightweightCodeRequirement(Self.lightweightCodeRequirement(signingIdentifier: ownSignature.signingIdentifier))
        ])

        #expect(try results.map { try $0.get() } == [true])
    }

    @available(macOS 26.0, macCatalyst 26.0, *)
    @Test func `The sender fails requirements it does not meet`() async throws {
        let results = try await self.check([
            .codeSigning("identifier \"com.charlessoft.SwiftyXPC.Tests.NoSuchProcess\""),
            .hasEntitlement("com.charlessoft.SwiftyXPC.Tests.NoSuchEntitlement"),
            .lightweightCodeRequirement(
                Self.lightweightCodeRequirement(signingIdentifier: "com.charlessoft.SwiftyXPC.Tests.NoSuchProcess")
            ),
        ])

        #expect(try results.map { try $0.get() } == [false, false, false])
    }

    @available(macOS 26.0, macCatalyst 26.0, *)
    @Test func `A requirement that does not parse is an error, not a verdict`() async throws {
        let unknownOperator = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(unknownOperator, "$frobnicate", 1)

        let results = try await self.check([.codeSigning(""), .lightweightCodeRequirement(unknownOperator)])

        try #require(results.count == 2)
        #expect(throws: XPCError.self) { try results[0].get() }
        #expect(throws: XPCError.self) { try results[1].get() }
    }
}
#endif
