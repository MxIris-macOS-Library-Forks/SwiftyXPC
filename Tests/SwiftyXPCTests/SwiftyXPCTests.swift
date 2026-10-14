#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import System
import Testing

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
        let goodConn = try self.openConnection(codeSigningRequirement: self.helperCodeSigningRequirement())

        let response: String = try await goodConn.sendMessage(name: CommandSet.capitalizeString, request: "Testing 1 2 3")
        #expect(response == "TESTING 1 2 3")

        let badConn = try self.openConnection(codeSigningRequirement: "identifier \"com.apple.true\" and anchor apple")

        let verificationError = await #expect(throws: XPCError.self) {
            try await badConn.sendMessage(name: CommandSet.capitalizeString, request: "Testing 1 2 3")
        }
        #expect(verificationError?.unknownDescription == "Peer Forbidden")

        let requirementError = #expect(throws: XPCError.self) {
            _ = try self.openConnection(codeSigningRequirement: "")
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

        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)

        let events = Recorder<String>()
        let errors = Recorder<String>()

        listener.setMessageHandler(name: JokeMessage.askForJoke) { (_, request: String) -> String in
            #expect(request == "Tell me a joke")
            events.record(JokeMessage.askForJoke)
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
    }

    @Test func `Two-way communication with error`() async throws {
        XPCErrorRegistry.shared.registerDomain(forErrorType: JokeMessage.NotAKnockKnockJoke.self)
        let conn = try self.openConnection()

        let listener = try XPCListener(type: .anonymous, codeSigningRequirement: nil)
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
    }

    private func helperCodeSigningRequirement() throws -> String {
        try #require(LaunchedTestHelper.current).codeSigningRequirement
    }

    private func openConnection(codeSigningRequirement: String? = nil) throws -> XPCConnection {
        let conn = try XPCConnection(
            type: .remoteMachService(serviceName: helperID, isPrivilegedHelperTool: false),
            codeSigningRequirement: codeSigningRequirement ?? self.helperCodeSigningRequirement()
        )
        conn.activate()

        return conn
    }
}
#endif
