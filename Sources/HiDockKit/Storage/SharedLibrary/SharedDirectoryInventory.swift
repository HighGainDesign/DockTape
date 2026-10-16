// © 2026 High Gain Design. All rights reserved.
import Foundation
import CryptoKit

/// Exact subtree input for a directory move. It contains hashes, never copies
/// of original media; unknown and hidden ordinary files travel with the folder.
public struct SharedDirectoryInventory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let directory: Bool
        public let fingerprint: String?
    }
    public let entries: [Entry]
    func validate() throws {
        guard Set(entries.map(\.path)).count == entries.count, entries.map(\.path) == entries.map(\.path).sorted() else { throw SharedLibraryOperationError.invalidOperation }
        for entry in entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, !entry.path.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  entry.directory ? entry.fingerprint == nil : entry.fingerprint.map(SharedLibraryOperation.validHash) == true else { throw SharedLibraryOperationError.invalidOperation }
        }
    }
    static func prepare(at directory: URL) async throws -> Self {
        let files = try await Task.detached { try Self.files(at: directory) }.value
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if attributes[.type] as? FileAttributeType == .typeRegular {
                let name = file.lastPathComponent
                let logical = name.hasPrefix(".") && name.hasSuffix(".icloud")
                    ? file.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7))) : file
                _ = try await RecordingFileAccess().waitUntilAvailable(at: logical, knownToExist: true)
            }
        }
        return try await CoordinatedFileAccess().withRead(at: directory) { scope in
            try scope.checkCancellation()
            return try capture(at: scope.url)
        }
    }
    private static func files(at directory: URL) throws -> [URL] {
        guard (try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory else { throw SharedLibraryOperationError.unsafePath }
        var result: [URL] = [], pending = [directory]
        while let parent = pending.popLast() {
            for url in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                guard SharedLibraryMaterializer.contained(url, in: directory) else { throw SharedLibraryOperationError.unsafePath }
                let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular else { throw SharedLibraryOperationError.unsafePath }
                if type == .typeDirectory {
                    // An independently bound nested library has its own writers.
                    guard !FileManager.default.fileExists(atPath: url.appendingPathComponent(".docktape/format.json").path) else { throw SharedLibraryOperationError.unsafePath }
                    pending.append(url)
                }
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
    static func capture(at directory: URL) throws -> Self {
        let files = try files(at: directory)
        let rootPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var entries: [Entry] = []
        for file in files {
            try Task.checkCancellation()
            let absolute = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard absolute.hasPrefix(prefix) else { throw SharedLibraryOperationError.unsafePath }
            let path = String(absolute.dropFirst(prefix.count))
            let type = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            if type == .typeDirectory { entries.append(.init(path: path, directory: true, fingerprint: nil)); continue }
            let handle = try FileHandle(forReadingFrom: file)
            var digest = SHA256()
            do {
                while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                    try Task.checkCancellation(); digest.update(data: bytes)
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
            entries.append(.init(path: path, directory: false, fingerprint: fingerprint))
        }
        let result = Self(entries: entries.sorted { $0.path < $1.path })
        try result.validate()
        return result
    }
}

public struct SharedFolderFileOutcome: Sendable {
    public let id: UUID
    public let name: String
    public let result: SharedMaterializationResult
    public let projectionError: String?
}
