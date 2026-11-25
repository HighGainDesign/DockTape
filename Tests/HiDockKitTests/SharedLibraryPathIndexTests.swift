// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedLibraryPathIndexTests: XCTestCase {
    private let writer = UUID()
    private func folder(_ name: String, parent: UUID? = nil, id: UUID = UUID()) throws -> SharedEntityState {
        var state = SharedEntityState(id: id, kind: .folder)
        try state.assign(field: "name", value: .text(name), writer: writer)
        try state.assign(field: "parent", value: parent.map { .text($0.uuidString) } ?? .unset, writer: writer)
        return state
    }
    private func recording(_ title: String, folder: UUID? = nil) throws -> SharedEntityState {
        var state = SharedEntityState(id: UUID(), kind: .recording)
        try state.assign(field: "title", value: .text(title), writer: writer)
        try state.assign(field: "folder", value: folder.map { .text($0.uuidString) } ?? .unset, writer: writer)
        return state
    }
    func testFolderRenameAndRecordingMoveKeepIdentityAndCompanionClaims() throws {
        var parent = try folder("Old")
        let nested = try folder("Nested", parent: parent.id)
        var item = try recording("Meeting", folder: nested.id)
        let one = try SharedLibraryPathIndex(states: [parent, nested, item], caseSensitive: false)
        XCTAssertEqual(try one.recording(at: "Old/Nested/Meeting.mp3"), item.id)
        try parent.assign(field: "name", value: .text("New"), writer: writer)
        let two = try SharedLibraryPathIndex(states: [parent, nested, item], caseSensitive: false)
        XCTAssertEqual(two.owners(of: "New/Nested/Meeting.summary.md"), [item.id])
        XCTAssertTrue(two.owners(of: "Old/Nested/Meeting.mp3").isEmpty)
        try item.assign(field: "folder", value: .unset, writer: writer)
        let moved = try SharedLibraryPathIndex(states: [parent, nested, item], caseSensitive: false,
                                               retainedLocations: [item.id: ["New/Nested/Meeting.mp3"]])
        XCTAssertEqual(moved.owners(of: "Meeting.mp3"), [item.id])
        XCTAssertEqual(moved.owners(of: "New/Nested/Meeting.transcript.json"), [item.id])
    }
    func testCollidingTitlesAndCaseInsensitiveNamesNeverPickOneOwner() throws {
        let a = try recording("Meeting"), b = try recording("meeting")
        let index = try SharedLibraryPathIndex(states: [a, b], caseSensitive: false)
        XCTAssertEqual(index.owners(of: "MEETING.mp3"), [a.id, b.id])
        XCTAssertThrowsError(try index.recording(at: "Meeting.mp3"))
        let sensitive = try SharedLibraryPathIndex(states: [a, b], caseSensitive: true)
        XCTAssertEqual(try sensitive.recording(at: "Meeting.mp3"), a.id)
        XCTAssertEqual(try sensitive.recording(at: "meeting.mp3"), b.id)
    }
    func testSameBasenameInDifferentFoldersAndPendingDeletionRemainOwned() throws {
        let a = try folder("A"), b = try folder("B")
        let first = try recording("Meeting", folder: a.id)
        var second = try recording("Meeting", folder: b.id)
        try second.delete(writer: writer)
        let index = try SharedLibraryPathIndex(states: [a, b, first, second], caseSensitive: false)
        XCTAssertEqual(try index.recording(at: "A/Meeting.mp3"), first.id)
        XCTAssertEqual(index.owners(of: "B/Meeting.mp3"), [second.id], "Pending delete cannot release its sole original path")
    }
    func testConflictingTitleReservesEveryCompetingPath() throws {
        let initial = try recording("Before")
        var a = initial, b = initial
        try a.assign(field: "title", value: .text("Left"), writer: writer)
        try b.assign(field: "title", value: .text("Right"), writer: UUID())
        let conflict = try a.merged(with: b)
        let index = try SharedLibraryPathIndex(states: [conflict], caseSensitive: false)
        XCTAssertEqual(index.owners(of: "Left.mp3"), [initial.id])
        XCTAssertEqual(index.owners(of: "Right.mp3"), [initial.id])
        XCTAssertNil(index.resolvedPaths[initial.id])
    }
    func testMalformedOrMissingFolderGraphCannotSupplyOperationAuthority() throws {
        let missing = try recording("Meeting", folder: UUID())
        XCTAssertThrowsError(try SharedLibraryPathIndex(states: [missing], caseSensitive: false))
        let id = UUID()
        let cycle = try folder("Cycle", parent: id, id: id)
        let child = try recording("Meeting", folder: id)
        XCTAssertThrowsError(try SharedLibraryPathIndex(states: [cycle, child], caseSensitive: false))
        let invalid = try recording("../Other")
        XCTAssertThrowsError(try SharedLibraryPathIndex(states: [invalid], caseSensitive: false))
    }
}
