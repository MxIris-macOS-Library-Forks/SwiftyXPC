//
//  ServiceDelegate.swift
//  Example XPC Service
//
//  Created by Charles Srstka on 5/5/22.
//

import SwiftyXPC

@main
final class XPCService: Sendable {
    static func main() {
        do {
            let xpcService = XPCService()

            // In an actual product, you should always require something of the peer here, for security; for instance
            // `.codeSigning("anchor apple generic and identifier \"com.charlessoft.SwiftyXPC.Example-App\"")`.
            let requirement: XPCPeerRequirement? = nil

            let serviceListener = try XPCListener(type: .service, requirement: requirement)

            serviceListener.setMessageHandler(name: CommandSet.capitalizeString, handler: xpcService.capitalizeString)
            serviceListener.setMessageHandler(name: CommandSet.longRunningTask, handler: xpcService.longRunningTask)

            serviceListener.activate()
            fatalError("Should never get here")
        } catch {
            fatalError("Error while setting up XPC service: \(error)")
        }
    }

    private func capitalizeString(_: XPCMessageContext, string: String) async throws -> String {
        return string.uppercased()
    }

    private func longRunningTask(_: XPCMessageContext, endpoint: XPCEndpoint) async throws {
        let remoteConnection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))

        remoteConnection.activate()

        for i in 0...100 {
            try await Task.sleep(for: .milliseconds(500))

            try remoteConnection.sendOnewayMessage(
                name: LongRunningTaskMessage.progressNotification,
                message: Double(i) / 100.0
            )
        }
    }
}
