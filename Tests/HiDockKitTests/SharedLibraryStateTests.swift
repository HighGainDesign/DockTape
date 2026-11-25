// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedLibraryStateTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let recording = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let oldGeneration = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let newGeneration = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    func testLegacyIdentityUsesRelativePathRatherThanBasenameOrMacRoot() throws {
        let first = try SharedLibraryIdentity.legacy(relativePath: "One/Meeting.mp3")
        let second = try SharedLibraryIdentity.legacy(relativePath: "Two/Meeting.mp3")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, try SharedLibraryIdentity.legacy(relativePath: "One/Meeting.mp3"))
        XCTAssertEqual(try SharedLibraryIdentity.legacy(relativePath: "Café.mp3"),
                       try SharedLibraryIdentity.legacy(relativePath: "Cafe\u{301}.mp3"))
    }

    func testIdentityRejectsPathsEscapingTheLibrary() {
        for path in ["", "/Meeting.mp3", "../Meeting.mp3", "One/../Meeting.mp3",
                     "One/./Meeting.mp3", "One//Meeting.mp3", "One/", ".docktape/state.json", "bad\0name.mp3"] {
            XCTAssertThrowsError(try SharedLibraryIdentity.legacy(relativePath: path), path)
        }
    }

    func testVerifiedDeviceSourceClaimsAgreeWithoutCollapsingOtherSources() throws {
        let one = try SharedLibraryIdentity.deviceImport(filename: "REC_20261013_120000.hda",
                                                         sourceMD5: "1234567890abcdef1234567890abcdef")
        let repeated = try SharedLibraryIdentity.deviceImport(filename: "REC_20261013_120000.hda",
                                                              sourceMD5: "1234567890ABCDEF1234567890ABCDEF")
        let different = try SharedLibraryIdentity.deviceImport(filename: "REC_20261013_130000.hda",
                                                               sourceMD5: "1234567890abcdef1234567890abcdef")
        XCTAssertEqual(one, repeated)
        XCTAssertNotEqual(one, different)
        XCTAssertThrowsError(try SharedLibraryIdentity.deviceImport(filename: "REC.hda", sourceMD5: String(repeating: "0", count: 32)))
        XCTAssertThrowsError(try SharedLibraryIdentity.deviceImport(filename: "REC.hda", sourceMD5: "unproven"))
    }

    func testIndependentMetadataChangesSurviveBothWriters() throws {
        var left = SharedEntityState(id: recording, kind: .recording)
        var right = left
        try left.assign(field: "title", value: .text("Launch"), writer: a)
        try right.assign(field: "folder", value: .text("Calls"), writer: b)
        let joined = try left.merged(with: right)
        XCTAssertEqual(joined.value(for: "title"), .text("Launch"))
        XCTAssertEqual(joined.value(for: "folder"), .text("Calls"))
        XCTAssertEqual(joined.lifecycle, .alive)
        XCTAssertTrue(joined.conflicts.isEmpty)
        XCTAssertEqual(joined.id, recording)
    }

    func testCompetingMetadataDoesNotPickTheLastArrival() throws {
        var left = SharedEntityState(id: recording, kind: .recording)
        var right = left
        try left.assign(field: "title", value: .text("One"), writer: a)
        try right.assign(field: "title", value: .text("Two"), writer: b)
        let joined = try left.merged(with: right)
        XCTAssertNil(joined.value(for: "title"))
        XCTAssertEqual(joined.conflicts.count, 1)
        XCTAssertEqual(joined, try right.merged(with: left))
    }

    func testDeleteVersusEditRetainsTheEditAndNeedsExplicitResolution() throws {
        var base = SharedEntityState(id: recording, kind: .recording)
        try base.assign(field: "title", value: .text("Original"), writer: a)
        var deleting = base
        var editing = base
        try deleting.delete(writer: a)
        try editing.assign(field: "title", value: .text("Changed offline"), writer: b)
        var joined = try deleting.merged(with: editing)
        XCTAssertEqual(joined.lifecycle, .conflicted)
        XCTAssertEqual(joined.value(for: "title"), .text("Changed offline"))
        let before = joined
        XCTAssertThrowsError(try joined.assign(field: "folder", value: .text("Moved"), writer: a))
        XCTAssertEqual(joined, before)
        try joined.restore(writer: a)
        XCTAssertEqual(joined.lifecycle, .alive)
        XCTAssertEqual(joined.value(for: "title"), .text("Changed offline"))
        let stale = deleting
        joined = try joined.merged(with: stale)
        XCTAssertEqual(joined.lifecycle, .alive)
    }

    func testOrdinaryEditCannotResurrectAConfirmedDeletion() throws {
        var state = SharedEntityState(id: recording, kind: .recording)
        try state.assign(field: "title", value: .text("Kept metadata"), writer: a)
        try state.delete(writer: a)
        let before = state
        XCTAssertThrowsError(try state.assign(field: "title", value: .text("Silent restore"), writer: b))
        XCTAssertEqual(state, before)
        XCTAssertEqual(state.lifecycle, .deleted)
    }

    func testEntityAndKindMismatchAreRejected() throws {
        let state = SharedEntityState(id: recording, kind: .recording)
        XCTAssertThrowsError(try state.merged(with: SharedEntityState(id: a, kind: .recording)))
        XCTAssertThrowsError(try state.merged(with: SharedEntityState(id: recording, kind: .template)))
    }

    func testDocumentCanonicalizationAvoidsWhitespaceOnlyConflicts() throws {
        let first = try SharedDocument(id: oldGeneration, json: Data("{\"b\":\"two\", \"a\":1}".utf8))
        let second = try SharedDocument(id: oldGeneration, json: Data("{\n\"a\":1,\"b\":\"two\"\n}".utf8))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.json, Data("{\"a\":1,\"b\":\"two\"}".utf8))
        XCTAssertThrowsError(try SharedDocument(id: oldGeneration, json: Data("not JSON".utf8)))
    }

    func testConcurrentGenerationsCannotPairOneContentWithAnotherIdentity() throws {
        let alpha = try SharedDocument(id: oldGeneration, json: Data("{\"text\":\"alpha\"}".utf8))
        let beta = try SharedDocument(id: newGeneration, json: Data("{\"text\":\"beta\"}".utf8))
        var left = SharedEntityState(id: recording, kind: .recording)
        var right = left
        try left.assignGeneration(alpha, component: .transcript, writer: a)
        try right.assignGeneration(beta, component: .transcript, writer: b)
        let joined = try left.merged(with: right)
        XCTAssertEqual(joined.generationValues(for: .transcript), [alpha, beta])
        XCTAssertNil(joined.currentDocument(for: .transcript))
        XCTAssertFalse(joined.conflicts.isEmpty)
    }

    func testSelectingContentClearsObservedCompetingFileApprovals() throws {
        let alpha = try SharedDocument(id: oldGeneration, json: Data("{\"text\":\"alpha\"}".utf8))
        let beta = try SharedDocument(id: newGeneration, json: Data("{\"text\":\"beta\"}".utf8))
        var left = SharedEntityState(id: recording, kind: .recording)
        var right = left
        try left.assignGeneration(alpha, component: .transcript, writer: a)
        try right.assignGeneration(beta, component: .transcript, writer: b)
        for (writer, document, hash) in [(a, alpha, "alpha-hash"), (b, beta, "beta-hash")] {
            if writer == a {
                try left.assign(field: "externalAdoption.transcript", value: .text(hash), writer: writer)
                try left.assign(field: "externalAdoptionGeneration.transcript", value: .text(document.id.uuidString.lowercased()), writer: writer)
            } else {
                try right.assign(field: "externalAdoption.transcript", value: .text(hash), writer: writer)
                try right.assign(field: "externalAdoptionGeneration.transcript", value: .text(document.id.uuidString.lowercased()), writer: writer)
            }
        }
        var joined = try left.merged(with: right)
        XCTAssertEqual(joined.conflicts.count, 3)
        let stale = joined
        try joined.assignGeneration(alpha, component: .transcript, writer: a)
        joined = try joined.merged(with: stale)
        XCTAssertEqual(joined.currentDocument(for: .transcript), alpha)
        XCTAssertNil(joined.value(for: "externalAdoption.transcript"))
        XCTAssertNil(joined.value(for: "externalAdoptionGeneration.transcript"))
        XCTAssertTrue(joined.conflicts.isEmpty, "Content selection must also resolve its observed obsolete file approvals")
    }

    func testIndependentActionItemsCombineWithinTheSameGeneration() throws {
        let document = try SharedDocument(id: oldGeneration, json: Data("{\"sections\":[]}".utf8))
        var base = SharedEntityState(id: recording, kind: .recording)
        try base.assignGeneration(document, component: .summary, writer: a)
        var left = base
        var right = base
        try left.assignGenerationEdit(component: .summary, generation: oldGeneration, key: "item-one", value: .flag(true), writer: a)
        try right.assignGenerationEdit(component: .summary, generation: oldGeneration, key: "item-two", value: .flag(true), writer: b)
        let joined = try left.merged(with: right)
        XCTAssertEqual(joined.generationEdits(for: .summary), ["item-one": .flag(true), "item-two": .flag(true)])
        XCTAssertTrue(joined.conflicts.isEmpty)
    }

    func testConcurrentOldGenerationEditNeverAttachesToReplacementContent() throws {
        let old = try SharedDocument(id: oldGeneration, json: Data("{\"text\":\"old\"}".utf8))
        let new = try SharedDocument(id: newGeneration, json: Data("{\"text\":\"new\"}".utf8))
        var base = SharedEntityState(id: recording, kind: .recording)
        try base.assignGeneration(old, component: .transcript, writer: a)
        var editing = base
        var replacing = base
        try editing.assignGenerationEdit(component: .transcript, generation: oldGeneration, key: "speaker-one", value: .text("Ada"), writer: a)
        try replacing.assignGeneration(new, component: .transcript, writer: b)
        let joined = try editing.merged(with: replacing)
        XCTAssertEqual(joined.currentDocument(for: .transcript), new)
        XCTAssertTrue(joined.generationEdits(for: .transcript).isEmpty)
        XCTAssertFalse(joined.conflicts.isEmpty, "Old generation edits must remain actionable rather than be lost or misapplied")
    }

    func testObservedGenerationEditsAreSupersededWithoutStaleResurrection() throws {
        let old = try SharedDocument(id: oldGeneration, json: Data("{\"text\":\"old\"}".utf8))
        let new = try SharedDocument(id: newGeneration, json: Data("{\"text\":\"new\"}".utf8))
        var state = SharedEntityState(id: recording, kind: .recording)
        try state.assignGeneration(old, component: .transcript, writer: a)
        try state.assignGenerationEdit(component: .transcript, generation: oldGeneration, key: "speaker-one", value: .text("Ada"), writer: a)
        let stale = state
        try state.assignGeneration(new, component: .transcript, writer: b)
        state = try state.merged(with: stale)
        XCTAssertEqual(state.currentDocument(for: .transcript), new)
        XCTAssertTrue(state.generationEdits(for: .transcript).isEmpty)
        XCTAssertTrue(state.conflicts.isEmpty)
    }

    func testLateGenerationEditIsRejectedWithoutPartialMutation() throws {
        let document = try SharedDocument(id: newGeneration, json: Data("{\"text\":\"new\"}".utf8))
        var state = SharedEntityState(id: recording, kind: .recording)
        try state.assignGeneration(document, component: .transcript, writer: a)
        let before = state
        XCTAssertThrowsError(try state.assignGenerationEdit(component: .transcript, generation: oldGeneration,
                                                            key: "speaker-one", value: .text("Ada"), writer: b))
        XCTAssertEqual(state, before)
    }

    func testGenerationIdentityCannotBeReusedForDifferentContent() throws {
        let first = try SharedDocument(id: oldGeneration, json: Data("{\"text\":\"one\"}".utf8))
        let forged = try SharedDocument(id: oldGeneration, json: Data("{\"text\":\"two\"}".utf8))
        var left = SharedEntityState(id: recording, kind: .recording)
        var right = left
        try left.assignGeneration(first, component: .transcript, writer: a)
        try right.assignGeneration(forged, component: .transcript, writer: b)
        XCTAssertThrowsError(try left.merged(with: right))
        let before = left
        XCTAssertThrowsError(try left.assignGeneration(forged, component: .transcript, writer: a))
        XCTAssertEqual(left, before)
    }

    func testGenerationEditsRejectWrongSemanticTypes() throws {
        let document = try SharedDocument(id: oldGeneration, json: Data("{\"sections\":[]}".utf8))
        var state = SharedEntityState(id: recording, kind: .recording)
        try state.assignGeneration(document, component: .summary, writer: a)
        let before = state
        XCTAssertThrowsError(try state.assignGenerationEdit(component: .summary, generation: oldGeneration,
                                                            key: "item", value: .text("not a checkbox"), writer: b))
        XCTAssertEqual(state, before)
    }

    func testDecoderRejectsAUserEditWithoutItsLifecycleCommit() throws {
        var state = SharedEntityState(id: recording, kind: .recording)
        try state.assign(field: "title", value: .text("Changed"), writer: a)
        let bytes = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var fields = try XCTUnwrap(object["fields"] as? [String: Any])
        fields.removeValue(forKey: "$lifecycle")
        object["fields"] = fields
        let incomplete = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(SharedEntityState.self, from: incomplete))
    }

    func testRenameChangesLocationWithoutChangingRecordingIdentity() throws {
        var state = SharedEntityState(id: recording, kind: .recording)
        try state.assign(field: "title", value: .text("Old"), writer: a)
        try state.assign(field: "title", value: .text("New"), writer: a)
        XCTAssertEqual(state.id, recording)
        XCTAssertEqual(state.value(for: "title"), .text("New"))
        let bytes = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(SharedEntityState.self, from: bytes), state)
    }
}
