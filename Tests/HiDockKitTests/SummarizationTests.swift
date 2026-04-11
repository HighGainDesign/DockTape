// Tests/HiDockKitTests/SummarizationTests.swift
import XCTest
@testable import HiDockKit

/// Mock LLM provider for testing summarization orchestration.
private struct MockLLMProvider: LLMProvider {
    var name: String = "mock"
    var defaultModel: String = "mock-1"
    var availableModels: [String] = ["mock-1"]
    var responseText: String = """
    ## Summary
    Test summary content.

    ## Key Points
    - Point 1
    - Point 2
    """
    var shouldFail: Bool = false
    var delay: Duration = .zero

    func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String {
        if delay > .zero { try await Task.sleep(for: delay) }
        if shouldFail { throw NSError(domain: "MockLLM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock failure"]) }
        return responseText
    }

    func verifyKey() async throws {
        if shouldFail { throw NSError(domain: "MockLLM", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid key"]) }
    }
}

final class SummarizationTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummarizationTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Template Section Parsing

    func testParseSectionsFromJSONResponse() {
        let response = """
        {"sections": [
            {"heading": "Summary", "content": "A productive team standup covering sprint progress."},
            {"heading": "Key Points", "items": [{"text": "Backend API migration is 80% complete"}, {"text": "Frontend team needs design review by Friday"}]},
            {"heading": "Action Items", "items": [{"text": "Schedule design review (Sarah)", "isCompleted": false}, {"text": "Update migration tracker (Mike)", "isCompleted": false}]}
        ]}
        """

        let sections = Template.parseSections(from: response)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].heading, "Summary")
        XCTAssertTrue(sections[0].content.contains("productive team standup"))
        XCTAssertEqual(sections[1].heading, "Key Points")
        XCTAssertEqual(sections[1].items?.count, 2)
        XCTAssertEqual(sections[2].heading, "Action Items")
        XCTAssertEqual(sections[2].items?.count, 2)
    }

    func testParseSectionsHandlesEmptyResponse() {
        let sections = Template.parseSections(from: "")
        // Empty string falls back to a single section
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.heading, "Summary")
    }

    func testParseSectionsFallsBackForPlainText() {
        let response = "Just a plain text response with no JSON."
        let sections = Template.parseSections(from: response)
        // Non-JSON falls back to a single section wrapping the full text
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.heading, "Summary")
        XCTAssertTrue(sections.first?.content.contains("plain text") ?? false)
    }

    // MARK: - Provider Integration

    func testMockProviderSummarize() async throws {
        let provider = MockLLMProvider()
        let result = try await provider.summarize(transcript: "Hello world", systemPrompt: "Summarize", model: "mock-1")
        XCTAssertTrue(result.contains("Test summary content"))
    }

    func testMockProviderFailure() async {
        let provider = MockLLMProvider(shouldFail: true)
        do {
            _ = try await provider.summarize(transcript: "Hello", systemPrompt: "Summarize", model: "mock-1")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Mock failure"))
        }
    }

    // MARK: - Summary Store Round-Trip with Provider

    func testEndToEndSummarizeAndStore() async throws {
        let provider = MockLLMProvider()
        let store = SummaryStore(baseDirectory: tempDir)

        let transcript = "Speaker 1: Let's discuss the roadmap.\nSpeaker 2: Sure, I have updates."
        let systemPrompt = TemplateStore.builtInDefaults.first { $0.id == "meeting" }?.systemPrompt ?? "Summarize this."

        let responseText = try await provider.summarize(transcript: transcript, systemPrompt: systemPrompt, model: "mock-1")
        let sections = Template.parseSections(from: responseText)

        let summary = Summary(
            recordingFilename: "standup-2026-04-11.mp3",
            model: "mock-1",
            provider: "mock",
            templateUsed: "meeting",
            sections: sections
        )

        try await store.save(summary, mp3Filename: "standup-2026-04-11.mp3")

        // Verify round-trip
        try await store.loadAll()
        let loaded = await store.summary(for: "standup-2026-04-11.mp3")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.model, "mock-1")
        XCTAssertEqual(loaded?.provider, "mock")
        XCTAssertEqual(loaded?.templateUsed, "meeting")
        XCTAssertFalse(loaded?.sections.isEmpty ?? true)
    }

    // MARK: - Multiple Summaries (Queue Behavior)

    func testMultipleSummariesDontOverwrite() async throws {
        let store = SummaryStore(baseDirectory: tempDir)

        let summary1 = Summary(
            recordingFilename: "rec1.mp3",
            model: "mock-1", provider: "mock", templateUsed: "meeting",
            sections: [Summary.Section(heading: "Summary", content: "First recording.", items: nil)]
        )
        let summary2 = Summary(
            recordingFilename: "rec2.mp3",
            model: "mock-1", provider: "mock", templateUsed: "interview",
            sections: [Summary.Section(heading: "Summary", content: "Second recording.", items: nil)]
        )

        try await store.save(summary1, mp3Filename: "rec1.mp3")
        try await store.save(summary2, mp3Filename: "rec2.mp3")
        try await store.loadAll()

        let loaded1 = await store.summary(for: "rec1.mp3")
        let loaded2 = await store.summary(for: "rec2.mp3")
        XCTAssertNotNil(loaded1)
        XCTAssertNotNil(loaded2)
        XCTAssertEqual(loaded1?.templateUsed, "meeting")
        XCTAssertEqual(loaded2?.templateUsed, "interview")
    }

    func testResummarizeOverwritesPrevious() async throws {
        let store = SummaryStore(baseDirectory: tempDir)

        let summary1 = Summary(
            recordingFilename: "rec.mp3",
            model: "mock-1", provider: "mock", templateUsed: "meeting",
            sections: [Summary.Section(heading: "Summary", content: "Version 1.", items: nil)]
        )
        try await store.save(summary1, mp3Filename: "rec.mp3")

        let summary2 = Summary(
            recordingFilename: "rec.mp3",
            model: "mock-1", provider: "mock", templateUsed: "lecture",
            sections: [Summary.Section(heading: "Summary", content: "Version 2.", items: nil)]
        )
        try await store.save(summary2, mp3Filename: "rec.mp3")
        try await store.loadAll()

        let loaded = await store.summary(for: "rec.mp3")
        XCTAssertEqual(loaded?.templateUsed, "lecture")
        XCTAssertTrue(loaded?.sections.first?.content.contains("Version 2") ?? false)
    }

    // MARK: - Template Validation

    func testBuiltInTemplatesAllHaveSystemPrompts() {
        for template in TemplateStore.builtInDefaults {
            XCTAssertFalse(template.systemPrompt.isEmpty, "Template '\(template.name)' has empty systemPrompt")
            XCTAssertFalse(template.name.isEmpty, "Template has empty name")
            XCTAssertFalse(template.id.isEmpty, "Template '\(template.name)' has empty id")
        }
    }

    func testCustomPromptBuild() {
        let prompt = Template.buildCustomPrompt("Focus on action items only")
        XCTAssertTrue(prompt.contains("action items"))
    }
}
