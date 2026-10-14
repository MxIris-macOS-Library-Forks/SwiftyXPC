#if os(macOS) || targetEnvironment(macCatalyst)
//
//  XPCFileDescriptorWrapper.swift
//  SwiftyXPC
//
//  Created by Charles Srstka on 7/24/21.
//

import Darwin
import System

/// An owned wrapper around a file descriptor, which can be embedded within XPC messages to send file descriptors to other processes.
///
/// This wrapper takes ownership of the file descriptor so the user doesn't need to close it manually: the descriptor is
/// closed when the wrapper is deinitialized.
///
/// You can also embed a `FileDescriptor` from the `System` module. However, a `FileDescriptor` is not owned, so you will
/// need to make sure the file descriptor is not closed in the sender process before the message is embedded in an XPC message.
public final class XPCFileDescriptor: Codable {
    internal let fileDescriptor: Int32

    /// Create an `XPCFileDescriptor` from a raw file descriptor and take the ownership of it.
    /// The file descriptor will be closed automatically when this instance is deinitialized.
    public init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Create an `XPCFileDescriptor` from a `FileDescriptor` and take the ownership of it.
    /// The file descriptor will be closed automatically when this instance is deinitialized.
    public init(fileDescriptor: FileDescriptor) {
        self.fileDescriptor = fileDescriptor.rawValue
    }

    /// Duplicate the file descriptor. The caller is responsible for closing the returned file descriptor.
    public func dup() throws -> Int32 {
        let fd = Darwin.dup(fileDescriptor)

        if fd < 0 {
            throw Errno(rawValue: errno)
        }

        return fd
    }

    /// Duplicate the file descriptor. The caller is responsible for closing the returned `FileDescriptor`.
    public func duplicate() throws -> FileDescriptor {
        try FileDescriptor(rawValue: self.fileDescriptor).duplicate()
    }

    deinit {
        close(self.fileDescriptor)
    }
}
#endif
