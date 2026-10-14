#if os(macOS) || targetEnvironment(macCatalyst)
//
//  XPCFileDescriptorWrapper.swift
//  SwiftyXPC
//
//  Created by Charles Srstka on 7/24/21.
//

import Darwin
import System
import XPC

/// An owned wrapper around a file descriptor, which can be embedded within XPC messages to send file descriptors to other processes.
///
/// This wrapper takes ownership of the file descriptor so the user doesn't need to close it manually: the descriptor is
/// closed when the wrapper is deinitialized.
///
/// You can also embed a `FileDescriptor` from the `System` module. However, a `FileDescriptor` is not owned, so you will
/// need to make sure the file descriptor is not closed in the sender process before the message is embedded in an XPC message.
///
/// A file descriptor travels in a message as an XPC file descriptor object, which gives the receiving process its own
/// duplicate, so only `XPCEncoder` and `XPCDecoder` can encode and decode it.
public final class XPCFileDescriptor: XPCObjectRepresentable, Sendable {
    /// The XPC type of the object that represents a file descriptor: `.fileDescriptor`.
    public static var xpcType: XPCType { .fileDescriptor }

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

    /// Create an `XPCFileDescriptor` that owns a duplicate of the file descriptor in an XPC file descriptor object.
    ///
    /// - Parameter xpcObject: An XPC object of type `XPC_TYPE_FD`.
    ///
    /// - Throws: `XPCConnection.Error.typeMismatch` if `xpcObject` is not a file descriptor object, or an `Errno` if
    ///   the descriptor cannot be duplicated.
    public convenience init(xpcObject: xpc_object_t) throws {
        guard xpc_get_type(xpcObject) == XPC_TYPE_FD else {
            throw XPCConnection.Error.typeMismatch(expected: .fileDescriptor, actual: xpcObject.type)
        }

        let duplicate = xpc_fd_dup(xpcObject)

        if duplicate < 0 {
            throw Errno(rawValue: errno)
        }

        self.init(fileDescriptor: duplicate)
    }

    /// Returns an XPC file descriptor object that holds a duplicate of the file descriptor.
    ///
    /// - Throws: An `Errno` if the descriptor cannot be duplicated, for instance because it is not open.
    public func makeXPCObject() throws -> xpc_object_t {
        guard let object = xpc_fd_create(self.fileDescriptor) else {
            throw Errno(rawValue: errno)
        }

        return object
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
