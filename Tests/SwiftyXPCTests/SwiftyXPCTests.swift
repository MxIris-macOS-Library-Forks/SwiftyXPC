#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import System
import Testing
import XPC

@testable import SwiftyXPC
import TestShared

/// Tests that talk to the `TestHelper` Mach service in another process.
///
/// The tests share one helper instance, which `LaunchedTestHelper` loads into launchd for the whole suite.
// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
@Suite(.serialized, .launchedTestHelper)
struct SwiftyXPCTests {
    @Test func `Process IDs`() async throws {
        let conn = try self.openConnection()

        let ids: ProcessIDs = try await conn.sendMessage(name: CommandSet.reportIDs)

        #expect(ids.pid == conn.processIdentifier)
        #expect(ids.effectiveUID == conn.effectiveUserIdentifier)
        #expect(ids.effectiveGID == conn.effectiveGroupIdentifier)
        #expect(ids.auditSessionID == conn.auditSessionIdentifier)
    }

    @Test func `Code signature verification`() async throws {
        let goodConn = try self.openConnection(requirement: .codeSigning(self.helperCodeSigningRequirement()))

        let response: String = try await goodConn.sendMessage(name: CommandSet.capitalizeString, request: "Testing 1 2 3")
        #expect(response == "TESTING 1 2 3")

        let badConn = try self.openConnection(requirement: .codeSigning("identifier \"com.apple.true\" and anchor apple"))

        let verificationError = await #expect(throws: XPCError.self) {
            try await badConn.sendMessage(name: CommandSet.capitalizeString, request: "Testing 1 2 3")
        }
        #expect(verificationError?.unknownDescription == "Peer Forbidden")

        let requirementError = #expect(throws: XPCError.self) {
            _ = try self.openConnection(requirement: .codeSigning(""))
        }
        #expect(requirementError?.isInvalidCodeSignatureRequirement == true)
    }

    @Test func `Simple request and response`() async throws {
        let conn = try self.openConnection()

        let stringResponse: String = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "hi there")
        #expect(stringResponse == "HI THERE")

        let doubleResponse: Double = try await conn.sendMessage(name: CommandSet.multiplyBy5, request: 3.7)
        #expect(abs(doubleResponse - 18.5) <= 0.001)
    }

    @Test func `Data transport`() async throws {
        let conn = try self.openConnection()

        let dataInfo: DataInfo = try await conn.sendMessage(
            name: CommandSet.transportData,
            request: "One to beam up".data(using: .utf8)!
        )

        #expect(String(data: dataInfo.characterName, encoding: .utf8) == "Lt. Cmdr. Data")
        #expect(String(data: dataInfo.playedBy, encoding: .utf8) == "Brent Spiner")
        #expect(
            dataInfo.otherCharacters.map { String(data: $0, encoding: .utf8) }
                == ["Lore", "B4", "Noonien Soong", "Arik Soong", "Altan Soong", "Adam Soong"]
        )

        XPCErrorRegistry.shared.registerDomain(forErrorType: DataInfo.DataError.self)

        let dataError = await #expect(throws: DataInfo.DataError.self) {
            try await conn.sendMessage(name: CommandSet.transportData, request: "It's Lore being sneaky".data(using: .utf8)!)
        }
        #expect(dataError?.failureReason == "fluctuation in the positronic matrix")
    }

    @Test func `Two-way communication`() async throws {
        let conn = try self.openConnection()

        let listener = try SwiftyXPC.XPCListener(type: .anonymous)

        let events = Recorder<String>()
        let errors = Recorder<String>()
        let senderProcessIdentifiers = Recorder<pid_t>()

        listener.setMessageHandler(name: JokeMessage.askForJoke) { (context, request: String) -> String in
            #expect(request == "Tell me a joke")
            events.record(JokeMessage.askForJoke)
            senderProcessIdentifiers.record(context.processIdentifier)
            return "Knock knock"
        }

        listener.setMessageHandler(name: JokeMessage.whosThere) { (_, request: String) -> String in
            #expect(request == "Who's there?")
            events.record(JokeMessage.whosThere)
            return "Orange"
        }

        listener.setMessageHandler(name: JokeMessage.who) { (_, request: String) -> String in
            #expect(request == "Orange who?")
            events.record(JokeMessage.who)
            return "Orange you glad this example is so silly?"
        }

        listener.setMessageHandler(name: JokeMessage.groan) { (_, request: String) in
            #expect(request == "That was awful!")
            events.record(JokeMessage.groan)
        }

        listener.errorHandler = { _, error in
            if (error as? XPCError)?.isConnectionInvalid == true {
                // connection can go down once we've received the last message
                return
            }

            errors.record(String(describing: error))
        }

        listener.activate()

        try await conn.sendMessage(name: CommandSet.tellAJoke, request: listener.endpoint)

        // The groan is a one-way message, so it can still be on its way when `tellAJoke` returns.
        #expect(try await events.waitUntil(count: 4))
        #expect(events.values == [JokeMessage.askForJoke, JokeMessage.whosThere, JokeMessage.who, JokeMessage.groan])
        #expect(errors.values.isEmpty)

        // The joke came from the helper, which reports its own process identifier.
        let helperIDs: ProcessIDs = try await conn.sendMessage(name: CommandSet.reportIDs)
        #expect(senderProcessIdentifiers.values == [helperIDs.pid])
    }

    @Test func `Two-way communication with error`() async throws {
        XPCErrorRegistry.shared.registerDomain(forErrorType: JokeMessage.NotAKnockKnockJoke.self)
        let conn = try self.openConnection()

        let listener = try SwiftyXPC.XPCListener(type: .anonymous)
        let errors = Recorder<String>()

        listener.setMessageHandler(name: JokeMessage.askForJoke) { (_, request: String) -> String in
            #expect(request == "Tell me a joke")
            return "A `foo` walks into a `bar`"
        }

        listener.errorHandler = { _, error in
            if (error as? XPCError)?.isConnectionInvalid == true {
                // connection can go down once we've received the last message
                return
            }

            errors.record(String(describing: error))
        }

        listener.activate()

        let jokeError = await #expect(throws: JokeMessage.NotAKnockKnockJoke.self) {
            try await conn.sendMessage(name: CommandSet.tellAJoke, request: listener.endpoint)
        }
        #expect(jokeError?.complaint == "That was not a knock knock joke!")
        #expect(errors.values.isEmpty)
    }

    @Test func `One-way vs two-way`() async throws {
        let conn = try self.openConnection()

        var date = Date.now
        try await conn.sendMessage(name: CommandSet.pauseOneSecond)
        #expect(Date.now.timeIntervalSince(date) >= 1.0)

        date = Date.now
        try conn.sendOnewayMessage(name: CommandSet.pauseOneSecond, message: XPCNull())
        #expect(Date.now.timeIntervalSince(date) < 0.5)
    }

    @Test func `Cancel connection`() async throws {
        let conn = try self.openConnection()

        let response: String = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "will work")
        #expect(response == "WILL WORK")

        conn.cancel()

        let cancellationError = await #expect(throws: XPCError.self) {
            _ = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "won't work") as String
        }
        #expect(cancellationError?.isConnectionInvalid == true)

        // XPC words the reason itself ("xpc_connection_cancel()" on macOS 27), so only its presence is checked.
        #expect(cancellationError?.invalidationReason != nil)
    }

    @available(macOS 14.4, macCatalyst 17.4, *)
    @Test func `A peer without a required entitlement is rejected`() async throws {
        let conn = try self.openConnection(requirement: .hasEntitlement("com.charlessoft.SwiftyXPC.Tests.NoSuchEntitlement"))
        defer { conn.cancel() }

        let error = await #expect(throws: XPCError.self) {
            try await conn.sendMessage(name: CommandSet.capitalizeString, request: "rejected")
        }
        #expect(error?.unknownDescription == "Peer Forbidden")
    }

    @available(macOS 14.4, macCatalyst 17.4, *)
    @Test func `A peer that is not part of the operating system fails a platform requirement`() async throws {
        let conn = try self.openConnection(requirement: .isPlatformCode())
        defer { conn.cancel() }

        let error = await #expect(throws: XPCError.self) {
            try await conn.sendMessage(name: CommandSet.capitalizeString, request: "rejected")
        }
        #expect(error?.unknownDescription == "Peer Forbidden")
    }

    @available(macOS 14.4, macCatalyst 17.4, *)
    @Test func `A lightweight code requirement admits a matching peer`() async throws {
        let requirement = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(requirement, "signing-identifier", try self.helperSigningIdentifier())

        let conn = try self.openConnection(requirement: .lightweightCodeRequirement(requirement))
        defer { conn.cancel() }

        let response: String = try await conn.sendMessage(name: CommandSet.capitalizeString, request: "admitted")
        #expect(response == "ADMITTED")
    }

    @available(macOS 14.4, macCatalyst 17.4, *)
    @Test func `A lightweight code requirement with an unknown operator is rejected`() throws {
        let requirement = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(requirement, "$frobnicate", 1)

        let error = #expect(throws: XPCError.self) {
            _ = try self.openConnection(requirement: .lightweightCodeRequirement(requirement))
        }
        #expect(error?.isInvalidPeerRequirement == true)
    }

    @available(macOS 14.4, macCatalyst 17.4, *)
    @Test func `A lightweight code requirement that is not a dictionary is rejected`() throws {
        let error = #expect(throws: XPCError.self) {
            _ = try self.openConnection(requirement: .lightweightCodeRequirement(xpc_int64_create(1)))
        }
        #expect(error?.isInvalidPeerRequirement == true)
    }

    private func helperCodeSigningRequirement() throws -> String {
        try #require(LaunchedTestHelper.current).codeSigningRequirement
    }

    private func helperSigningIdentifier() throws -> String {
        try #require(LaunchedTestHelper.current).signingIdentifier
    }

    /// Opens a connection to the helper that requires `requirement`, or the helper's designated requirement if `nil`.
    private func openConnection(requirement: SwiftyXPC.XPCPeerRequirement? = nil) throws -> XPCConnection {
        let conn = try XPCConnection(
            type: .remoteMachService(serviceName: helperID, isPrivilegedHelperTool: false),
            requirement: requirement ?? .codeSigning(self.helperCodeSigningRequirement())
        )
        conn.activate()

        return conn
    }
}
#endif
