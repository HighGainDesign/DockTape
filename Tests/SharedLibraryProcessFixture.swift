import Darwin
// © 2026 High Gain Design. All rights reserved.
import Foundation
import HiDockKit

@main
struct SharedLibraryProcessFixture {
  private struct Report: Encodable {
    let title: String?
    let folder: String?
    let sequence: UInt64
  }
  private enum FixtureError: Error { case arguments, gateTimedOut }

  static func main() async throws {
    let args = CommandLine.arguments
    guard args.count >= 5, let writer = UUID(uuidString: args[3]),
      let id = UUID(uuidString: args[4])
    else {
      throw FixtureError.arguments
    }
    if args[1].hasPrefix("accept-") {
      guard args.count == 6 else { throw FixtureError.arguments }
      let root = URL(fileURLWithPath: args[2]), local = URL(fileURLWithPath: args[5])
      let coordinator = SharedLibraryCoordinator(root: root, writerID: writer, witnessDirectory: local,
        afterCommit: { if args[1].hasSuffix("-crash") { Darwin._exit(74) } })
      if args[1] == "accept-seed" {
        _ = try await coordinator.enable()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Accepted.mp3").path) {
          let base = try await coordinator.recording(at: "Accepted.mp3")
          let fingerprint = SharedLibraryOperation.fingerprint(try Data(contentsOf: root.appendingPathComponent("Accepted.mp3")))
          _ = try await coordinator.edit(.init(base: base, changes: [.assign(field: "audioFingerprint", value: .text(fingerprint)), .assign(field: "audioPublished", value: .text(fingerprint))]))
        }
        _ = try await coordinator.projectOutputs()
        print("seeded"); return
      }
      if args[1] == "accept-resume" {
        let accepted = try await coordinator.recording(at: "Accepted.mp3")
        let result = try await coordinator.resumeRecordingOperation(id: accepted.state.id)
        print(result.result == .complete ? "complete" : "pending"); return
      }
      let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
      try await store.setup()
      if args[1] == "accept-import-crash" {
        var bytes = Data(repeating: 3, count: 417)
        bytes.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0x64])
        _ = try await store.importRecording(hdaData: bytes, entry: FileEntry(filename: "Accepted.hda", size: UInt32(bytes.count)))
      } else if args[1] == "accept-merge-crash" {
        _ = try await store.mergeRecordings(filenames: ["One.mp3", "Two.mp3"], as: "Accepted")
      } else { throw FixtureError.arguments }
      throw FixtureError.arguments
    }
    if args[1].hasPrefix("job-") {
      guard args.count >= 6 else { throw FixtureError.arguments }
      let root = URL(fileURLWithPath: args[2]), local = URL(fileURLWithPath: args[5])
      let coordinator = SharedLibraryCoordinator(root: root, writerID: writer, witnessDirectory: local, trash: { source in
        let disposal = root.deletingLastPathComponent().appendingPathComponent("disposed")
        try FileManager.default.createDirectory(at: disposal, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: disposal.appendingPathComponent(source.lastPathComponent))
      })
      if args[1] == "job-seed" {
        let manifest = try await coordinator.enable()
        _ = try await coordinator.projectOutputs()
        print(manifest.references.first { $0.entity.kind == .recording }!.entity.id.uuidString)
        return
      }
      let entity = SharedEntityIdentity(id: id, kind: .recording)
      if args[1] == "job-hold" {
        guard args.count == 8 else { throw FixtureError.arguments }
        let token = try await coordinator.pinJob(entity)
        try Data("ready".utf8).write(to: URL(fileURLWithPath: args[6]), options: .atomic)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !FileManager.default.fileExists(atPath: args[7]) {
          guard ContinuousClock.now < deadline else { throw FixtureError.gateTimedOut }
          try await Task.sleep(for: .milliseconds(10))
        }
        await coordinator.finishJob(token)
        print("released"); return
      }
      if args[1] == "job-delete" {
        let result = try await coordinator.deleteSharedRecording(filename: "Meeting.mp3")
        print(result.result == .complete ? "complete" : "waiting"); return
      }
      if args[1] == "job-resume" {
        let result = try await coordinator.resumeRecordingOperation(id: id)
        print(result.result == .complete ? "complete" : "waiting"); return
      }
      if args[1] == "job-probe" {
        let value = try await coordinator.operationAuthority(entity: entity, paths: ["Meeting.mp3"])
        print(value.hasPendingWork ? "active" : "idle"); return
      }
      throw FixtureError.arguments
    }
    let repository = SharedLibraryRepository(root: URL(fileURLWithPath: args[2]), writerID: writer)
    let entity = SharedEntityIdentity(id: id, kind: .recording)
    if args[1] == "seed-move" {
      let base = try await repository.load(entity: entity)
      _ = try await repository.commit(
        .init(
          base: base,
          changes: [
            .assign(field: "title", value: .text("destination")),
            .assign(
              field: "audioFingerprint",
              value: .text(SharedLibraryOperation.fingerprint(Data("Synthetic process audio".utf8)))
            ),
          ]))
      return
    }
    if args[1] == "move" || args[1] == "move-crash" {
      guard args.count == 8 else { throw FixtureError.arguments }
      let root = URL(fileURLWithPath: args[2])
      let receipts = URL(fileURLWithPath: args[5])
      let snapshot = try await repository.load(entity: entity)
      let library = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
      let operation = try SharedLibraryOperation(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
        libraryID: library, entity: entity, inputRevision: "before-move",
        outputRevision: SharedStateFingerprint.of(snapshot.state),
        steps: [
          .move(
            source: "source.mp3", destination: "destination.mp3",
            fingerprint: SharedLibraryOperation.fingerprint(Data("Synthetic process audio".utf8)))
        ])
      let materializer = SharedLibraryMaterializer(
        root: root, receipts: receipts,
        authority: {
          let current = try await repository.load(entity: entity)
          return .init(
            libraryID: library, state: current.state,
            membership: .init(libraryID: library, founder: writer, bootstrapFingerprint: "fixture"),
            acknowledgments: [], hasPendingWork: false,
            pathOwners: ["source.mp3": [id], "destination.mp3": [id]])
        },
        afterMutation: { _ in
          let marker = receipts.appendingPathComponent("mutation-count")
          var content = (try? Data(contentsOf: marker)) ?? Data()
          content.append(Data("mutation\n".utf8))
          try content.write(to: marker, options: .atomic)
          if args[1] == "move-crash" { exit(73) }
        })
      try Data("ready".utf8).write(to: URL(fileURLWithPath: args[6]), options: .atomic)
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while !FileManager.default.fileExists(atPath: args[7]) {
        guard ContinuousClock.now < deadline else { throw FixtureError.gateTimedOut }
        try await Task.sleep(for: .milliseconds(10))
      }
      guard try await materializer.replay(operation) == .complete else {
        throw FixtureError.arguments
      }
      print("complete")
      return
    }
    if args[1] == "read" {
      let snapshot = try await repository.load(entity: entity)
      func text(_ value: SharedFieldValue?) -> String? {
        if case .text(let text)? = value { return text }
        return nil
      }
      let report = Report(
        title: text(snapshot.state.value(for: "title")),
        folder: text(snapshot.state.value(for: "folder")), sequence: snapshot.ownerSequence)
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
    let outcome = try await repository.commit(
      .init(base: base, changes: [.assign(field: args[5], value: .text(args[6]))]))
    print("accepted:\(outcome.ownerSequence)")
  }
}
