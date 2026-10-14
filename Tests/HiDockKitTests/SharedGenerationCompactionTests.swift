// © 2026 High Gain Design. All rights reserved.
import XCTest

@testable import HiDockKit

final class SharedGenerationCompactionTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private func document(_ text: String) throws -> SharedDocument {
        try SharedDocument(id: UUID(), json: JSONSerialization.data(withJSONObject: ["text": text]))
    }
    func testCertifiedClosedGenerationDoesNotResurrectOldSpeakerEdits() throws {
        var state = SharedEntityState(id: UUID(), kind: .recording)
        let first = try document("First")
        let second = try document("Second")
        try state.assignGeneration(first, component: .transcript, writer: a)
        try state.assignGenerationEdit(
            component: .transcript, generation: first.id, key: "speaker", value: .text("Sam"), writer: a)
        let stale = state
        try state.assignGeneration(second, component: .transcript, writer: a)
        let context = try SharedGenerationCompaction.proposed(for: state)
        let compacted = try state.compacting(context)
        XCTAssertEqual(compacted.fields.count, 2, "Only lifecycle and current content remain")
        let replayed = try compacted.merged(with: stale)
        XCTAssertEqual(replayed.currentDocument(for: .transcript)?.id, second.id)
        XCTAssertTrue(replayed.conflicts.isEmpty)
        XCTAssertEqual(replayed.generationEdits(for: .transcript), [:])
    }
    func testConcurrentOldGenerationEditPreventsCompactionProposal() throws {
        var initial = SharedEntityState(id: UUID(), kind: .recording)
        let first = try document("First")
        try initial.assignGeneration(first, component: .transcript, writer: a)
        var replaced = initial
        var late = initial
        try replaced.assignGeneration(document("Second"), component: .transcript, writer: a)
        try late.assignGenerationEdit(
            component: .transcript, generation: first.id, key: "speaker", value: .text("Keep my edit"), writer: b)
        let conflict = try replaced.merged(with: late)
        XCTAssertFalse(conflict.conflicts.isEmpty)
        XCTAssertThrowsError(try SharedGenerationCompaction.proposed(for: conflict))
    }
    func testRetiredNamespaceCanBeReintroducedWithoutOldCountersErasingNewLabels() throws {
        var state = SharedEntityState(id: UUID(), kind: .recording)
        let first = try document("First")
        let second = try document("Second")
        let third = try document("Third")
        try state.assignGeneration(first, component: .transcript, writer: a)
        try state.assignGenerationEdit(
            component: .transcript, generation: first.id, key: "speaker", value: .text("Old name"), writer: a)
        try state.assignGeneration(second, component: .transcript, writer: a)
        let context = try SharedGenerationCompaction.proposed(for: state)
        var compacted = try state.compacting(context)
        var oldPeer = state
        try oldPeer.assign(field: "note", value: .text("Independent offline note"), writer: b)
        try compacted.assignGeneration(first, component: .transcript, writer: a)
        try compacted.assignGenerationEdit(
            component: .transcript, generation: first.id, key: "speaker", value: .text("New name"), writer: a)
        let joined = try compacted.merged(with: oldPeer)
        XCTAssertEqual(joined.generationEdits(for: .transcript), ["speaker": .text("New name")])
        XCTAssertEqual(joined.value(for: "note"), .text("Independent offline note"))
        XCTAssertTrue(joined.conflicts.isEmpty)
        // A later observed replacement must still consume the new edit. Do not
        // discard a post-checkpoint unset merely because its namespace is old.
        var later = joined
        try later.assignGeneration(third, component: .transcript, writer: b)
        let replayed = try compacted.merged(with: later)
        XCTAssertEqual(replayed.currentDocument(for: .transcript)?.id, third.id)
        XCTAssertTrue(replayed.conflicts.isEmpty)
    }
    func testRepeatedConfirmedRegenerationBoundsMetadataAndPreservesCurrentEdits() throws {
        var state = SharedEntityState(id: UUID(), kind: .recording)
        var history: [SharedEntityState] = []
        for index in 0..<30 {
            let doc = try document("Current")
            try state.assignGeneration(doc, component: .transcript, writer: a)
            try state.assignGenerationEdit(
                component: .transcript, generation: doc.id, key: "speaker", value: .text("Name \(index)"), writer: a)
            history.append(state)
            state = try state.compacting(SharedGenerationCompaction.proposed(for: state))
            XCTAssertEqual(state.fields.count, 3)
            XCTAssertEqual(state.compaction?.context.count, 1)
        }
        for old in history.reversed() { state = try state.merged(with: old) }
        XCTAssertEqual(state.generationEdits(for: .transcript), ["speaker": .text("Name 29")])
        XCTAssertTrue(state.conflicts.isEmpty)
        XCTAssertLessThan(
            try JSONEncoder().encode(state).count, 2500, "Do not retain one namespace/payload per old generation")
    }
    func testCausalFloorRejectsOldDotsButRetainsARealLaterWrite() throws {
        var old = CausalRegister<String>()
        try old.assign("Old", by: a)
        let floored = try old.applyingCausalFloor([.init(writer: a, counter: 20)])
        XCTAssertTrue(floored.values.isEmpty)
        var fresh = floored
        try fresh.assign("New", by: a, counterAtLeast: 21)
        try fresh.merge(old)
        XCTAssertEqual(fresh.values, ["New"])
        XCTAssertThrowsError(try old.applyingCausalFloor([.init(writer: a, counter: 1), .init(writer: a, counter: 2)]))
    }
}
