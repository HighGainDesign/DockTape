// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

/// Library state: recordings, folders, selection.
@Observable
@MainActor
final class LibraryState {
    var recordings: [RecordingMetadata] = []
    var folders: [String] = []
    var selectedFolder: String? = nil  // nil = "All Recordings"
    var selectedRecording: String? = nil
    var selectedRecordings: Set<String> = []
    var downloadedFilenames: Set<String> = []
    var searchText: String = ""
    var isSearchFocused: Bool = false

    let store: RecordingStore
    let transcriptStore: TranscriptStore

    init(store: RecordingStore, transcriptStore: TranscriptStore) {
        self.store = store
        self.transcriptStore = transcriptStore
    }

    func setup() async throws {
        try await store.setup()
        try await transcriptStore.loadAll()
        await refresh()
    }

    /// Set of device filenames that have been imported (from library.json).
    var importedDeviceFilenames: Set<String> = []

    func refresh() async {
        recordings = await store.allRecordings()
        downloadedFilenames = Set(recordings.map(\.filename))
        importedDeviceFilenames = await store.allImportedDeviceFilenames()
        folders = await store.folders()
        try? await transcriptStore.loadAll()
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
        folders = await store.folders()
    }

    func renameFolder(from oldName: String, to newName: String) async throws {
        try await store.renameFolder(from: oldName, to: newName)
        if selectedFolder == oldName { selectedFolder = newName }
        await refresh()
    }

    func deleteFolder(named name: String) async throws {
        try await store.deleteFolder(named: name)
        if selectedFolder == name { selectedFolder = nil }
        await refresh()
    }

    func moveRecording(filename: String, toFolder folder: String?) async throws {
        let newFilename = try await store.moveRecording(filename: filename, toFolder: folder)
        await transcriptStore.rename(from: filename, to: newFilename)
        await refresh()
    }

    func deleteRecording(_ rec: RecordingMetadata) async throws {
        try await store.deleteRecording(filename: rec.filename)
        try await transcriptStore.delete(for: rec.filename)
        await refresh()
    }

    func renameRecording(_ rec: RecordingMetadata, to name: String) async throws -> String {
        let newFilename = try await store.renameRecording(filename: rec.filename, to: name)
        await transcriptStore.rename(from: rec.filename, to: newFilename)
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

    func transcript(for filename: String) async -> Transcript? {
        await transcriptStore.transcript(for: filename)
    }

    func updateSpeakerNames(for filename: String, names: [String: String]) async throws {
        // Detect merges (same name assigned to multiple IDs)
        var nameToIDs: [String: [String]] = [:]
        for (sid, name) in names {
            nameToIDs[name, default: []].append(sid)
        }
        for (_, ids) in nameToIDs where ids.count > 1 {
            let sorted = ids.sorted()
            let targetID = sorted[0]
            for sourceID in sorted.dropFirst() {
                try await transcriptStore.mergeSpeakers(for: filename, source: sourceID, into: targetID)
            }
        }
        let current = await transcriptStore.transcript(for: filename)
        if let current {
            var finalNames: [String: String] = [:]
            for sid in current.speakerIDs {
                finalNames[sid] = names[sid] ?? sid
            }
            try await transcriptStore.updateSpeakerNames(for: filename, names: finalNames)
        }
    }
}
