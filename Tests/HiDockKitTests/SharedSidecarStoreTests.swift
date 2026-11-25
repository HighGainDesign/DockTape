// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedSidecarStoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let transcript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
                                    segments: [.init(startTime: 0, endTime: 1, text: "Test", speakerID: "A")],
                                    speakerNames: ["A": "Alice", "B": "Bob"])
        try await TranscriptStore(baseDirectory: root).save(transcript, mp3Filename: "Meeting.mp3")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID())
        _ = try await coordinator.enable()
        return (root, coordinator)
    }
    func testRenamedResidentSidecarsUseSelectedIdentityDespiteUnrelatedNameConflict() async throws {
        let fm = FileManager.default
        let p = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(p)
        try fm.createDirectory(at: p, withIntermediateDirectories: true)
        let left = p.appendingPathComponent("left"), right = p.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        for name in ["A.mp3", "B.mp3"] {
            try Data(("Synthetic " + name).utf8).write(to: left.appendingPathComponent(name))
        }
        try await TranscriptStore(baseDirectory: left).save(Transcript(recordingFilename: "B.mp3", transcriptionModel: "fixture",
            hasSpeakerLabels: false, segments: [.init(startTime: 0, endTime: 1, text: "Resident healthy B")]), mp3Filename: "B.mp3")
        try await SummaryStore(baseDirectory: left).save(Summary(recordingFilename: "B.mp3", model: "fixture", provider: "fixture",
            templateUsed: "fixture", sections: [.init(heading: "Summary", content: "Resident healthy summary",
                items: [.init(text: "Synthetic action")])]), mp3Filename: "B.mp3")
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: p.appendingPathComponent("a-local"))
        _ = try await a.enable(); _ = try await a.projectOutputs()
        let aid = try await a.reference(to: "A.mp3").entityID, bid = try await a.reference(to: "B.mp3").entityID
        let rename = try await a.relocateRecording(filename: "B.mp3", title: "Healthy")
        guard rename.result == .complete else { throw SharedLibraryOperationError.unfinishedOperation }
        try fm.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: p.appendingPathComponent("b-local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Isolation peer")
        for _ in 0..<3 {
            try deliverOwned(right, left, writer: b.writerID); try await a.refresh()
            try deliverOwned(left, right, writer: a.writerID); try await b.refresh()
        }
        let ae = SharedEntityIdentity(id: aid, kind: .recording), be = SharedEntityIdentity(id: bid, kind: .recording)
        _ = try await a.edit(.init(base: try await a.read(ae), changes: [.assign(field: "title", value: .text("Left title"))]))
        _ = try await b.edit(.init(base: try await b.read(ae), changes: [.assign(field: "title", value: .text("Right title"))]))
        try deliverOwned(right, left, writer: b.writerID)
        let unrelated = try await a.read(ae), healthy = try await a.read(be)
        XCTAssertFalse(unrelated.state.conflicts.isEmpty)
        XCTAssertNotNil(healthy.state.currentDocument(for: .transcript))
        let reference = SharedRecordingReference(libraryID: healthy.libraryID, entityID: bid)
        let transcripts = TranscriptStore(baseDirectory: left, shared: SharedSidecarAdapter(coordinator: a))
        let summaries = SummaryStore(baseDirectory: left, shared: SharedSidecarAdapter(coordinator: a))
        let records = RecordingStore(baseDirectory: left, shared: SharedRecordingMetadataAdapter(coordinator: a))
        try await records.setup()
        let head = left.appendingPathComponent(".docktape/records/" + aid.uuidString.lowercased() + "/" + a.writerID.uuidString.lowercased() + ".json")
        let held = expectation(description: "Unrelated conflicted head held"), ready = expectation(description: "Selected resident content completed before unrelated release")
        let release = DispatchSemaphore(value: 0)
        let holder = Task {
            try await CoordinatedFileAccess().withWrite(at: head) { _ in
                held.fulfill(); _ = release.wait(timeout: .now() + 8)
            }
        }
        await fulfillment(of: [held], timeout: 1)
        let reading = Task {
            try await transcripts.loadAll(from: records); try await summaries.loadAll(from: records)
            let transcript = try await transcripts.loadTranscript(for: "Healthy.mp3", reference: reference)
            let summary = try await summaries.loadSummary(for: "Healthy.mp3", reference: reference)
            try await transcripts.updateSpeakerNames(for: "Healthy.mp3", names: ["speaker": "Synthetic name"])
            try await summaries.toggleItem(XCTUnwrap(summary?.sections.first?.items?.first?.id), inSummaryFor: "Healthy.mp3")
            try await records.setMeta(mode: "Pho", deviceFilename: "synthetic-B.hda", for: "Healthy.mp3")
            ready.fulfill()
            return (transcript, summary)
        }
        await fulfillment(of: [ready], timeout: 2)
        release.signal(); try await holder.value
        let (transcript, summary) = try await reading.value
        let edited = try await transcripts.loadTranscript(for: "Healthy.mp3", reference: reference)
        let completed = try await summaries.loadSummary(for: "Healthy.mp3", reference: reference)
        let wrong = SharedRecordingReference(libraryID: reference.libraryID, entityID: aid)
        let beforeEdits = try await a.recording(at: "Healthy.mp3", reference: reference)
        do { try await transcripts.updateSpeakerNames(for: "Healthy.mp3", names: ["speaker": "Wrong identity"], reference: wrong); XCTFail("Queued names must retain their selected ID") } catch SharedSidecarError.reloadRequired { }
        do { try await transcripts.splitSpeaker(for: "Healthy.mp3", segmentID: XCTUnwrap(transcript?.segments.first?.id), allFollowing: true, reference: wrong); XCTFail("Queued split must retain its selected ID") } catch SharedSidecarError.reloadRequired { }
        do { try await transcripts.mergeSpeakers(for: "Healthy.mp3", source: "speaker", into: "other", reference: wrong); XCTFail("Queued merge must retain its selected ID") } catch SharedSidecarError.reloadRequired { }
        do { try await summaries.toggleItem(XCTUnwrap(summary?.sections.first?.items?.first?.id), inSummaryFor: "Healthy.mp3", reference: wrong); XCTFail("Queued checkbox must retain its selected ID") } catch SharedSidecarError.reloadRequired { }
        let afterEdits = try await a.recording(at: "Healthy.mp3", reference: reference)
        XCTAssertEqual(beforeEdits.state, afterEdits.state)
        let mode = await records.mode(for: "Healthy.mp3")
        XCTAssertEqual(edited?.speakerNames["speaker"], "Synthetic name")
        XCTAssertEqual(completed?.sections.first?.items?.first?.isCompleted, true)
        XCTAssertEqual(mode, "Pho")
        XCTAssertEqual(transcript?.plainText(), "Resident healthy B")
        XCTAssertEqual(summary?.sections.first?.content, "Resident healthy summary")
        do { _ = try await transcripts.loadTranscript(for: "A.mp3", reference: reference); XCTFail("A stable ID must not authorize another selected path") }
        catch SharedLibraryCoordinatorError.differentBinding { }
        do { _ = try await summaries.loadSummary(for: "Healthy.mp3", reference: .init(libraryID: UUID(), entityID: bid)); XCTFail("A copied entity ID must not cross library bindings") }
        catch SharedLibraryCoordinatorError.differentBinding { }
        do { _ = try await TranscriptStore(baseDirectory: right).loadTranscript(for: "Healthy.mp3", reference: reference); XCTFail("A legacy store must reject a shared recording reference") }
        catch SharedLibraryCoordinatorError.differentBinding { }
        let otherCatalog = RecordingStore(baseDirectory: right, shared: SharedRecordingMetadataAdapter(coordinator: b))
        try await otherCatalog.setup()
        do { try await transcripts.loadAll(from: otherCatalog); XCTFail("A same-library catalog from another coordinator must not supply local presence") }
        catch SharedLibraryCoordinatorError.differentBinding { }
        do { try await summaries.loadAll(from: RecordingStore(baseDirectory: left)); XCTFail("A legacy catalog cannot replace accepted shared presence") }
        catch SharedLibraryCoordinatorError.differentBinding { }
    }

    func testOlderCatalogCannotEraseContentSavedBeforeReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Owned presence fixture".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID()); _ = try await coordinator.enable()
        // First content is accepted after this exact catalog observed absence.
        let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await records.setup()
        let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        try await transcripts.save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "New accepted transcript")]), mp3Filename: "Meeting.mp3")
        let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        try await summaries.save(Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
            sections: [.init(heading: "Summary", content: "New accepted generation")]), mp3Filename: "Meeting.mp3")
        try await transcripts.loadAll(from: records); try await summaries.loadAll(from: records)
        let transcriptPresent = await transcripts.hasTranscript(for: "Meeting.mp3"); XCTAssertTrue(transcriptPresent)
        let present = await summaries.hasSummary(for: "Meeting.mp3")
        XCTAssertTrue(present, "An older absence must not erase a successful accepted save")
        let view = try await coordinator.recording(at: "Meeting.mp3")
        _ = try await coordinator.edit(.init(base: view, changes: [.delete]))
        try await records.loadLibraryMeta(); try await summaries.loadAll(from: records); try await transcripts.loadAll(from: records)
        let transcriptDeleted = await transcripts.hasTranscript(for: "Meeting.mp3"); XCTAssertFalse(transcriptDeleted)
        let deleted = await summaries.hasSummary(for: "Meeting.mp3")
        XCTAssertFalse(deleted, "A genuinely newer accepted tombstone must still clear content")
    }
    private actor PresenceGate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    func testOlderHeldCatalogCannotEraseNewerIndividualRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Owned presence fixture".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID()); _ = try await coordinator.enable()
        let gate = PresenceGate()
        let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator, beforeLoadReturn: { await gate.wait() }))
        let loading = Task { try await records.setup() }
        for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        let entered = await gate.entered; XCTAssertTrue(entered)
        let summary = Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
            sections: [.init(heading: "Summary", content: "New independently read generation")])
        try await SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator)).save(summary, mp3Filename: "Meeting.mp3")
        try await TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator)).save(
            Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
                segments: [.init(startTime: 0, endTime: 1, text: "New individually read transcript")]), mp3Filename: "Meeting.mp3")
        let transcriptReader = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let transcript = try await transcriptReader.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(transcript?.plainText(), "New individually read transcript")
        let reader = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let loaded = try await reader.loadSummary(for: "Meeting.mp3")
        XCTAssertEqual(loaded?.sections.first?.content, "New independently read generation")
        await gate.release(); try await loading.value
        try await reader.loadAll(from: records); try await transcriptReader.loadAll(from: records)
        let transcriptPresent = await transcriptReader.hasTranscript(for: "Meeting.mp3"); XCTAssertTrue(transcriptPresent)
        let present = await reader.hasSummary(for: "Meeting.mp3")
        XCTAssertTrue(present, "An older scan must preserve a newer successful individual read")
    }

    func testHeldStandalonePresenceScanPreservesANewerIndividualRead() async throws {
        for component in [SharedComponent.transcript, .summary] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["A.mp3", "B.mp3"] { try Data("Owned standalone fixture".utf8).write(to: root.appendingPathComponent(name)) }
            let writer = SharedLibraryCoordinator(root: root, writerID: UUID()); _ = try await writer.enable()
            let a = try await writer.reference(to: "A.mp3"), b = try await writer.reference(to: "B.mp3")
            let reader = SharedLibraryCoordinator(root: root, writerID: writer.writerID)
            let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: reader))
            let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: reader))
            let held = expectation(description: "Unrelated A held"), readB = expectation(description: "Older scan read B absence")
            let release = DispatchSemaphore(value: 0)
            let head = root.appendingPathComponent(".docktape/records/" + a.entityID.uuidString.lowercased() + "/" + writer.writerID.uuidString.lowercased() + ".json")
            let holder = Task { try await CoordinatedFileAccess().withWrite(at: head) { _ in held.fulfill(); _ = release.wait(timeout: .now() + 8) } }
            await fulfillment(of: [held], timeout: 1)
            let stream = await reader.events()
            let observer = Task { for await event in stream { if case .entity(_, let entity, _) = event, entity.id == b.entityID { readB.fulfill(); return } } }
            let scan = Task { if component == .transcript { try await transcripts.loadAll() } else { try await summaries.loadAll() } }
            await fulfillment(of: [readB], timeout: 2)
            observer.cancel()
            if component == .transcript {
                try await TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: writer)).save(
                    Transcript(recordingFilename: "B.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
                        segments: [.init(startTime: 0, endTime: 1, text: "New accepted B")]), mp3Filename: "B.mp3")
                _ = try await transcripts.loadTranscript(for: "B.mp3", reference: b)
            } else {
                try await SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: writer)).save(
                    Summary(recordingFilename: "B.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
                        sections: [.init(heading: "Summary", content: "New accepted B")]), mp3Filename: "B.mp3")
                _ = try await summaries.loadSummary(for: "B.mp3", reference: b)
            }
            release.signal(); try await holder.value; try await scan.value
            let present = component == .transcript ? await transcripts.hasTranscript(for: "B.mp3") : await summaries.hasSummary(for: "B.mp3")
            XCTAssertTrue(present, "The older held scan must preserve the accepted B read")
        }
    }

    func testNewCompleteAbsenceOutranksOlderPositiveCatalogInFreshStores() async throws {
        let (root, coordinator) = try await fixture()
        try await SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator)).save(
            Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
                sections: [.init(heading: "Summary", content: "Old accepted summary")]), mp3Filename: "Meeting.mp3")
        let older = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator)); try await older.setup()
        _ = try await coordinator.edit(.init(base: try await coordinator.recording(at: "Meeting.mp3"), changes: [.delete]))
        let newer = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator)); try await newer.setup()
        for standalone in [false, true] {
            let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
            let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
            if standalone { try await transcripts.loadAll(); try await summaries.loadAll() }
            else { try await transcripts.loadAll(from: newer); try await summaries.loadAll(from: newer) }
            try await transcripts.loadAll(from: older); try await summaries.loadAll(from: older)
            let transcriptPresent = await transcripts.hasTranscript(for: "Meeting.mp3"), summaryPresent = await summaries.hasSummary(for: "Meeting.mp3")
            XCTAssertFalse(transcriptPresent, "A fresh store must remember complete absence for unknown keys")
            XCTAssertFalse(summaryPresent, "Old positive catalogs cannot resurrect a newer accepted deletion")
        }
    }
    private actor ObservedPresence {
        var first: (Bool, Bool)?
        func accept(_ value: (Bool, Bool)) -> Bool { guard first == nil else { return false }; first = value; return true }
    }
    func testProgressiveCachedViewsDoNotClaimANewerPresenceObservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["Meeting.mp3", "Other.mp3"] { try Data("Owned partial presence".utf8).write(to: root.appendingPathComponent(name)) }
        try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Old content")]), mp3Filename: "Meeting.mp3")
        try await SummaryStore(baseDirectory: root).save(Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
            sections: [.init(heading: "Summary", content: "Old content")]), mp3Filename: "Meeting.mp3")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID()); _ = try await coordinator.enable()
        let older = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator)); try await older.setup()
        let view = try await coordinator.recording(at: "Meeting.mp3")
        _ = try await coordinator.edit(.init(base: view, changes: [.delete]))
        let newer = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator)); try await newer.setup()
        let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        try await transcripts.loadAll(from: newer); try await summaries.loadAll(from: newer)
        let head = root.appendingPathComponent(".docktape/records/" + view.state.id.uuidString.lowercased() + "/" + coordinator.writerID.uuidString.lowercased() + ".json")
        let held = expectation(description: "Deleted B cannot refresh yet"), partial = expectation(description: "A triggers partial cached catalog")
        let release = DispatchSemaphore(value: 0)
        let holder = Task { try await CoordinatedFileAccess().withWrite(at: head) { _ in held.fulfill(); _ = release.wait(timeout: .now() + 8) } }
        await fulfillment(of: [held], timeout: 1)
        let observation = ObservedPresence()
        let refresh = Task { try await older.loadLibraryMeta(onProgress: {
            try? await transcripts.loadAll(from: older); try? await summaries.loadAll(from: older)
            let flags = (await transcripts.hasTranscript(for: "Meeting.mp3"), await summaries.hasSummary(for: "Meeting.mp3"))
            if await observation.accept(flags) { partial.fulfill() }
        }) }
        await fulfillment(of: [partial], timeout: 2)
        release.signal(); try await holder.value; try await refresh.value
        let observed = await observation.first
        XCTAssertEqual(observed?.0, false, "A cached positive B view is not a new observation during A progress")
        XCTAssertEqual(observed?.1, false)
    }

    func testObsoleteSharedReadCannotReplaceNewerCachedContentOrEditorInput() async throws {
        for component in [SharedComponent.transcript, .summary] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for filename in ["One.mp3", "Two.mp3"] {
                try Data("Owned overlapping read fixture".utf8).write(to: root.appendingPathComponent(filename))
                try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: filename, transcriptionModel: "fixture", hasSpeakerLabels: true,
                    segments: [.init(startTime: 0, endTime: 1, text: "Old accepted text", speakerID: "s")]), mp3Filename: filename)
                try await SummaryStore(baseDirectory: root).save(Summary(recordingFilename: filename, model: "fixture", provider: "fixture", templateUsed: "fixture",
                    sections: [.init(heading: "Summary", content: "Old accepted text")]), mp3Filename: filename)
            }
            let witness = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-local"); roots.append(witness)
            let writer = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: witness); _ = try await writer.enable(); _ = try await writer.projectOutputs()
            let views = try await writer.snapshots(kinds: [.recording]).sorted { $0.state.id.uuidString < $1.state.id.uuidString }
            let selected = views[0], unrelated = views[1]
            let reference = SharedRecordingReference(libraryID: selected.libraryID, entityID: selected.state.id)
            guard case .text(let initial)? = selected.state.value(for: "initialPath") else { throw SharedSidecarError.invalidContent }
            _ = try await writer.relocateRecording(filename: initial, title: "Renamed", reference: reference)
            let reader = SharedLibraryCoordinator(root: root, writerID: writer.writerID, witnessDirectory: witness)
            let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: reader))
            let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: reader))
            let before = try await writer.recording(at: "Renamed.mp3", reference: reference)
            let held = expectation(description: "Later unrelated head held"), reached = expectation(description: "Older global lookup retained selected snapshot before unrelated wait")
            let release = DispatchSemaphore(value: 0)
            let head = root.appendingPathComponent(".docktape/records/" + unrelated.state.id.uuidString.lowercased() + "/" + writer.writerID.uuidString.lowercased() + ".json")
            let holder = Task { try await CoordinatedFileAccess().withWrite(at: head) { _ in held.fulfill(); _ = release.wait(timeout: .now() + 8) } }
            await fulfillment(of: [held], timeout: 1)
            let stream = await reader.events()
            let observer = Task { for await event in stream { if case .loading(_, let entity) = event, entity.id == unrelated.state.id { reached.fulfill(); return } } }
            let old = Task { if component == .transcript { _ = try await transcripts.loadTranscript(for: "Renamed.mp3") } else { _ = try await summaries.loadSummary(for: "Renamed.mp3") } }
            await fulfillment(of: [reached], timeout: 2); observer.cancel()
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let bytes: Data
            if component == .transcript {
                bytes = try encoder.encode(Transcript(recordingFilename: "Renamed.mp3", transcriptionModel: "new", hasSpeakerLabels: true,
                    segments: [.init(startTime: 0, endTime: 1, text: "New accepted text", speakerID: "s")]))
            } else {
                bytes = try encoder.encode(Summary(recordingFilename: "Renamed.mp3", model: "new", provider: "fixture", templateUsed: "fixture",
                    sections: [.init(heading: "Summary", content: "New accepted text")]))
            }
            _ = try await writer.edit(.init(base: before, changes: [.generation(try SharedDocument(id: UUID(), json: bytes), component: component)]))
            if component == .transcript { _ = try await transcripts.loadTranscript(for: "Renamed.mp3", reference: reference) }
            else { _ = try await summaries.loadSummary(for: "Renamed.mp3", reference: reference) }
            release.signal(); try await holder.value
            do { try await old.value } catch is CancellationError { }
            if component == .transcript {
                let cached = await transcripts.cachedTranscript(for: "Renamed.mp3")
                XCTAssertEqual(cached?.segments.first?.text, "New accepted text", "Obsolete results must not replace the current editor input")
                try await transcripts.mergeSpeakers(for: "Renamed.mp3", source: "s", into: "other", reference: reference)
                let persisted = try await transcripts.loadTranscript(for: "Renamed.mp3", reference: reference)
                XCTAssertEqual(persisted?.segments.first?.text, "New accepted text", "A current editor must not publish obsolete cached text")
            } else {
                let cached = await summaries.allSummaries()
                XCTAssertEqual(cached.first?.sections.first?.content, "New accepted text", "The summary cache must also reject obsolete read results")
            }
        }
    }

    private actor ReadCompletion {
        var finished = false
        func finish() { finished = true }
    }
    func testNewCompletePresenceOrdersAnUncachedPendingIndividualRead() async throws {
        for component in [SharedComponent.transcript, .summary] {
            for initiallyPresent in [false, true] {
              for scanFirst in [true, false] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for index in 0..<48 { try Data("Owned pending read fixture".utf8).write(to: root.appendingPathComponent("Recording-\(index).mp3")) }
                let witness = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-local"); roots.append(witness)
                let writer = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: witness); _ = try await writer.enable()
                let views = try await writer.snapshots(kinds: [.recording]).sorted { $0.state.id.uuidString < $1.state.id.uuidString }
                let selected = views[0], cold = views[1]
                let reference = SharedRecordingReference(libraryID: selected.libraryID, entityID: selected.state.id)
                guard case .text(let initial)? = selected.state.value(for: "initialPath") else { throw SharedSidecarError.invalidContent }
                _ = try await writer.relocateRecording(filename: initial, title: "Renamed", reference: reference)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                func document(_ text: String) throws -> SharedDocument {
                    let bytes: Data
                    if component == .transcript { bytes = try encoder.encode(Transcript(recordingFilename: "Renamed.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
                        segments: [.init(startTime: 0, endTime: 1, text: text)])) }
                    else { bytes = try encoder.encode(Summary(recordingFilename: "Renamed.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
                        sections: [.init(heading: "Summary", content: text)])) }
                    return try SharedDocument(id: UUID(), json: bytes)
                }
                if initiallyPresent { _ = try await writer.edit(.init(base: try await writer.recording(at: "Renamed.mp3", reference: reference), changes: [.generation(try document("Old content"), component: component)])) }
                let reader = SharedLibraryCoordinator(root: root, writerID: writer.writerID, witnessDirectory: witness)
                let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: reader)); try await records.setup()
                let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: reader))
                let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: reader))
                try await transcripts.loadAll(from: records); try await summaries.loadAll(from: records)
                let base = try await writer.recording(at: "Renamed.mp3", reference: reference)
                let held = expectation(description: "Later fallback head held"), reached = expectation(description: "Pending read retained old target")
                let release = DispatchSemaphore(value: 0)
                let head = root.appendingPathComponent(".docktape/records/" + cold.state.id.uuidString.lowercased() + "/" + writer.writerID.uuidString.lowercased() + ".json")
                let holder = Task { try await CoordinatedFileAccess().withWrite(at: head) { _ in held.fulfill(); _ = release.wait(timeout: .now() + 8) } }
                await fulfillment(of: [held], timeout: 1)
                let stream = await reader.events(), completion = ReadCompletion()
                let observer = Task { for await event in stream { if case .loading(_, let entity) = event, entity.id == cold.state.id { reached.fulfill(); return } } }
                let old = Task { () throws -> String? in
                    let value: String?
                    if component == .transcript { value = try await transcripts.loadTranscript(for: "Renamed.mp3")?.segments.first?.text }
                    else { value = try await summaries.loadSummary(for: "Renamed.mp3")?.sections.first?.content }
                    await completion.finish(); return value
                }
                await fulfillment(of: [reached], timeout: 2); observer.cancel()
                _ = try await writer.edit(.init(base: base, changes: initiallyPresent ? [.delete] : [.generation(try document("New content"), component: component)]))
                let scanGate = PresenceGate()
                let newer = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: reader, beforeLoadReturn: { if !scanFirst { await scanGate.wait() } }))
                let scan = Task { try await newer.setup(); try await transcripts.loadAll(from: newer); try await summaries.loadAll(from: newer) }
                release.signal(); try await holder.value
                let result: String?
                if scanFirst {
                    try await scan.value
                    let oldFinished = await completion.finished
                    XCTAssertFalse(oldFinished, "Fixture must apply newer scan before old read completion")
                    result = try await old.value
                } else {
                    for _ in 0..<200 { if await scanGate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
                    let gateEntered = await scanGate.entered; XCTAssertTrue(gateEntered)
                    result = try await old.value
                    await scanGate.release(); try await scan.value
                }
                let present = component == .transcript ? await transcripts.hasTranscript(for: "Renamed.mp3") : await summaries.hasSummary(for: "Renamed.mp3")
                XCTAssertEqual(present, !initiallyPresent, "Newer accepted presence wins in either completion order")
                if scanFirst { XCTAssertEqual(result, initiallyPresent ? nil : "New content", "An invalidated pending read must use current accepted content") }
              }
            }
        }
    }

    func testFailedAndCancelledReadsCannotVetoCapturedAcceptedAbsence() async throws {
        for failure in ["deleted", "wrongReference", "cancelled"] {
            let (root, coordinator) = try await fixture()
            let reference = try await coordinator.reference(to: "Meeting.mp3")
            let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
            let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
            try await summaries.save(Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
                sections: [.init(heading: "Summary", content: "Old content")]), mp3Filename: "Meeting.mp3")
            _ = try await transcripts.loadTranscript(for: "Meeting.mp3", reference: reference)
            _ = try await summaries.loadSummary(for: "Meeting.mp3", reference: reference)
            _ = try await coordinator.edit(.init(base: try await coordinator.recording(at: "Meeting.mp3", reference: reference), changes: [.delete]))
            let newer = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator)); try await newer.setup()
            if failure == "cancelled" {
                for component in [SharedComponent.transcript, .summary] {
                    let held = expectation(description: "Deleted target held for cancellation"), reading = expectation(description: "Read began before cancellation")
                    let release = DispatchSemaphore(value: 0)
                    let head = root.appendingPathComponent(".docktape/records/" + reference.entityID.uuidString.lowercased() + "/" + coordinator.writerID.uuidString.lowercased() + ".json")
                    let holder = Task { try await CoordinatedFileAccess().withWrite(at: head) { _ in held.fulfill(); _ = release.wait(timeout: .now() + 8) } }
                    await fulfillment(of: [held], timeout: 1)
                    let stream = await coordinator.events()
                    let observer = Task { for await event in stream { if case .loading(_, let entity) = event, entity.id == reference.entityID { reading.fulfill(); return } } }
                    let read = Task {
                        if component == .transcript { _ = try await transcripts.loadTranscript(for: "Meeting.mp3", reference: reference) }
                        else { _ = try await summaries.loadSummary(for: "Meeting.mp3", reference: reference) }
                    }
                    await fulfillment(of: [reading], timeout: 2); observer.cancel(); read.cancel()
                    do { try await read.value; XCTFail("Held read must cancel") } catch is CancellationError { }
                    release.signal(); try await holder.value
                }
            } else {
                let requested = failure == "wrongReference" ? SharedRecordingReference(libraryID: UUID(), entityID: reference.entityID) : reference
                do { _ = try await transcripts.loadTranscript(for: "Meeting.mp3", reference: requested); XCTFail("Invalid/deleted read must fail") }
                catch SharedSidecarError.conflictedContent { } catch SharedLibraryCoordinatorError.differentBinding { }
                do { _ = try await summaries.loadSummary(for: "Meeting.mp3", reference: requested); XCTFail("Invalid/deleted read must fail") }
                catch SharedSidecarError.conflictedContent { } catch SharedLibraryCoordinatorError.differentBinding { }
            }
            try await transcripts.loadAll(from: newer); try await summaries.loadAll(from: newer)
            let transcriptPresent = await transcripts.hasTranscript(for: "Meeting.mp3"), summaryPresent = await summaries.hasSummary(for: "Meeting.mp3")
            XCTAssertFalse(transcriptPresent, failure + " must not veto accepted absence")
            XCTAssertFalse(summaryPresent, failure + " must not veto accepted absence")
            let cachedTranscripts = await transcripts.allTranscripts(), cachedSummaries = await summaries.allSummaries()
            XCTAssertTrue(cachedTranscripts.isEmpty); XCTAssertTrue(cachedSummaries.isEmpty)
        }
    }

    func testFirstAcceptedGenerationsAreKnownBeforeProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Owned synthetic original".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID())
        _ = try await coordinator.enable()
        let transcript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Accepted before output publication")])
        let summary = Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
            sections: [.init(heading: "Summary", content: "Accepted before output publication")])
        try await TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator)).save(transcript, mp3Filename: "Meeting.mp3")
        try await SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator)).save(summary, mp3Filename: "Meeting.mp3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.summary.json").path))
        let reopened = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID)
        let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: reopened))
        let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: reopened))
        try await transcripts.loadAll(); try await summaries.loadAll()
        let hasTranscript = await transcripts.hasTranscript(for: "Meeting.mp3"), hasSummary = await summaries.hasSummary(for: "Meeting.mp3")
        XCTAssertTrue(hasTranscript); XCTAssertTrue(hasSummary)
        let loaded = try await transcripts.loadTranscript(for: "Meeting.mp3"), loadedSummary = try await summaries.loadSummary(for: "Meeting.mp3")
        XCTAssertEqual(loaded?.plainText(), "Accepted before output publication")
        XCTAssertEqual(loadedSummary?.sections.first?.content, "Accepted before output publication")
        let view = try await reopened.recording(at: "Meeting.mp3")
        _ = try await reopened.edit(.init(base: view, changes: [.delete]))
        try await transcripts.loadAll(); try await summaries.loadAll()
        let removedTranscript = await transcripts.hasTranscript(for: "Meeting.mp3"), removedSummary = await summaries.hasSummary(for: "Meeting.mp3")
        XCTAssertFalse(removedTranscript); XCTAssertFalse(removedSummary)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.mp3")), Data("Owned synthetic original".utf8))
    }
    func testUnacceptedPhysicalSidecarsDoNotClaimSharedContentExistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Owned synthetic original".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID()); _ = try await coordinator.enable()
        for component in ["transcript", "summary"] { try Data("External unaccepted file".utf8).write(to: root.appendingPathComponent("Meeting." + component + ".json")) }
        let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let summaries = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        try await transcripts.loadAll(); try await summaries.loadAll()
        let hasTranscript = await transcripts.hasTranscript(for: "Meeting.mp3"), hasSummary = await summaries.hasSummary(for: "Meeting.mp3")
        XCTAssertFalse(hasTranscript); XCTAssertFalse(hasSummary)
    }

    func testActualTranscriptStoresMergeIndependentSpeakerEditsThroughSharedAuthority() async throws {
        let (root, coordinator) = try await fixture()
        let one = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let two = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await one.loadTranscript(for: "Meeting.mp3")
        _ = try await two.loadTranscript(for: "Meeting.mp3")
        try await one.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Anna", "B": "Bob"])
        try await two.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Alice", "B": "Ben"])
        let result = try await one.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(result?.speakerNames, ["A": "Anna", "B": "Ben"])
    }
    func testActualTranscriptStoreRejectsEditToSupersededGeneration() async throws {
        let (root, coordinator) = try await fixture()
        let one = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let two = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await one.loadTranscript(for: "Meeting.mp3")
        let replacement = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "new", hasSpeakerLabels: true,
                                     segments: [.init(startTime: 0, endTime: 2, text: "New", speakerID: "A")])
        _ = try await two.loadTranscript(for: "Meeting.mp3")
        try await two.save(replacement, mp3Filename: "Meeting.mp3")
        do {
            try await one.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Wrong"])
            XCTFail("An old display must not rename a new generation")
        } catch SharedLibraryCoordinatorError.staleReview {}
        let result = try await two.loadTranscript(for: "Meeting.mp3")
        XCTAssertTrue(result?.speakerNames.isEmpty == true)
        XCTAssertEqual(result?.segments.first?.text, "New")
    }
    func testSharedSidecarDoesNotTrustUntrackedDiskReplacement() async throws {
        let (root, coordinator) = try await fixture()
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let before = try await store.loadTranscript(for: "Meeting.mp3")
        try Data("{\"untracked\":true}".utf8).write(to: root.appendingPathComponent("Meeting.transcript.json"))
        let after = try await store.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(before?.segments.first?.id, after?.segments.first?.id)
    }
    func testSharedSummaryStoresMergeIndependentCheckboxes() async throws {
        let (root, coordinator) = try await fixture()
        let first = Summary.Item(text: "First"), second = Summary.Item(text: "Second")
        let summary = Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
                              sections: [.init(heading: "Tasks", content: "", items: [first, second])])
        let one = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let two = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        try await one.save(summary, mp3Filename: "Meeting.mp3")
        _ = try await two.loadSummary(for: "Meeting.mp3")
        try await one.toggleItem(first.id, inSummaryFor: "Meeting.mp3")
        try await two.toggleItem(second.id, inSummaryFor: "Meeting.mp3")
        let result = try await one.loadSummary(for: "Meeting.mp3")
        XCTAssertEqual(result?.sections.first?.items?.map(\.isCompleted), [true, true])
    }
    func testSpeakerRemovalSurvivesReloadAndDoesNotRestoreOriginalLabel() async throws {
        let (root, coordinator) = try await fixture()
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await store.loadTranscript(for: "Meeting.mp3")
        try await store.updateSpeakerNames(for: "Meeting.mp3", names: ["B": "Bob"])
        let fresh = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let result = try await fresh.loadTranscript(for: "Meeting.mp3")
        XCTAssertNil(result?.speakerNames["A"])
        XCTAssertEqual(result?.speakerNames["B"], "Bob")
    }
    func testSaveRejectsContentBelongingToAnotherRecording() async throws {
        let (root, coordinator) = try await fixture()
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let before = try await store.loadTranscript(for: "Meeting.mp3")
        let copied = Transcript(recordingFilename: "SomeoneElse.mp3", transcriptionModel: "fixture",
                                hasSpeakerLabels: false, segments: [])
        do {
            try await store.save(copied, mp3Filename: "Meeting.mp3")
            XCTFail("Copied content must be explicitly rebound/adopted")
        } catch SharedSidecarError.invalidContent {}
        let result = try await store.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(result?.segments.first?.id, before?.segments.first?.id)
    }
    func testSharedStoreCannotBlindlyReplaceExistingContentWithoutAnInputSnapshot() async throws {
        let (root, coordinator) = try await fixture()
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let generated = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "stale job",
                                   hasSpeakerLabels: false, segments: [])
        do {
            try await store.save(generated, mp3Filename: "Meeting.mp3")
            XCTFail("An unpinned producer must not consume an existing generation")
        } catch SharedSidecarError.reloadRequired {}
    }

    private func deliverOwned(_ source: URL, _ destination: URL, writer: UUID) throws {
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
    func testActualStoresMergeOfflineTwoRootEditsAndPreserveCompetingNames() async throws {
        let (left, one) = try await fixture()
        let right = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(right)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: right.appendingPathComponent("Meeting.mp3"))
        let secondWriter = UUID()
        let two = SharedLibraryCoordinator(root: right, writerID: secondWriter)
        try deliverOwned(left, right, writer: one.writerID)
        try await two.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliverOwned(right, left, writer: secondWriter)
        try await one.refresh()
        try deliverOwned(left, right, writer: one.writerID)
        try await two.refresh()
        try deliverOwned(right, left, writer: secondWriter)
        try await one.refresh()
        try deliverOwned(left, right, writer: one.writerID)
        let a = TranscriptStore(baseDirectory: left, shared: SharedSidecarAdapter(coordinator: one))
        let b = TranscriptStore(baseDirectory: right, shared: SharedSidecarAdapter(coordinator: two))
        _ = try await a.loadTranscript(for: "Meeting.mp3")
        _ = try await b.loadTranscript(for: "Meeting.mp3")
        // No transport between these edits: actors cannot serialize two roots.
        try await a.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Anna", "B": "Bob"])
        try await b.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Alice", "B": "Ben"])
        try deliverOwned(left, right, writer: one.writerID)
        try deliverOwned(right, left, writer: secondWriter)
        let joinedA = try await a.loadTranscript(for: "Meeting.mp3")
        let joinedB = try await b.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(joinedA?.speakerNames, ["A": "Anna", "B": "Ben"])
        XCTAssertEqual(joinedB?.speakerNames, joinedA?.speakerNames)
        // Establish the joined view as the confirmed common projection.
        for _ in 0..<3 {
            try await one.refresh()
            try deliverOwned(left, right, writer: one.writerID)
            try await two.refresh()
            try deliverOwned(right, left, writer: secondWriter)
        }
        let common = try await one.recording(at: "Meeting.mp3").confirmedState
        XCTAssertEqual(common?.generationEdits(for: .transcript)["A"], .text("Anna"))
        try await a.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Left choice", "B": "Ben"])
        try await b.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Right choice", "B": "Ben"])
        try deliverOwned(left, right, writer: one.writerID)
        try deliverOwned(right, left, writer: secondWriter)
        let state = try await one.recording(at: "Meeting.mp3").state
        let conflict = try XCTUnwrap(state.conflicts.first { $0.field.hasSuffix(".A") })
        XCTAssertEqual(conflict.values, [.text("Left choice"), .text("Right choice")])
        let other = try await two.recording(at: "Meeting.mp3").state
        XCTAssertEqual(state, other)
        let conflictedDisplay = try await a.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(conflictedDisplay?.speakerNames["A"], "Anna", "Retain the last confirmed choice during conflict")
        XCTAssertEqual(conflictedDisplay?.speakerNames["B"], "Ben")
        do {
            try await a.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Unreviewed third choice", "B": "Ben"])
            XCTFail("Ordinary editing must not silently consume both competing values")
        } catch SharedSidecarError.conflictedContent {}
        let unresolved = try await one.recording(at: "Meeting.mp3").state
        XCTAssertEqual(unresolved.conflicts.first { $0.field.hasSuffix(".A") }?.values,
                       [.text("Left choice"), .text("Right choice")])
    }

    func testSharedAdapterCannotBeAttachedToAnotherLibraryRoot() async throws {
        let (_, coordinator) = try await fixture()
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(other)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let store = TranscriptStore(baseDirectory: other, shared: SharedSidecarAdapter(coordinator: coordinator))
        do {
            _ = try await store.loadTranscript(for: "Meeting.mp3")
            XCTFail("A store must not read another library through its attached adapter")
        } catch SharedLibraryCoordinatorError.differentBinding {}
    }

    func testCommittedSpeakerEditSurvivesCancellationWithoutReportingRollback() async throws {
        let (root, original) = try await fixture()
        let cancelled = SharedLibraryCoordinator(root: root, writerID: original.writerID,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: cancelled))
        _ = try await store.loadTranscript(for: "Meeting.mp3")
        let work = Task { try await store.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Accepted", "B": "Bob"]) }
        do { try await work.value }
        catch { XCTFail("Committed speaker edit must return its accepted result: \(error)") }
        let reopened = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: original))
        let result = try await reopened.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(result?.speakerNames["A"], "Accepted")
    }
    func testCommittedSummaryEditSurvivesCancellationWithoutReportingRollback() async throws {
        let (root, original) = try await fixture()
        let item = Summary.Item(text: "Task")
        let summary = Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
                              sections: [.init(heading: "Tasks", content: "", items: [item])])
        try await SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: original)).save(summary, mp3Filename: "Meeting.mp3")
        let cancelled = SharedLibraryCoordinator(root: root, writerID: original.writerID,
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let store = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: cancelled))
        _ = try await store.loadSummary(for: "Meeting.mp3")
        let work = Task { try await store.toggleItem(item.id, inSummaryFor: "Meeting.mp3") }
        do { try await work.value }
        catch { XCTFail("Committed checkbox edit must return its accepted result: \(error)") }
        let reopened = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: original))
        let result = try await reopened.loadSummary(for: "Meeting.mp3")
        XCTAssertTrue(result?.sections.first?.items?.first?.isCompleted == true)
    }

}
