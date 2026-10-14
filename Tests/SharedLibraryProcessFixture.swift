// © 2026 High Gain Design. All rights reserved.
import Foundation
import HiDockKit

@main
struct SharedLibraryProcessFixture {
    private struct Report: Encodable { let title: String?; let folder: String?; let sequence: UInt64 }
    private enum FixtureError: Error { case arguments, gateTimedOut }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5, let writer = UUID(uuidString: args[3]), let id = UUID(uuidString: args[4]) else {
            throw FixtureError.arguments
        }
        let repository = SharedLibraryRepository(root: URL(fileURLWithPath: args[2]), writerID: writer)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        if args[1] == "read" {
            let snapshot = try await repository.load(entity: entity)
            func text(_ value: SharedFieldValue?) -> String? { if case .text(let text)? = value { return text }; return nil }
            let report = Report(title: text(snapshot.state.value(for: "title")), folder: text(snapshot.state.value(for: "folder")), sequence: snapshot.ownerSequence)
            print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
            return
        }
        guard args[1] == "write", args.count == 9 else { throw FixtureError.arguments }
        let base = try await repository.load(entity: entity)
        try Data("ready".utf8).write(to: URL(fileURLWithPath: args[7]), options: .atomic)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: args[8]) {
            guard ContinuousClock.now < deadline else { throw FixtureError.gateTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        let outcome = try await repository.commit(.init(base: base, changes: [.assign(field: args[5], value: .text(args[6]))]))
        print("accepted:\(outcome.ownerSequence)")
    }
}
