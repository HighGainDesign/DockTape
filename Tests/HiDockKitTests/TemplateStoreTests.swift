import XCTest
@testable import HiDockKit

final class TemplateStoreTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemplateStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Template struct

    func testTemplateCodableRoundTrip() throws {
        let original = Template(
            id: "test-id",
            name: "Test",
            description: "A test template",
            promptText: "Summarize this.",
            isBuiltIn: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Template.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testUserTemplateHasUUIDId() {
        let t = Template.makeUserTemplate(name: "Mine", description: "desc", promptText: "prompt")
        XCTAssertEqual(t.id.count, 36)
        XCTAssertFalse(t.isBuiltIn)
    }

    // MARK: - Built-in templates

    func testBuiltInTemplatesExist() async {
        let store = TemplateStore(baseDirectory: tempDir)
        let builtIns = await store.builtInTemplates()
        XCTAssertEqual(builtIns.count, 7)
    }

    func testBuiltInTemplateNames() async {
        let store = TemplateStore(baseDirectory: tempDir)
        let names = await store.builtInTemplates().map(\.name)
        XCTAssertTrue(names.contains("Meeting/1:1"))
        XCTAssertTrue(names.contains("Lecture/Class"))
        XCTAssertTrue(names.contains("Interview"))
        XCTAssertTrue(names.contains("Memo"))
        XCTAssertTrue(names.contains("Discussion"))
        XCTAssertTrue(names.contains("Consultation"))
        XCTAssertTrue(names.contains("Coaching/Counseling"))
    }

    func testDefaultTemplateForMode() async {
        let store = TemplateStore(baseDirectory: tempDir)
        let mee = await store.defaultTemplate(forMode: "Mee")
        let pho = await store.defaultTemplate(forMode: "Pho")
        let wip = await store.defaultTemplate(forMode: "Wip")
        let rec = await store.defaultTemplate(forMode: "Rec")
        XCTAssertEqual(mee.id, "meeting")
        XCTAssertEqual(pho.id, "consultation")
        XCTAssertEqual(wip.id, "memo")
        XCTAssertEqual(rec.id, "meeting")
    }

    func testEachBuiltInHasPromptWithJSON() async {
        let store = TemplateStore(baseDirectory: tempDir)
        let builtIns = await store.builtInTemplates()
        for template in builtIns {
            XCTAssertTrue(
                template.systemPrompt.contains("JSON"),
                "Template '\(template.name)' systemPrompt does not contain 'JSON'"
            )
        }
    }

    // MARK: - CRUD

    func testAddUserTemplate() async {
        let store = TemplateStore(baseDirectory: tempDir)
        let t = Template.makeUserTemplate(name: "Custom", description: "desc", promptText: "prompt")
        await store.addUserTemplate(t)
        let all = await store.allTemplates()
        XCTAssertEqual(all.count, 8)
    }

    func testUpdateBuiltInOverride() async {
        let store = TemplateStore(baseDirectory: tempDir)
        var meeting = await store.template(forID: "meeting")!
        meeting.promptText = "My custom meeting prompt"
        await store.update(meeting)
        let updated = await store.template(forID: "meeting")!
        XCTAssertEqual(updated.promptText, "My custom meeting prompt")
    }

    func testResetBuiltInToDefault() async {
        let store = TemplateStore(baseDirectory: tempDir)
        let originalPrompt = TemplateStore.builtInDefaults.first(where: { $0.id == "meeting" })!.promptText
        var meeting = await store.template(forID: "meeting")!
        meeting.promptText = "Overridden prompt"
        await store.update(meeting)
        await store.resetToDefault(id: "meeting")
        let reset = await store.template(forID: "meeting")!
        XCTAssertEqual(reset.promptText, originalPrompt)
    }

    func testDeleteUserTemplate() async {
        let store = TemplateStore(baseDirectory: tempDir)
        let t = Template.makeUserTemplate(name: "Temp", description: "desc", promptText: "prompt")
        await store.addUserTemplate(t)
        await store.delete(id: t.id)
        let all = await store.allTemplates()
        XCTAssertEqual(all.count, 7)
        let deleted = await store.template(forID: t.id)
        XCTAssertNil(deleted)
    }

    // MARK: - Persistence

    func testPersistAndReload() async throws {
        let store1 = TemplateStore(baseDirectory: tempDir)

        // Add a user template
        let userT = Template.makeUserTemplate(name: "Saved", description: "persisted", promptText: "keep me")
        await store1.addUserTemplate(userT)

        // Override a built-in
        var meeting = await store1.template(forID: "meeting")!
        meeting.promptText = "Persisted meeting prompt"
        await store1.update(meeting)

        // Give save tasks time to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        // Load into a fresh store
        let store2 = TemplateStore(baseDirectory: tempDir)
        await store2.load()

        let reloaded = await store2.allTemplates()
        XCTAssertEqual(reloaded.count, 8)

        let reloadedMeeting = await store2.template(forID: "meeting")!
        XCTAssertEqual(reloadedMeeting.promptText, "Persisted meeting prompt")

        let reloadedUser = await store2.template(forID: userT.id)
        XCTAssertNotNil(reloadedUser)
        XCTAssertEqual(reloadedUser?.name, "Saved")
    }

    // MARK: - Migration

    func testMigrateFromUserDefaults() async throws {
        let suiteName = "com.docktape.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        defaults.set("Migrated meeting prompt", forKey: "templatePrompt_meeting")
        defaults.set("Migrated memo prompt", forKey: "templatePrompt_memo")

        let store = TemplateStore(baseDirectory: tempDir)
        await store.migrateFromUserDefaults(defaults)

        let meeting = await store.template(forID: "meeting")!
        XCTAssertEqual(meeting.promptText, "Migrated meeting prompt")

        let memo = await store.template(forID: "memo")!
        XCTAssertEqual(memo.promptText, "Migrated memo prompt")

        // Keys should be cleared
        XCTAssertNil(defaults.string(forKey: "templatePrompt_meeting"))
        XCTAssertNil(defaults.string(forKey: "templatePrompt_memo"))

        // Clean up suite
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Parsing

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
        let sections = Template.parseSections(from: json)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].heading, "Summary")
        XCTAssertEqual(sections[1].items?.count, 1)
    }

    func testParseSectionsFromCodeFencedJSON() throws {
        let response = """
        Here is the summary:
        ```json
        {"sections": [{"heading": "Summary", "content": "Fenced.", "items": null}]}
        ```
        Some trailing text.
        """
        let sections = Template.parseSections(from: response)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].content, "Fenced.")
    }

    func testExtractJSONWithPreamble() {
        let response = "Sure! Here's your JSON:\n{\"key\": \"value\"}\nHope that helps!"
        let extracted = Template.extractJSON(from: response)
        XCTAssertEqual(extracted, "{\"key\": \"value\"}")
    }

    func testParseSectionsFallbackOnInvalidJSON() throws {
        let rawText = "This is just plain text, not JSON."
        let sections = Template.parseSections(from: rawText)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].heading, "Summary")
        XCTAssertEqual(sections[0].content, rawText)
    }

    func testParseSectionsWithStringItems() throws {
        // LLMs sometimes return items as plain strings instead of objects
        let json = """
        {
            "sections": [
                {"heading": "Topics", "content": null, "items": ["Topic A", "Topic B", "Topic C"]},
                {"heading": "Perspectives", "content": null, "items": ["View 1", "View 2"]}
            ]
        }
        """
        let sections = Template.parseSections(from: json)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].heading, "Topics")
        XCTAssertEqual(sections[0].items?.count, 3)
        XCTAssertEqual(sections[0].items?[0].text, "Topic A")
        XCTAssertFalse(sections[0].items?[0].isCompleted ?? true)
    }

    func testBuildCustomPrompt() {
        let prompt = Template.buildCustomPrompt("Extract customer objections")
        XCTAssertTrue(prompt.contains("Extract customer objections"))
        XCTAssertTrue(prompt.contains("JSON"))
    }
}
