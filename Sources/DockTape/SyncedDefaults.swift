// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Mirrors selected UserDefaults keys to NSUbiquitousKeyValueStore for iCloud sync.
/// Views use @AppStorage (UserDefaults) as usual. This class keeps them in sync with iCloud.
@MainActor
final class SyncedDefaults {
    static let shared = SyncedDefaults()

    /// Keys that sync across devices. Machine-specific keys (libraryLocation, bookmarks) stay local.
    static let syncedKeys: Set<String> = [
        "storageMode",
        "aiProvider",
        "aiModel",
        "aiCustomBaseURL",
        "aiCustomModel",
        "autoSummarize",
        "autoSummarizeTemplate",
        "autoDeleteAfterDownload",
        "autoSyncClock",
        "librarySortBy",
        "libraryFilterMode",
        "libraryFilterPeriod",
    ]

    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard

    private init() {}

    /// Call once at app launch. Pulls remote values and starts listening for changes.
    func start() {
        // Pull any remote values that exist
        cloud.synchronize()

        // Seed local defaults from cloud for keys that don't exist locally yet
        for key in Self.syncedKeys {
            if local.object(forKey: key) == nil, let remote = cloud.object(forKey: key) {
                local.set(remote, forKey: key)
            }
        }

        // Push local values to cloud (in case this is the first device)
        for key in Self.syncedKeys {
            if let value = local.object(forKey: key) {
                cloud.set(value, forKey: key)
            }
        }

        // Listen for remote changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud
        )

        // Listen for local changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: local
        )
    }

    @objc private func cloudDidChange(_ notification: Notification) {
        guard let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }

        for key in changedKeys where Self.syncedKeys.contains(key) {
            if let value = cloud.object(forKey: key) {
                local.set(value, forKey: key)
            }
        }
    }

    /// Track which keys we're currently writing to avoid echo loops.
    private var isUpdatingCloud = false

    @objc private func localDidChange(_ notification: Notification) {
        guard !isUpdatingCloud else { return }
        isUpdatingCloud = true
        defer { isUpdatingCloud = false }

        for key in Self.syncedKeys {
            if let value = local.object(forKey: key) {
                cloud.set(value, forKey: key)
            }
        }
    }
}
