// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedStoreOfflineTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: url.appendingPathComponent("Meeting.mp3"))
        return url
    }
    private func deliver(_ source: URL, _ destination: URL, writer: UUID) throws {
        let tree = source.appendingPathComponent(".docktape").resolvingSymlinksInPath()
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: tree, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let file as URL in iterator {
            guard (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else { continue }
            let bytes = try Data(contentsOf: file)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let payload = object["payload"] as? [String: Any]
            let owner = (object["writerID"] as? String) ?? (payload?["writer"] as? String) ?? (object["founder"] as? String)
            guard owner.flatMap(UUID.init(uuidString:)) == writer else { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(tree.path.count + 1))
            let target = destination.appendingPathComponent(".docktape/" + relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
    }
    func testRealRecordingAndTemplateStoresJoinIndependentOfflineEdits() async throws {
        let left = try root(), right = try root()
        let original = RecordingStore(baseDirectory: left)
        try await original.setup()
        try await original.setMeta(mode: "Rec", deviceFilename: "device.hda", for: "Meeting.mp3")
        let template = Template.makeUserTemplate(name: "Original", description: "", promptText: "Original prompt")
        try await TemplateStore(baseDirectory: left).addUserTemplate(template)
        let a = SharedLibraryCoordinator(root: left, writerID: UUID())
        _ = try await a.enable()
        let b = SharedLibraryCoordinator(root: right, writerID: UUID())
        try deliver(left, right, writer: a.writerID)
        try await b.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliver(right, left, writer: b.writerID)
        try await a.refresh()
        try deliver(left, right, writer: a.writerID)
        try await b.refresh()
        try deliver(right, left, writer: b.writerID)
        try await a.refresh()
        try deliver(left, right, writer: a.writerID)
        let recordsA = RecordingStore(baseDirectory: left, shared: SharedRecordingMetadataAdapter(coordinator: a))
        let recordsB = RecordingStore(baseDirectory: right, shared: SharedRecordingMetadataAdapter(coordinator: b))
        let templatesA = TemplateStore(baseDirectory: left, shared: SharedTemplateAdapter(coordinator: a))
        let templatesB = TemplateStore(baseDirectory: right, shared: SharedTemplateAdapter(coordinator: b))
        try await recordsA.setup(); try await recordsB.setup()
        try await templatesA.load(); try await templatesB.load()
        // Disconnected roots have independent actors and owner files.
        try await recordsA.setMeta(mode: "Mee", deviceFilename: "device.hda", for: "Meeting.mp3")
        try await recordsB.setMeta(mode: "Rec", deviceFilename: "changed.hda", for: "Meeting.mp3")
        var first = template; first.name = "Renamed"
        var second = template; second.promptText = "Changed prompt"
        try await templatesA.update(first); try await templatesB.update(second)
        try deliver(left, right, writer: a.writerID)
        try deliver(right, left, writer: b.writerID)
        try await recordsA.loadLibraryMeta(); try await recordsB.loadLibraryMeta()
        try await templatesA.load(); try await templatesB.load()
        let modeA = await recordsA.mode(for: "Meeting.mp3")
        let modeB = await recordsB.mode(for: "Meeting.mp3")
        let devicesA = await recordsA.allImportedDeviceFilenames()
        let devicesB = await recordsB.allImportedDeviceFilenames()
        XCTAssertEqual(modeA, "Mee"); XCTAssertEqual(modeB, modeA)
        XCTAssertEqual(devicesA, ["changed.hda"]); XCTAssertEqual(devicesB, devicesA)
        let joinedA = await templatesA.template(forID: template.id)
        let joinedB = await templatesB.template(forID: template.id)
        XCTAssertEqual(joinedA?.name, "Renamed"); XCTAssertEqual(joinedA?.promptText, "Changed prompt")
        XCTAssertEqual(joinedA, joinedB)
        // Divergent prompts remain competing causal values, never latest-clock wins.
        first = try XCTUnwrap(joinedA); second = try XCTUnwrap(joinedB)
        first.promptText = "Left prompt"; second.promptText = "Right prompt"
        try await templatesA.update(first); try await templatesB.update(second)
        try deliver(left, right, writer: a.writerID)
        try deliver(right, left, writer: b.writerID)
        let id = try SharedLibraryIdentity.legacy(relativePath: "template-" + template.id)
        let state = try await a.read(.init(id: id, kind: .template)).state
        XCTAssertEqual(state.conflicts.first { $0.field == "prompt" }?.values, [.text("Left prompt"), .text("Right prompt")])
    }
    func testMetadataFirstPartialMoveReservesIntermediatePathOnOtherRoot() async throws {
        let left = try root(), right = try root()
        let localA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let localB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots += [localA, localB]
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: localA)
        _ = try await a.enable(); _ = try await a.projectOutputs()
        let entity = SharedEntityIdentity(id: try await a.reference(to: "Meeting.mp3").entityID, kind: .recording)
        try deliver(left, right, writer: a.writerID)
        try Data(contentsOf: left.appendingPathComponent("library.json")).write(to: right.appendingPathComponent("library.json"), options: .atomic)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: localB)
        try await b.requestEnrollment(requestID: UUID(), label: "Other Mac")
        for _ in 0..<3 {
            try deliver(right, left, writer: b.writerID); try await a.refresh()
            try deliver(left, right, writer: a.writerID); try await b.refresh()
        }
        enum Stop: Error { case afterAudio }
        do { _ = try await a.relocateRecording(filename: "Meeting.mp3", title: "Intermediate", afterMutation: { _ in throw Stop.afterAudio }); XCTFail() }
        catch Stop.afterAudio {}
        _ = try await a.edit(.init(base: try await a.read(entity), changes: [.assign(field: "title", value: .text("Final"))]))
        try deliver(left, right, writer: a.writerID) // No physical move on B yet.
        let permission = try await b.operationAuthority(entity: entity, paths: ["Intermediate.mp3", "Meeting.mp3", "Final.mp3"])
        XCTAssertEqual(permission.pathOwners["Intermediate.mp3"], [entity.id])
        let store = RecordingStore(baseDirectory: right, shared: SharedRecordingMetadataAdapter(coordinator: b))
        try await store.setup()
        let data = Data([0xFF, 0xFB, 0x90, 0x64, 1, 2, 3, 4])
        do { _ = try await store.importRecording(hdaData: data, entry: FileEntry(filename: "Intermediate.hda", size: UInt32(data.count))); XCTFail("Metadata delivery must reserve the late physical path before another import claims it") }
        catch SharedLibraryOperationError.pathConflict(let path) { XCTAssertEqual(path, "Intermediate.mp3") }
        XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("Meeting.mp3")), Data("synthetic".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("Intermediate.mp3").path))
    }

}
