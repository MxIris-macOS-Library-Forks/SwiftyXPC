#if os(macOS) || targetEnvironment(macCatalyst)
//
//  ProcessIDs.swift
//
//
//  Created by Charles Srstka on 10/14/23.
//

import Darwin
import SwiftyXPC
import System

// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
public struct ProcessIDs: Codable, Sendable {
    public let pid: pid_t
    public let effectiveUID: uid_t
    public let effectiveGID: gid_t
    #if os(macOS)
    public let auditSessionID: au_asid_t
    #endif

    public init(connection: XPCConnection) throws {
        self.pid = getpid()
        self.effectiveUID = geteuid()
        self.effectiveGID = getegid()
        #if os(macOS)
        self.auditSessionID = connection.auditSessionIdentifier
        #endif
    }
}
#endif
