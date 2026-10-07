// © 2026 High Gain Design. All rights reserved.

import Foundation
import XCTest
@testable import HiDockKit

final class LibraryFileDiscoveryTests: XCTestCase {
    func testFinderHiddenRecordingStillAppears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        var url = directory.appendingPathComponent("cloud-only.mp3")
        try Data([0xff, 0xfb]).write(to: url)
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
        let scanned = await store.allRecordings()
        XCTAssertEqual(scanned.map(\.filename), ["cloud-only.mp3"])
    }

    func testDotFilesAndDotDirectoriesAreExcluded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        for name in [".hidden.mp3", ".cache/nested.mp3", "visible.mp3"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        XCTAssertEqual(LibraryFileDiscovery.files(in: directory, suffix: ".mp3").map(\.relativePath), ["visible.mp3"])
    }

    func testNestedICloudPlaceholdersExposeRecordingAndSidecarKeys() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        try await store.createFolder(named: "Calls")
        for suffix in [".mp3", ".transcript.json", ".summary.json"] {
            try Data().write(to: directory.appendingPathComponent("Calls/.clip\(suffix).icloud"))
        }
        let recordings = await store.allRecordings()
        XCTAssertEqual(recordings.map(\.filename), ["Calls/clip.mp3"])
        let transcripts = TranscriptStore(baseDirectory: directory)
        let summaries = SummaryStore(baseDirectory: directory)
        try await transcripts.loadAll()
        try await summaries.loadAll()
        let hasTranscript = await transcripts.hasTranscript(for: "Calls/clip.mp3")
        let hasSummary = await summaries.hasSummary(for: "Calls/clip.mp3")
        XCTAssertTrue(hasTranscript)
        XCTAssertTrue(hasSummary)
    }

    func testUppercaseMP3ExtensionIsRecognized() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("clip.MP3"))
        XCTAssertEqual(LibraryFileDiscovery.files(in: directory, suffix: ".mp3").map(\.relativePath), ["clip.MP3"])
    }
    func testCloudPlaceholderCountsAsImportedWithoutMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingStore(baseDirectory: directory)
        try await store.setup()
        try Data().write(to: directory.appendingPathComponent(".2026Oct06-090000-Rec00.mp3.icloud"))
        let downloaded = await store.isDownloaded(filename: "2026Oct06-090000-Rec00.hda")
        XCTAssertTrue(downloaded)
    }

}
