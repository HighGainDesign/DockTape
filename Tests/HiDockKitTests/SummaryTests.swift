// © 2026 High Gain Design. All rights reserved.

// Tests/HiDockKitTests/SummaryTests.swift
import XCTest
@testable import HiDockKit

final class SummaryTests: XCTestCase {

    func testSummaryCodableRoundTrip() throws {
        let summary = Summary(
            recordingFilename: "meeting.mp3",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            model: "claude-sonnet-4-6",
            provider: "anthropic",
            templateUsed: "meeting",
            customPrompt: nil,
            sections: [
                Summary.Section(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    heading: "Action Items",
                    content: "",
                    items: [
                        Summary.Item(
                            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                            text: "Send follow-up email",
                            isCompleted: false
                        )
                    ]
                ),
                Summary.Section(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    heading: "Summary",
                    content: "Team discussed Q4 roadmap priorities.",
                    items: nil
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Summary.self, from: data)

        XCTAssertEqual(decoded.recordingFilename, "meeting.mp3")
        XCTAssertEqual(decoded.model, "claude-sonnet-4-6")
        XCTAssertEqual(decoded.provider, "anthropic")
        XCTAssertEqual(decoded.templateUsed, "meeting")
        XCTAssertNil(decoded.customPrompt)
        XCTAssertEqual(decoded.sections.count, 2)
        XCTAssertEqual(decoded.sections[0].heading, "Action Items")
        XCTAssertEqual(decoded.sections[0].items?.count, 1)
        XCTAssertEqual(decoded.sections[0].items?[0].text, "Send follow-up email")
        XCTAssertFalse(decoded.sections[0].items?[0].isCompleted ?? true)
        XCTAssertEqual(decoded.sections[1].content, "Team discussed Q4 roadmap priorities.")
    }

    func testSummaryWithCustomPrompt() throws {
        let summary = Summary(
            recordingFilename: "call.mp3",
            createdAt: Date(),
            model: "gpt-4o",
            provider: "openai",
            templateUsed: "custom",
            customPrompt: "Extract all customer objections",
            sections: [
                Summary.Section(
                    id: UUID(),
                    heading: "Customer Objections",
                    content: "Price too high. Timeline too long.",
                    items: nil
                )
            ]
        )

        XCTAssertEqual(summary.id, "call.mp3")
        XCTAssertEqual(summary.customPrompt, "Extract all customer objections")
    }

    func testItemCompletionToggle() {
        var item = Summary.Item(id: UUID(), text: "Review docs", isCompleted: false)
        XCTAssertFalse(item.isCompleted)
        item.isCompleted = true
        XCTAssertTrue(item.isCompleted)
    }
}
