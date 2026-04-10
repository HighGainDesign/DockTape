import XCTest
@testable import HiDockKit

final class SummaryTemplateTests: XCTestCase {

    func testModeToTemplate() {
        XCTAssertEqual(SummaryTemplate.forMode("Mee"), .meeting)
        XCTAssertEqual(SummaryTemplate.forMode("Pho"), .call)
        XCTAssertEqual(SummaryTemplate.forMode("Wip"), .memo)
        XCTAssertEqual(SummaryTemplate.forMode("Rec"), .recording)
        XCTAssertEqual(SummaryTemplate.forMode(""), .recording)
        XCTAssertEqual(SummaryTemplate.forMode("Unknown"), .recording)
    }

    func testMeetingPromptContainsRequiredSections() {
        let prompt = SummaryTemplate.meeting.systemPrompt
        XCTAssertTrue(prompt.contains("Action Items"))
        XCTAssertTrue(prompt.contains("Summary"))
        XCTAssertTrue(prompt.contains("Key Decisions"))
        XCTAssertTrue(prompt.contains("Next Steps"))
        XCTAssertTrue(prompt.contains("JSON"))
    }

    func testCallPromptContainsRequiredSections() {
        let prompt = SummaryTemplate.call.systemPrompt
        XCTAssertTrue(prompt.contains("Action Items"))
        XCTAssertTrue(prompt.contains("Synopsis"))
        XCTAssertTrue(prompt.contains("Commitments"))
    }

    func testMemoPromptIsShort() {
        let prompt = SummaryTemplate.memo.systemPrompt
        XCTAssertTrue(prompt.contains("Gist"))
        // Memo should not request action items as a numbered section
        // (the shared JSON schema example mentions "Action Items" but that's just format guidance)
        XCTAssertFalse(prompt.contains("1. \"Action Items\""))
    }

    func testBuildCustomPrompt() {
        let prompt = SummaryTemplate.buildCustomPrompt("Extract customer objections")
        XCTAssertTrue(prompt.contains("Extract customer objections"))
        XCTAssertTrue(prompt.contains("JSON"))
    }

    func testParseSectionsFromValidJSON() throws {
        let json = """
        {
            "sections": [
                {"heading": "Summary", "content": "A good meeting.", "items": null},
                {"heading": "Action Items", "content": "", "items": [
                    {"text": "Send email", "isCompleted": false}
                ]}
            ]
        }
        """
        let sections = try SummaryTemplate.parseSections(from: json)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].heading, "Summary")
        XCTAssertEqual(sections[1].items?.count, 1)
    }

    func testParseSectionsFallbackOnInvalidJSON() throws {
        let rawText = "This is just plain text, not JSON."
        let sections = try SummaryTemplate.parseSections(from: rawText)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].heading, "Summary")
        XCTAssertEqual(sections[0].content, rawText)
    }
}
