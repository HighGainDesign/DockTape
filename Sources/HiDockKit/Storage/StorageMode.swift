// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Where DockTape stores recordings, transcripts, summaries, and templates.
public enum StorageMode: String, CaseIterable, Sendable {
    case icloud = "icloud"
    case local = "local"
    case custom = "custom"
}

/// Resolves the base directory URL for a given storage mode.
public enum StorageLocationResolver {

    /// The iCloud ubiquity container identifier.
    public static let containerID = "iCloud.design.highgain.docktape"

    /// Resolve the storage base directory.
    public static func resolve(mode: StorageMode, customURL: URL?) -> URL {
        switch mode {
        case .icloud:
            if let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) {
                return container.appendingPathComponent("Documents")
            }
            return localDefault

        case .local:
            return localDefault

        case .custom:
            return customURL ?? localDefault
        }
    }

    /// Whether the iCloud ubiquity container is currently available.
    public static var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID) != nil
    }

    /// The local default path: ~/Documents/HiDock Recordings/
    public static var localDefault: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("HiDock Recordings")
    }

    /// Determine the initial storage mode for a pre-iCloud install.
    ///
    /// - Custom path set → `.custom`
    /// - Default path has recordings → `.local` (don't orphan existing files)
    /// - Fresh install → `.icloud`
    public static func migratedMode(from defaults: UserDefaults) -> StorageMode {
        if defaults.url(forKey: "libraryLocation") != nil {
            return .custom
        }
        // If the default local directory already has recordings, keep using it
        let defaultDir = localDefault
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: defaultDir.path),
           contents.contains(where: { $0.hasSuffix(".mp3") }) {
            return .local
        }
        return .icloud
    }
}
