// © 2026 High Gain Design. All rights reserved.
import Foundation
import HiDockKit

enum CLIUsageError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
struct CLIInvocation {
    let arguments: [String]
    let root: URL
    init(arguments: [String]) throws {
        var remaining = arguments
        var selected: URL?
        while let index = remaining.firstIndex(of: "--library") {
            guard selected == nil, index + 1 < remaining.count, !remaining[index + 1].hasPrefix("--"), !remaining[index + 1].isEmpty else {
                throw CLIUsageError.message("Specify --library PATH exactly once.")
            }
            selected = URL(fileURLWithPath: (remaining[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
            remaining.removeSubrange(index...index + 1)
        }
        self.arguments = remaining
        self.root = (selected ?? StorageLocationResolver.localDefault).standardizedFileURL.resolvingSymlinksInPath()
    }
    static func removingFlag(_ flag: String, from arguments: [String]) -> [String] {
        var remaining = arguments
        if let index = remaining.firstIndex(of: flag) {
            remaining.removeSubrange(index...min(index + 1, remaining.count - 1))
        }
        return remaining
    }
}
