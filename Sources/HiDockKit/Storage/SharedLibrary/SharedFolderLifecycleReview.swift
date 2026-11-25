// © 2026 High Gain Design. All rights reserved.
import Foundation

/// An exact root decision with retained descendant state, never file permission.
public struct SharedFolderLifecycleReview: Sendable {
    public struct Member: Sendable {
        public let path: String
        public let state: SharedEntityState
    }
    public let keep: Bool
    public let members: [Member]
    public var contextFingerprint: String { base.fingerprint + ":" + context + ":" + cohort }
    let base: SharedLibraryViewSnapshot
    let context: String
    let cohort: String
}
