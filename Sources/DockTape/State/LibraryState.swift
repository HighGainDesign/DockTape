// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

/// Library state: recordings, folders, selection.
@Observable
@MainActor
final class LibraryState {
    var recordings: [RecordingMetadata] = []
    var folders: [String] = []
    let binding = UUID()
    private var folderReferences: [String: SharedFolderReference] = [:]
    var folderSelections: [FolderSelection] { folders.map { folderSelection(named: $0) } }
    func folderSelection(named name: String) -> FolderSelection {
        .init(name: name, reference: folderReferences[name], libraryBinding: binding)
    }
    private func validate(_ selection: FolderSelection) throws {
        guard selection.libraryBinding == binding else { throw SharedLibraryCoordinatorError.differentBinding }
        if sharedCoordinator != nil {
            guard selection.reference != nil else { throw SharedSidecarError.reloadRequired }
        } else if selection.reference != nil { throw SharedLibraryCoordinatorError.differentBinding }
    }
    func recordingSelection(_ recording: RecordingMetadata) -> RecordingSelection {
        .init(filename: recording.filename, reference: recording.reference, libraryBinding: binding)
    }
    func validate(_ selection: RecordingSelection) throws {
        guard selection.libraryBinding == binding else { throw SharedLibraryCoordinatorError.differentBinding }
        _ = try SharedLibraryIdentity.normalized(selection.filename)
        guard recordings.contains(where: { $0.filename == selection.filename && $0.reference == selection.reference }) else { throw SharedSidecarError.reloadRequired }
        if sharedCoordinator != nil {
            guard selection.reference != nil else { throw SharedSidecarError.reloadRequired }
        } else if selection.reference != nil { throw SharedLibraryCoordinatorError.differentBinding }
    }
    var selectedFolder: String? = nil  // nil = "All Recordings"
    var selectedRecording: String? = nil
    var selectedRecordings: Set<String> = []
    var downloadedFilenames: Set<String> = []
    var searchText: String = ""
    var isSearchFocused: Bool = false

    let store: RecordingStore
    let transcriptStore: TranscriptStore
    let sharedCoordinator: SharedLibraryCoordinator?
    var refreshError: String?
    enum MetadataLoadState { case idle, loading, stopped }
    private(set) var metadataLoadState: MetadataLoadState = .idle
    var isLoadingMetadata: Bool { metadataLoadState == .loading }
    private var contentRevisions: [String: String] = [:]
    private var metadataRequest = UUID()
    private var metadataTask: Task<Void, Error>?
    var onSharedContent: (@MainActor () async -> Void)?


    init(store: RecordingStore, transcriptStore: TranscriptStore, sharedCoordinator: SharedLibraryCoordinator? = nil) {
        self.sharedCoordinator = sharedCoordinator
        self.store = store
        self.transcriptStore = transcriptStore
    }

    func setup() async throws { _ = try await loadMetadata(initial: true) }

    /// Set of device filenames that have been imported (from library.json).
    var importedDeviceFilenames: Set<String> = []

    @discardableResult
    func refresh(afterMetadata: @escaping @MainActor () async -> Void = {}, onFailure: @MainActor (Error) -> Void = { _ in }) async -> Bool {
        do { return try await loadMetadata(initial: false, afterMetadata: afterMetadata) }
        catch { if !(error is CancellationError) { onFailure(error) }; return false }
    }

    func cancelMetadataLoad() {
        metadataRequest = UUID()
        metadataTask?.cancel(); metadataTask = nil
        metadataLoadState = .stopped
        refreshError = nil
    }

    private func loadMetadata(initial: Bool, afterMetadata: @escaping @MainActor () async -> Void = {}) async throws -> Bool {
        metadataTask?.cancel()
        let request = UUID(); metadataRequest = request
        metadataLoadState = .loading; refreshError = nil
        let task = Task { @MainActor [self] in
            do {
                if sharedCoordinator == nil { try await transcriptStore.loadAll() }
                let progress: @Sendable () async -> Void = { [weak self] in await self?.publishCatalog(request: request) }
                if initial { try await store.setup(onProgress: sharedCoordinator == nil ? nil : progress) }
                else if sharedCoordinator != nil { try await store.loadLibraryMeta(onProgress: progress) }
                try Task.checkCancellation()
                await publishCatalog(request: request)
                await afterMetadata()
                try Task.checkCancellation()
            } catch {
                if metadataRequest == request, !(error is CancellationError) { refreshError = error.localizedDescription }
                throw error
            }
        }
        metadataTask = task
        defer {
            if metadataRequest == request { metadataTask = nil; metadataLoadState = .idle }
        }
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            return metadataRequest == request && !Task.isCancelled
        } catch {
            // A stopped/superseded task cannot report a late provider error
            // into the newer load, even if the provider uses its own error type.
            if Task.isCancelled { throw CancellationError() }
            if metadataRequest != request { return false }
            throw error
        }
    }

    private func publishCatalog(request: UUID) async {
        guard metadataRequest == request, !Task.isCancelled else { return }
        let entries = await store.allRecordings()
        let imported = await store.allImportedDeviceFilenames()
        let folderCatalog = await store.folderCatalog()
        let revisions = await store.contentRevisions()
        if sharedCoordinator != nil { try? await transcriptStore.loadAll(from: store) }
        guard metadataRequest == request, !Task.isCancelled else { return }
        recordings = entries
        downloadedFilenames = Set(entries.map(\.filename))
        selectedRecordings.formIntersection(downloadedFilenames)
        if let selectedRecording, !downloadedFilenames.contains(selectedRecording) { self.selectedRecording = nil }
        importedDeviceFilenames = imported; folders = folderCatalog.names; folderReferences = folderCatalog.references
        contentRevisions = revisions
        if sharedCoordinator != nil { await onSharedContent?() }
    }

    func contentID(for filename: String, fallbackRevision: UInt64) -> String {
        let revision = contentRevisions[filename] ?? "legacy-\(fallbackRevision)"
        return store.baseDirectory.appendingPathComponent(filename).absoluteString + "|" + revision
    }

    func isDownloaded(_ filename: String) -> Bool {
        let mp3Name = filename.hasSuffix(".hda")
            ? filename.replacingOccurrences(of: ".hda", with: ".mp3", options: .caseInsensitive)
            : filename
        if downloadedFilenames.contains(mp3Name) { return true }
        // Check library.json for renamed recordings
        return importedDeviceFilenames.contains(filename)
    }

    /// Recordings filtered by the currently selected folder.
    var filteredByFolder: [RecordingMetadata] {
        guard let folder = selectedFolder else { return recordings }
        return recordings.filter { $0.folder == folder || ($0.folder?.hasPrefix(folder + "/") == true) }
    }

    // MARK: - Folder CRUD

    func createFolder(named name: String) async throws {
        try await store.createFolder(named: name)
        if sharedCoordinator != nil { await refresh() }
        else { folders = await store.folders() }
    }

    func renameFolder(from oldName: String, to newName: String) async throws -> String {
        try await renameFolder(selection: folderSelection(named: oldName), to: newName)
    }
    func renameFolder(selection: FolderSelection, to newName: String) async throws -> String {
        try validate(selection)
        let oldName = selection.name
        let affected = recordings.filter { $0.filename.hasPrefix(oldName + "/") }
        let actualName = try await store.renameFolder(from: oldName, to: newName, reference: selection.reference)
        for rec in affected {
            let newFilename = actualName + rec.filename.dropFirst(oldName.count)
            if sharedCoordinator == nil { try await transcriptStore.rename(from: rec.filename, to: newFilename) }
        else { try await transcriptStore.loadAll(from: store) }
        }
        if selectedFolder == oldName { selectedFolder = actualName }
        await refresh()
        return actualName
    }

    func deleteFolder(named name: String) async throws {
        try await deleteFolder(selection: folderSelection(named: name))
    }
    func deleteFolder(selection: FolderSelection) async throws {
        try validate(selection)
        let name = selection.name
        try await store.deleteFolder(named: name, reference: selection.reference)
        if selectedFolder == name { selectedFolder = nil }
        await refresh()
    }

    func moveRecording(filename: String, toFolder folder: String?) async throws -> String {
        guard let recording = recordings.first(where: { $0.filename == filename }) else { throw SharedSidecarError.reloadRequired }
        return try await moveRecording(selection: recordingSelection(recording), toFolder: folder.map { folderSelection(named: $0) })
    }
    func moveRecording(selection: RecordingSelection, toFolder folder: FolderSelection?) async throws -> String {
        try validate(selection)
        if let folder { try validate(folder) }
        let filename = selection.filename
        let newFilename = try await store.moveRecording(filename: filename, toFolder: folder?.name,
            reference: selection.reference, destinationReference: folder?.reference)
        if sharedCoordinator == nil { try await transcriptStore.rename(from: filename, to: newFilename) }
        else { try await transcriptStore.loadAll(from: store) }
        await refresh()
        return newFilename
    }

    @discardableResult
    func deleteRecording(_ rec: RecordingMetadata) async throws -> SharedRecordingFileOutcome? {
        try await deleteRecording(selection: recordingSelection(rec))
    }
    @discardableResult
    func deleteRecording(selection: RecordingSelection) async throws -> SharedRecordingFileOutcome? {
        guard selection.libraryBinding == binding else { throw SharedLibraryCoordinatorError.differentBinding }
        _ = try SharedLibraryIdentity.normalized(selection.filename)
        // Shared deletion follows the displayed ID even after a same-library rename.
        // A legacy filename has no identity and must still belong to this catalog.
        if sharedCoordinator == nil { try validate(selection) }
        let outcome: SharedRecordingFileOutcome?
        if let coordinator = sharedCoordinator {
            guard store.baseDirectory.standardizedFileURL.resolvingSymlinksInPath() == coordinator.root else {
                throw SharedLibraryCoordinatorError.differentBinding
            }
            guard let reference = selection.reference else { throw SharedLibraryCoordinatorError.staleJob }
            outcome = try await coordinator.deleteSharedRecording(filename: selection.filename, reference: reference)
        } else {
            guard selection.reference == nil else { throw SharedLibraryCoordinatorError.differentBinding }
            try await store.deleteRecording(filename: selection.filename)
            try await transcriptStore.delete(for: selection.filename)
            outcome = nil
        }
        await refresh()
        return outcome
    }

    func renameRecording(_ rec: RecordingMetadata, to name: String) async throws -> String {
        try await renameRecording(selection: recordingSelection(rec), to: name)
    }
    func renameRecording(selection: RecordingSelection, to name: String) async throws -> String {
        try validate(selection)
        let newFilename = try await store.renameRecording(filename: selection.filename, to: name, reference: selection.reference)
        if sharedCoordinator == nil { try await transcriptStore.rename(from: selection.filename, to: newFilename) }
        else { try await transcriptStore.loadAll(from: store) }
        await refresh()
        return newFilename
    }

    func revealInFinder(_ rec: RecordingMetadata) {
        let url = store.baseDirectory.appendingPathComponent(rec.filename)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func hasTranscript(for filename: String) async -> Bool {
        await transcriptStore.hasTranscript(for: filename)
    }

    func transcript(for filename: String, reference: SharedRecordingReference? = nil) async -> Transcript? {
        let selected = reference ?? recordings.first(where: { $0.filename == filename })?.reference
        return await transcriptStore.transcript(for: filename, reference: selected)
    }

    func updateSpeakerNames(for filename: String, names: [String: String]) async throws {
        guard let recording = recordings.first(where: { $0.filename == filename }) else { throw SharedSidecarError.reloadRequired }
        try await updateSpeakerNames(selection: recordingSelection(recording), names: names)
    }
    func updateSpeakerNames(selection: RecordingSelection, names: [String: String]) async throws {
        try validate(selection)
        let filename = selection.filename

        // Detect merges (same name assigned to multiple IDs)
        var nameToIDs: [String: [String]] = [:]
        for (sid, name) in names {
            nameToIDs[name, default: []].append(sid)
        }
        for (_, ids) in nameToIDs where ids.count > 1 {
            let sorted = ids.sorted()
            let targetID = sorted[0]
            for sourceID in sorted.dropFirst() {
                try await transcriptStore.mergeSpeakers(for: filename, source: sourceID, into: targetID, reference: selection.reference)
            }
        }
        try validate(selection)
        let current = await transcriptStore.cachedTranscript(for: filename)
        if let current {
            var finalNames: [String: String] = [:]
            for sid in current.speakerIDs {
                finalNames[sid] = names[sid] ?? sid
            }
            try validate(selection)
            try await transcriptStore.updateSpeakerNames(for: filename, names: finalNames, reference: selection.reference)
        }
    }
}
