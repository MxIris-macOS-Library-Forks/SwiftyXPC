// Exercises the 1.0 test helper with a client built from SwiftyXPC 0.5.105.
//
// Run it while the 1.0 `TestHelper` is loaded as the `com.charlessoft.SwiftyXPC.TestHelper` Mach service; see
// Tests/Interop/README.md. The exit status is the number of failed checks.

import Darwin
import Foundation
import InteropShared
import SwiftyXPC

XPCErrorRegistry.shared.registerDomain(DataInfo.DataError.domain, forErrorType: DataInfo.DataError.self)
XPCErrorRegistry.shared.registerDomain(JokeMessage.NotAKnockKnockJoke.domain, forErrorType: JokeMessage.NotAKnockKnockJoke.self)

let runner = CheckRunner()

func openConnection() throws -> XPCConnection {
    let connection = try XPCConnection(type: .remoteMachService(serviceName: helperID, isPrivilegedHelperTool: false))
    connection.activate()
    return connection
}

await runner.check("request and response") {
    let response: String = try await openConnection().sendMessage(name: CommandSet.capitalizeString, request: "interop")
    try expect(response == "INTEROP", "got \(response)")

    let product: Double = try await openConnection().sendMessage(name: CommandSet.multiplyBy5, request: 3.7)
    try expect(abs(product - 18.5) < 0.001, "got \(product)")
}

await runner.check("nested data") {
    let dataInfo: DataInfo = try await openConnection().sendMessage(
        name: CommandSet.transportData,
        request: "One to beam up".data(using: .utf8)!
    )
    try expect(String(data: dataInfo.characterName, encoding: .utf8) == "Lt. Cmdr. Data", "got \(dataInfo)")
    try expect(dataInfo.otherCharacters.count == 6, "got \(dataInfo.otherCharacters.count) other characters")
}

await runner.check("handler error") {
    do {
        try await openConnection().sendMessage(name: CommandSet.transportData, request: "Lore".data(using: .utf8)!)
        throw Mismatch("the request succeeded")
    } catch let error as DataInfo.DataError {
        try expect(error.failureReason == "fluctuation in the positronic matrix", "got \(error)")
    }
}

await runner.check("process identifiers") {
    let ids: ProcessIDs = try await openConnection().sendMessage(name: CommandSet.reportIDs)
    try expect(ids.pid > 0 && ids.pid != getpid(), "got pid \(ids.pid)")
}

await runner.check("one-way message draws no answer") {
    let connection = try openConnection()
    let errors = Recorder<String>()
    connection.errorHandler = { _, error in errors.record(String(describing: error)) }

    try connection.sendOnewayMessage(name: CommandSet.pauseOneSecond, message: XPCNull.shared)

    // A 0.5 receiver would answer once its one-second handler returned; give it time to.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let _: String = try await connection.sendMessage(name: CommandSet.capitalizeString, request: "flush")
    try expect(errors.values.isEmpty, "error handler received \(errors.values)")
}

await runner.check("unknown message name is answered with unexpectedMessage") {
    do {
        try await openConnection().sendMessage(name: "com.charlessoft.SwiftyXPC.Tests.NoSuchMessage")
        throw Mismatch("the request succeeded")
    } catch XPCConnection.Error.unexpectedMessage {
        // A 1.0 receiver answers; a 0.5 one left the sender with connectionInterrupted.
    }
}

func makeJokeListener(punchline: String, events: Recorder<String>, errors: Recorder<String>) throws -> SwiftyXPC.XPCListener {
    let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)

    listener.setMessageHandler(name: JokeMessage.askForJoke) { (_: XPCConnection, request: String) -> String in
        events.record(request)
        return punchline
    }

    listener.setMessageHandler(name: JokeMessage.whosThere) { (_: XPCConnection, request: String) -> String in
        events.record(request)
        return "Orange"
    }

    listener.setMessageHandler(name: JokeMessage.who) { (_: XPCConnection, request: String) -> String in
        events.record(request)
        return "Orange you glad this example is so silly?"
    }

    listener.setMessageHandler(name: JokeMessage.groan) { (_: XPCConnection, request: String) in
        events.record(request)
    }

    listener.errorHandler = { _, error in
        if case .connectionInvalid = error as? XPCError {
            return
        }

        errors.record(String(describing: error))
    }

    listener.activate()
    return listener
}

await runner.check("endpoint and requests in the other direction") {
    let events = Recorder<String>()
    let errors = Recorder<String>()
    let listener = try makeJokeListener(punchline: "Knock knock", events: events, errors: errors)
    defer { listener.cancel() }

    try await openConnection().sendMessage(name: CommandSet.tellAJoke, request: listener.endpoint)
    try await events.waitUntil(count: 4)

    try expect(
        events.values == ["Tell me a joke", "Who's there?", "Orange who?", "That was awful!"],
        "got \(events.values)"
    )
    try expect(errors.values.isEmpty, "listener error handler received \(errors.values)")
}

await runner.check("error from a handler that sent requests of its own") {
    let events = Recorder<String>()
    let errors = Recorder<String>()
    let listener = try makeJokeListener(punchline: "A `foo` walks into a `bar`", events: events, errors: errors)
    defer { listener.cancel() }

    do {
        try await openConnection().sendMessage(name: CommandSet.tellAJoke, request: listener.endpoint)
        throw Mismatch("the request succeeded")
    } catch let error as JokeMessage.NotAKnockKnockJoke {
        try expect(error.complaint == "That was not a knock knock joke!", "got \(error)")
    }
}

print("\(runner.failures) failed")
exit(Int32(runner.failures))
