// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Same-Mac processes share this local coordinated item. It holds no library
/// data and is not a provider/distributed lock. Reads and file hydration do not
/// acquire it; owner commits and synchronous physical phases acquire it with
/// their related files, preventing accepted local edits crossing a commit point.
public struct SharedLibraryLocalGate: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file.standardizedFileURL.resolvingSymlinksInPath() }
    func items(outside root: URL) throws -> [CoordinatedFileAccess.WriteItem] {
        guard file.resolvingSymlinksInPath() != root.resolvingSymlinksInPath(),
              !SharedLibraryMaterializer.contained(file.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath()) else {
            throw SharedLibraryOperationError.unsafePath
        }
        return [.init(file, mode: .replacing)]
    }
    func validate(_ scope: CoordinatedFileAccess.Scope, outside root: URL) throws {
        _ = try items(outside: root)
        // A missing /private/tmp path can resolve to /tmp after creation.
        // Compare both current canonical paths while refusing a replaced gate.
        let attributes = try FileManager.default.attributesOfItem(atPath: scope.url.path)
        let expected = try FileManager.default.attributesOfItem(atPath: file.path)
        guard scope.url.standardizedFileURL.resolvingSymlinksInPath() == file.resolvingSymlinksInPath(),
              expected[.type] as? FileAttributeType == .typeRegular,
              (expected[.size] as? NSNumber)?.intValue == 0,
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == 0 else {
            throw SharedLibraryOperationError.unsafePath
        }
    }
    func prepare(outside root: URL) async throws {
        _ = try items(outside: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var directory = file.deletingLastPathComponent()
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        try directory.setResourceValues(excluded)
        let file = self.file
        try await CoordinatedFileAccess().withWrite(at: file) { scope in
            guard scope.url.standardizedFileURL.resolvingSymlinksInPath() == file else {
                throw SharedLibraryOperationError.unsafePath
            }
            if FileManager.default.fileExists(atPath: scope.url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: scope.url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue == 0 else {
                    throw SharedLibraryOperationError.unsafePath
                }
            } else {
                try scope.checkCancellation()
                try Data().write(to: scope.url, options: .atomic)
            }
            var current = scope.url
            var fileExcluded = URLResourceValues(); fileExcluded.isExcludedFromBackup = true
            try current.setResourceValues(fileExcluded)
        }
    }
}
