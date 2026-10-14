//
//  MessageSender.swift
//  Example App
//
//  Created by Charles Srstka on 5/5/22.
//

import Foundation
import SwiftyXPC
import os

actor MessageSender {
    static let shared = try! MessageSender()

    private let connection: XPCConnection

    private init() throws {
        let connection = try XPCConnection(type: .remoteService(bundleID: "com.charlessoft.SwiftyXPC.Example-App.xpc"))

        let logger = Logger()

        connection.errorHandler = { _, error in
            logger.error("The connection to the XPC service received an error: \(error.localizedDescription)")
        }

        connection.activate()
        self.connection = connection
    }

    func capitalize(string: String) async throws -> String {
        try await self.connection.sendMessage(name: CommandSet.capitalizeString, request: string)
    }

    func startLongRunningTask(callback: @escaping @Sendable (Double?) -> Void) async throws {
        let listener = try XPCListener(type: .anonymous)  // in an actual product, pass a requirement

        // The service reports progress with one-way messages, which arrive in the order it sent them.
        listener.setMessageHandler(name: LongRunningTaskMessage.progressNotification) { (_, progress: Double) in
            callback(progress)
        }

        listener.errorHandler = { _, error in
            callback(nil)
            print("something went wrong: \(error)")
        }

        listener.activate()

        try await self.connection.sendMessage(name: CommandSet.longRunningTask, request: listener.endpoint)
    }
}
