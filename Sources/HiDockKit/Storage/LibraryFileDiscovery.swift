// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Recordings in iCloud storage can have the Finder hidden flag. Filter dot-files
/// ourselves instead of using skipsHiddenFiles, which also hides canonical audio.
enum LibraryFileDiscovery {
    struct File {
        let url: URL
        let relativePath: String
        let logicalName: String
        let isPlaceholder: Bool
    }

    static func files(in directory: URL, relativeTo base: URL? = nil, suffix: String) -> [File] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []) else { return [] }
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
                  (!name.hasPrefix(".") || placeholder),
                  logicalName.lowercased().hasSuffix(suffix.lowercased()) else { continue }
            let path = url.resolvingSymlinksInPath().path
            let sourceRelative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : name
            let folder = (sourceRelative as NSString).deletingLastPathComponent
            let relativePath = folder.isEmpty || folder == "." ? logicalName : "\(folder)/\(logicalName)"
            result.append(File(url: url, relativePath: relativePath,
                               logicalName: logicalName, isPlaceholder: placeholder))
        }
        return result
    }
}
