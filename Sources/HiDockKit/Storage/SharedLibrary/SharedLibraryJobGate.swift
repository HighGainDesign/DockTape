// © 2026 High Gain Design. All rights reserved.
import Foundation
import Darwin

/// Local liveness only: the kernel releases shared leases on process exit.
/// Pinning and physical/ack commits also join the existing local metadata gate.
/// The empty file is never replaced, synced or used as a distributed lock.
public struct SharedLibraryJobGate: Sendable {
    let file: URL
    init(file: URL) { self.file = file.standardizedFileURL.resolvingSymlinksInPath() }
    func prepare(outside root: URL) throws {
        guard !SharedLibraryMaterializer.contained(file, in: root) else { throw SharedLibraryOperationError.unsafePath }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var directory = file.deletingLastPathComponent()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let descriptor = try openFile(create: true)
        Darwin.close(descriptor)
        var current = file; try current.setResourceValues(values)
    }
    private func openFile(create: Bool = false) throws -> Int32 {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0)
        let descriptor = Darwin.open(file.path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var actual = stat(), named = stat()
        guard fstat(descriptor, &actual) == 0, lstat(file.path, &named) == 0,
              actual.st_mode & S_IFMT == S_IFREG, actual.st_size == 0,
              actual.st_dev == named.st_dev, actual.st_ino == named.st_ino else {
            Darwin.close(descriptor); throw SharedLibraryOperationError.unsafePath
        }
        return descriptor
    }
    func acquireShared() throws -> Int32 {
        let descriptor = try openFile()
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            Darwin.close(descriptor); throw SharedLibraryOperationError.unfinishedOperation
        }
        return descriptor
    }
    func acquireExclusive() throws -> Int32? {
        let descriptor = try openFile()
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
        let failure = errno; Darwin.close(descriptor)
        if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }
    func hasActiveWork() throws -> Bool {
        guard let descriptor = try acquireExclusive() else { return true }
        Darwin.close(descriptor); return false
    }
}

/// Mutable descriptor ownership is actor isolated; release is idempotent.
actor SharedLocalJobLease {
    private var descriptor: Int32?
    init(descriptor: Int32) { self.descriptor = descriptor }
    func release() { if let descriptor { Darwin.close(descriptor); self.descriptor = nil } }
    deinit { if let descriptor { Darwin.close(descriptor) } }
}
