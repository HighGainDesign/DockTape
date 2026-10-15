// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Recordings in iCloud storage can have the Finder hidden flag. Filter dot-files
/// ourselves instead of using skipsHiddenFiles, which also hides canonical audio.
/// File Provider online-only items keep ordinary filenames and remain in this
/// metadata-only listing; actual content preparation belongs to RecordingFileAccess.
enum LibraryFileDiscovery {
    struct File {
        let url: URL
        let relativePath: String
        let logicalName: String
        /// Only the iCloud dot-name stub; never use this flag to call iCloud
        /// download APIs for ordinary File Provider filenames.
        let isPlaceholder: Bool
    }

    /// Metadata-only folder discovery. Errors are not an empty library; symlink
    /// children and private control directories are never traversed.
    static func directories(in directory: URL) async throws -> [String] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let task = Task.detached { () throws -> [String] in
            let fm = FileManager.default
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            var pending = [root], result: Set<String> = []
            while let parent = pending.popLast() {
                try Task.checkCancellation()
                for url in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) {
                    guard !url.lastPathComponent.hasPrefix(".") else { continue }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    let path = url.standardizedFileURL.path
                    guard path.hasPrefix(prefix) else { throw SharedLibraryOperationError.unsafePath }
                    result.insert(try SharedLibraryIdentity.normalized(String(path.dropFirst(prefix.count))))
                    pending.append(url)
                }
            }
            return result.sorted()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func files(in directory: URL, relativeTo base: URL? = nil, suffix: String) -> [File] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [])
        else { return [] }
        let basePath = (base ?? directory).resolvingSymlinksInPath().path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        var result: [File] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            let placeholder = name.hasPrefix(".") && name.hasSuffix(".icloud")
            let logicalName = placeholder ? String(name.dropFirst().dropLast(7)) : name
            guard !logicalName.hasPrefix("."),
                !name.hasPrefix(".") || placeholder,
                logicalName.lowercased().hasSuffix(suffix.lowercased())
            else { continue }
            let path = url.resolvingSymlinksInPath().path
            let sourceRelative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : name
            let folder = (sourceRelative as NSString).deletingLastPathComponent
            let relativePath = folder.isEmpty || folder == "." ? logicalName : "\(folder)/\(logicalName)"
            result.append(
                File(
                    url: url, relativePath: relativePath,
                    logicalName: logicalName, isPlaceholder: placeholder))
        }
        return result
    }
}
