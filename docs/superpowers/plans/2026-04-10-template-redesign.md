# Template Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 4-case `SummaryTemplate` enum with a data-driven template system: 7 built-in templates, user-created templates, and a one-shot custom prompt.

**Architecture:** New `Template` struct and `TemplateStore` actor in HiDockKit replace the enum. App layer adds a Settings > Templates tab (split view) and updates the Summary tab picker. Migration from UserDefaults to JSON file storage.

**Tech Stack:** Swift, SwiftUI, macOS 14+, SPM, XCTest

---

## File Structure

### Create
- `Sources/HiDockKit/Summarization/Template.swift` — `Template` struct (data model)
- `Sources/HiDockKit/Summarization/TemplateStore.swift` — actor: load/save/migrate, built-in defaults
- `Sources/DockTape/Views/TemplateSettingsView.swift` — Settings > Templates tab (split view)
- `Tests/HiDockKitTests/TemplateStoreTests.swift` — tests for store, migration, CRUD

### Modify
- `Sources/HiDockKit/Summarization/SummaryTemplate.swift` — DELETE (replaced by Template + TemplateStore)
- `Sources/DockTape/State/SummarizationState.swift` — use `Template` instead of `SummaryTemplate`
- `Sources/DockTape/AppState.swift` — own `TemplateStore`, update `makeSettingsProvider`, update auto-summarize
- `Sources/DockTape/Views/SummaryTabView.swift` — new grouped picker with descriptions
- `Sources/DockTape/Views/AISettingsView.swift` — remove template editors, update auto-summarize picker
- `Sources/DockTape/Views/SettingsView.swift` — add Templates tab
- `Tests/HiDockKitTests/SummaryTemplateTests.swift` — DELETE (replaced by TemplateStoreTests)

---

### Task 1: Template Data Model

**Files:**
- Create: `Sources/HiDockKit/Summarization/Template.swift`
- Test: `Tests/HiDockKitTests/TemplateStoreTests.swift`

- [ ] **Step 1: Write failing test for Template struct**

```swift
// Tests/HiDockKitTests/TemplateStoreTests.swift
import XCTest
@testable import HiDockKit

final class TemplateStoreTests: XCTestCase {

    func testTemplateCodableRoundTrip() throws {
        let template = Template(
            id: "meeting",
            name: "Meeting/1:1",
            description: "Action items, decisions, and next steps",
            promptText: "You are summarizing a meeting transcript.",
            isBuiltIn: true
        )

        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(Template.self, from: data)

        XCTAssertEqual(decoded, template)
    }

    func testUserTemplateHasUUIDId() {
        let template = Template.makeUserTemplate(
            name: "Expert Network",
            description: "Knowledge extraction from expert calls",
            promptText: "Extract key claims and insights."
        )

        XCTAssertFalse(template.isBuiltIn)
        XCTAssertFalse(template.id.isEmpty)
        // UUID string is 36 chars
        XCTAssertEqual(template.id.count, 36)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TemplateStoreTests 2>&1 | tail -5`
Expected: FAIL — `Template` type not found

- [ ] **Step 3: Write Template struct**

```swift
// Sources/HiDockKit/Summarization/Template.swift
import Foundation

/// A summary template with a name, description, and LLM prompt.
public struct Template: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public var name: String
    public var description: String
    public var promptText: String
    public let isBuiltIn: Bool

    public init(id: String, name: String, description: String, promptText: String, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.description = description
        self.promptText = promptText
        self.isBuiltIn = isBuiltIn
    }

    /// Create a new user template with a UUID-based ID.
    public static func makeUserTemplate(name: String, description: String, promptText: String) -> Template {
        Template(id: UUID().uuidString, name: name, description: description, promptText: promptText, isBuiltIn: false)
    }

    /// The full system prompt sent to the LLM (prompt text + JSON schema).
    public var systemPrompt: String {
        if promptText.isEmpty { return "" }
        return "\(promptText)\n\n\(Self.jsonSchemaInstruction)"
    }

    /// Wrap a user-provided one-shot custom prompt with the JSON output schema.
    public static func buildCustomPrompt(_ userPrompt: String) -> String {
        """
        You are analyzing a transcript of an audio recording. The user wants:

        \(userPrompt)

        \(jsonSchemaInstruction)
        """
    }

    /// Parse the LLM response into Summary.Section array.
    /// Falls back to a single "Summary" section if JSON parsing fails.
    public static func parseSections(from response: String) throws -> [Summary.Section] {
        let jsonString = extractJSON(from: response)

        if let data = jsonString.data(using: .utf8) {
            do {
                let parsed = try JSONDecoder().decode(SectionsResponse.self, from: data)
                return parsed.sections.map { raw in
                    Summary.Section(
                        heading: raw.heading,
                        content: raw.content ?? "",
                        items: raw.items?.map { item in
                            Summary.Item(text: item.text, isCompleted: item.isCompleted ?? false)
                        }
                    )
                }
            } catch {
                // Fall through to fallback
            }
        }

        return [Summary.Section(heading: "Summary", content: response, items: nil)]
    }

    // MARK: - Private

    static let jsonSchemaInstruction = """
    Respond with ONLY a JSON object (no markdown fences, no extra text) in this exact format:
    {
        "sections": [
            {
                "heading": "Section Name",
                "content": "Markdown text for this section, or empty string if using items.",
                "items": null
            },
            {
                "heading": "Action Items",
                "content": "",
                "items": [
                    {"text": "Description of action item", "isCompleted": false}
                ]
            }
        ]
    }
    Use "items" array for list-style sections (action items, key points). Use "content" for narrative sections. Set items to null when using content.
    """

    /// Extract the JSON object from an LLM response, handling code fences,
    /// preamble text, and trailing commentary.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return trimmed
        }
        return String(trimmed[start...end])
    }
}

// MARK: - Response parsing types (private)

struct SectionsResponse: Decodable {
    let sections: [RawSection]
}

struct RawSection: Decodable {
    let heading: String
    let content: String?
    let items: [RawItem]?
}

struct RawItem: Decodable {
    let text: String
    let isCompleted: Bool?
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TemplateStoreTests 2>&1 | tail -5`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockKit/Summarization/Template.swift Tests/HiDockKitTests/TemplateStoreTests.swift
git commit -m "feat: add Template struct data model"
```

---

### Task 2: TemplateStore Actor with Built-in Templates

**Files:**
- Create: `Sources/HiDockKit/Summarization/TemplateStore.swift`
- Modify: `Tests/HiDockKitTests/TemplateStoreTests.swift`

- [ ] **Step 1: Write failing tests for TemplateStore**

Add to `TemplateStoreTests.swift`:

```swift
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemplateStoreTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testBuiltInTemplatesExist() async {
        let store = TemplateStore(baseDirectory: tempDir)
        let all = await store.allTemplates()
        XCTAssertEqual(all.filter(\.isBuiltIn).count, 7)
    }

    func testBuiltInTemplateNames() async {
        let store = TemplateStore(baseDirectory: tempDir)
        let names = await store.allTemplates().filter(\.isBuiltIn).map(\.name)
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
        let meeting = await store.defaultTemplate(forMode: "Mee")
        XCTAssertEqual(meeting.id, "meeting")
        let phone = await store.defaultTemplate(forMode: "Pho")
        XCTAssertEqual(phone.id, "consultation")
        let wip = await store.defaultTemplate(forMode: "Wip")
        XCTAssertEqual(wip.id, "memo")
        let rec = await store.defaultTemplate(forMode: "Rec")
        XCTAssertEqual(rec.id, "meeting")
    }

    func testEachBuiltInHasPromptWithJSON() async {
        let store = TemplateStore(baseDirectory: tempDir)
        for template in await store.allTemplates() where template.isBuiltIn {
            let prompt = template.systemPrompt
            XCTAssertTrue(prompt.contains("JSON"), "\(template.name) prompt missing JSON instruction")
            XCTAssertFalse(prompt.isEmpty, "\(template.name) prompt is empty")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TemplateStoreTests 2>&1 | tail -5`
Expected: FAIL — `TemplateStore` not found

- [ ] **Step 3: Write TemplateStore actor**

```swift
// Sources/HiDockKit/Summarization/TemplateStore.swift
import Foundation

/// Manages built-in and user-created summary templates.
/// Persists user templates and built-in overrides as `.templates.json`.
public actor TemplateStore {
    private let baseDirectory: URL
    private var builtInOverrides: [String: Template] = [:]  // keyed by built-in ID
    private var userTemplates: [Template] = []

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    // MARK: - Public API

    /// All templates: built-in (with overrides applied) + user-created.
    public func allTemplates() -> [Template] {
        let builtIns = Self.builtInDefaults.map { default_ in
            builtInOverrides[default_.id] ?? default_
        }
        return builtIns + userTemplates
    }

    /// Built-in templates only (with overrides applied).
    public func builtInTemplates() -> [Template] {
        Self.builtInDefaults.map { default_ in
            builtInOverrides[default_.id] ?? default_
        }
    }

    /// User-created templates only.
    public func userCreatedTemplates() -> [Template] {
        userTemplates
    }

    /// Find a template by ID.
    public func template(forID id: String) -> Template? {
        if let override = builtInOverrides[id] { return override }
        if let builtIn = Self.builtInDefaults.first(where: { $0.id == id }) { return builtIn }
        return userTemplates.first(where: { $0.id == id })
    }

    /// Default template for a device recording mode.
    public func defaultTemplate(forMode mode: String) -> Template {
        let id: String
        switch mode {
        case "Mee": id = "meeting"
        case "Pho": id = "consultation"
        case "Wip": id = "memo"
        default:    id = "meeting"
        }
        return template(forID: id) ?? Self.builtInDefaults[0]
    }

    // MARK: - CRUD

    /// Save a user-created template.
    public func addUserTemplate(_ template: Template) throws {
        userTemplates.append(template)
        try persist()
    }

    /// Update a template (built-in override or user template).
    public func update(_ template: Template) throws {
        if template.isBuiltIn {
            builtInOverrides[template.id] = template
        } else if let idx = userTemplates.firstIndex(where: { $0.id == template.id }) {
            userTemplates[idx] = template
        }
        try persist()
    }

    /// Delete a user-created template.
    public func delete(id: String) throws {
        userTemplates.removeAll(where: { $0.id == id })
        try persist()
    }

    /// Reset a built-in template to its default prompt and description.
    public func resetToDefault(id: String) throws {
        builtInOverrides.removeValue(forKey: id)
        try persist()
    }

    // MARK: - Persistence

    private var fileURL: URL {
        baseDirectory.appendingPathComponent(".templates.json")
    }

    /// Load templates from disk.
    public func load() throws {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let stored = try JSONDecoder().decode(StoredTemplates.self, from: data)
        builtInOverrides = Dictionary(
            stored.builtInOverrides.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        userTemplates = stored.userTemplates
    }

    private func persist() throws {
        let stored = StoredTemplates(
            builtInOverrides: Array(builtInOverrides.values),
            userTemplates: userTemplates
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        try data.write(to: fileURL)
    }

    // MARK: - Migration

    /// Migrate from UserDefaults-based template overrides (v1 format).
    public func migrateFromUserDefaults(_ defaults: UserDefaults = .standard) throws {
        let keyMap: [(key: String, id: String)] = [
            ("templatePrompt_meeting", "meeting"),
            ("templatePrompt_call", "consultation"),
            ("templatePrompt_memo", "memo"),
            ("templatePrompt_recording", "meeting"),  // old "recording" maps to "meeting"
        ]

        var migrated = false
        for (key, id) in keyMap {
            if let custom = defaults.string(forKey: key), !custom.isEmpty {
                if var template = Self.builtInDefaults.first(where: { $0.id == id }) {
                    template.promptText = custom
                    builtInOverrides[id] = template
                    migrated = true
                }
                defaults.removeObject(forKey: key)
            }
        }

        if migrated {
            try persist()
        }
    }

    // MARK: - Built-in Defaults

    static let builtInDefaults: [Template] = [
        Template(
            id: "meeting",
            name: "Meeting/1:1",
            description: "Action items, decisions, and next steps",
            promptText: """
            You are summarizing a meeting transcript. Produce a structured summary with these sections in this order:
            1. "Action Items" — extracted tasks and follow-ups as items
            2. "Summary" — 2-3 paragraph overview of what was discussed
            3. "Key Decisions" — decisions made, as items
            4. "Next Steps" — upcoming actions or milestones, as items
            """,
            isBuiltIn: true
        ),
        Template(
            id: "lecture",
            name: "Lecture/Class",
            description: "Key concepts and takeaways from educational content",
            promptText: """
            You are summarizing a lecture or class recording. Produce a structured summary with these sections:
            1. "Key Concepts" — main ideas and concepts taught, as items
            2. "Summary" — 2-3 paragraph overview of the material covered
            3. "Questions Raised" — questions asked by students or left open, as items
            4. "Takeaways" — key points to remember, as items
            """,
            isBuiltIn: true
        ),
        Template(
            id: "interview",
            name: "Interview",
            description: "Q&A pairs, key quotes, and assessment",
            promptText: """
            You are summarizing an interview transcript. Produce a structured summary with these sections:
            1. "Q&A" — key question-and-answer pairs, each as an item (format: "Q: ... A: ...")
            2. "Key Quotes" — notable or important statements, as items
            3. "Assessment" — overall impression and key observations in 1-2 paragraphs
            """,
            isBuiltIn: true
        ),
        Template(
            id: "memo",
            name: "Memo",
            description: "Brief gist of a voice note",
            promptText: """
            You are summarizing a voice memo / dictation. Produce a brief structured summary:
            1. "Gist" — 1-2 sentence summary of the memo content

            Keep it concise. This is a short personal note, not a meeting.
            """,
            isBuiltIn: true
        ),
        Template(
            id: "discussion",
            name: "Discussion",
            description: "Topics, perspectives, and notable quotes",
            promptText: """
            You are summarizing a multi-person discussion or conversation. Produce a structured summary with these sections:
            1. "Topics" — main topics discussed, as items
            2. "Perspectives" — key viewpoints expressed and by whom, as items
            3. "Notable Quotes" — important or memorable statements, as items
            """,
            isBuiltIn: true
        ),
        Template(
            id: "consultation",
            name: "Consultation",
            description: "Expert insights, recommendations, and follow-ups",
            promptText: """
            You are summarizing a consultation (e.g., doctor visit, legal advice, expert call, financial review). Produce a structured summary with these sections:
            1. "Key Insights" — important facts, findings, or advice given, as items
            2. "Recommendations" — specific suggestions or instructions, as items
            3. "Q&A" — key questions asked and answers given, as items
            4. "Follow-ups" — next steps, appointments, or actions to take, as items
            """,
            isBuiltIn: true
        ),
        Template(
            id: "coaching",
            name: "Coaching/Counseling",
            description: "Themes, observations, goals, and plan",
            promptText: """
            You are summarizing a coaching or counseling session. Produce a structured summary with these sections:
            1. "Themes" — recurring topics or emotional themes discussed, as items
            2. "Observations" — key insights or patterns noted in 1-2 paragraphs
            3. "Goals Discussed" — goals set, revisited, or adjusted, as items
            4. "Plan" — agreed next steps, exercises, or actions, as items
            """,
            isBuiltIn: true
        ),
    ]
}

// MARK: - Persistence Types

private struct StoredTemplates: Codable {
    let builtInOverrides: [Template]
    let userTemplates: [Template]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TemplateStoreTests 2>&1 | tail -5`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockKit/Summarization/TemplateStore.swift Tests/HiDockKitTests/TemplateStoreTests.swift
git commit -m "feat: add TemplateStore actor with 7 built-in templates"
```

---

### Task 3: TemplateStore CRUD and Persistence Tests

**Files:**
- Modify: `Tests/HiDockKitTests/TemplateStoreTests.swift`

- [ ] **Step 1: Write tests for CRUD and persistence**

Add to `TemplateStoreTests.swift`:

```swift
    func testAddUserTemplate() async throws {
        let store = TemplateStore(baseDirectory: tempDir)
        let custom = Template.makeUserTemplate(
            name: "Board Meeting",
            description: "Formal board meeting with motions and votes",
            promptText: "Summarize this board meeting with motions, votes, and resolutions."
        )
        try await store.addUserTemplate(custom)

        let all = await store.allTemplates()
        XCTAssertEqual(all.count, 8)  // 7 built-in + 1 user
        XCTAssertEqual(await store.userCreatedTemplates().count, 1)
    }

    func testUpdateBuiltInOverride() async throws {
        let store = TemplateStore(baseDirectory: tempDir)
        var meeting = await store.template(forID: "meeting")!
        let originalPrompt = meeting.promptText
        meeting.promptText = "Custom meeting prompt."
        try await store.update(meeting)

        let updated = await store.template(forID: "meeting")!
        XCTAssertEqual(updated.promptText, "Custom meeting prompt.")
        XCTAssertNotEqual(updated.promptText, originalPrompt)
    }

    func testResetBuiltInToDefault() async throws {
        let store = TemplateStore(baseDirectory: tempDir)
        var meeting = await store.template(forID: "meeting")!
        meeting.promptText = "Custom."
        try await store.update(meeting)
        try await store.resetToDefault(id: "meeting")

        let reset = await store.template(forID: "meeting")!
        XCTAssertTrue(reset.promptText.contains("Action Items"))
    }

    func testDeleteUserTemplate() async throws {
        let store = TemplateStore(baseDirectory: tempDir)
        let custom = Template.makeUserTemplate(name: "Temp", description: "", promptText: "test")
        try await store.addUserTemplate(custom)
        XCTAssertEqual(await store.userCreatedTemplates().count, 1)

        try await store.delete(id: custom.id)
        XCTAssertEqual(await store.userCreatedTemplates().count, 0)
    }

    func testPersistAndReload() async throws {
        let store = TemplateStore(baseDirectory: tempDir)
        let custom = Template.makeUserTemplate(name: "Saved", description: "Persisted", promptText: "test")
        try await store.addUserTemplate(custom)

        // Modify a built-in
        var memo = await store.template(forID: "memo")!
        memo.promptText = "Custom memo."
        try await store.update(memo)

        // Reload from disk
        let store2 = TemplateStore(baseDirectory: tempDir)
        try await store2.load()

        XCTAssertEqual(await store2.userCreatedTemplates().count, 1)
        XCTAssertEqual(await store2.userCreatedTemplates().first?.name, "Saved")
        let reloadedMemo = await store2.template(forID: "memo")!
        XCTAssertEqual(reloadedMemo.promptText, "Custom memo.")
    }

    func testMigrateFromUserDefaults() async throws {
        let defaults = UserDefaults(suiteName: "TemplateStoreTest-\(UUID().uuidString)")!
        defaults.set("My custom meeting prompt", forKey: "templatePrompt_meeting")
        defaults.set("My custom call prompt", forKey: "templatePrompt_call")

        let store = TemplateStore(baseDirectory: tempDir)
        try await store.migrateFromUserDefaults(defaults)

        let meeting = await store.template(forID: "meeting")!
        XCTAssertEqual(meeting.promptText, "My custom meeting prompt")
        // "call" migrates to "consultation"
        let consultation = await store.template(forID: "consultation")!
        XCTAssertEqual(consultation.promptText, "My custom call prompt")
        // UserDefaults keys should be cleared
        XCTAssertNil(defaults.string(forKey: "templatePrompt_meeting"))
        XCTAssertNil(defaults.string(forKey: "templatePrompt_call"))

        defaults.removePersistentDomain(forName: defaults.suiteName!)
    }
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter TemplateStoreTests 2>&1 | tail -5`
Expected: PASS (12 tests)

- [ ] **Step 3: Commit**

```bash
git add Tests/HiDockKitTests/TemplateStoreTests.swift
git commit -m "test: TemplateStore CRUD, persistence, and migration"
```

---

### Task 4: Wire TemplateStore into AppState

**Files:**
- Modify: `Sources/DockTape/AppState.swift`
- Modify: `Sources/DockTape/State/SummarizationState.swift`

- [ ] **Step 1: Add TemplateStore to AppState**

In `AppState.swift`, add `templateStore` property alongside other state objects:

```swift
var templateStore: TemplateStore
```

Initialize it in `init()` using the same `baseDirectory` as the library store. Call `templateStore.load()` and `templateStore.migrateFromUserDefaults()` during the startup `Task`.

- [ ] **Step 2: Update SummarizationState to use Template**

In `SummarizationState.swift`, change `QueueEntry.template` from `SummaryTemplate` to `Template`:

```swift
private struct QueueEntry {
    let recording: RecordingMetadata
    let template: Template
    let customPrompt: String?
}
```

Update `summarize()` parameter from `template: SummaryTemplate` to `template: Template`.

Update the prompt building in the `while` loop:

```swift
let systemPrompt: String
if entry.customPrompt != nil {
    systemPrompt = Template.buildCustomPrompt(entry.customPrompt!)
} else {
    systemPrompt = entry.template.systemPrompt
}
```

Update the `Summary` creation to use `entry.template.id` for `templateUsed`.

- [ ] **Step 3: Update AppState callers**

In `AppState.swift`:
- `contextMenuSummarize()`: use `await templateStore.defaultTemplate(forMode: rec.mode)` instead of `SummaryTemplate.forMode()`
- `autoSummarizeRecordings()`: read default template from store, pass `Template` to `summarizeRecordings()`
- `summarizeRecordings()`: change parameter type from `SummaryTemplate` to `Template`

- [ ] **Step 4: Build to verify compilation**

Run: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run tests**

Run: `swift test 2>&1 | grep "Executed" | tail -1`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/DockTape/AppState.swift Sources/DockTape/State/SummarizationState.swift
git commit -m "refactor: wire TemplateStore into AppState and SummarizationState"
```

---

### Task 5: Update Summary Tab Picker

**Files:**
- Modify: `Sources/DockTape/Views/SummaryTabView.swift`

- [ ] **Step 1: Replace SummaryTemplate picker with Template picker**

Remove `@State private var selectedTemplate: SummaryTemplate` and the `SummaryTemplate.forMode()` init.

Add:
```swift
@State private var selectedTemplate: Template?
@State private var templates: [Template] = []
```

Load templates from `state.templateStore` in `.task`:
```swift
.task {
    templates = await state.templateStore.allTemplates()
    selectedTemplate = await state.templateStore.defaultTemplate(forMode: recording.mode)
}
```

Replace the Picker with a grouped picker:
```swift
Picker("Template", selection: $selectedTemplate) {
    let builtIn = templates.filter(\.isBuiltIn)
    let user = templates.filter { !$0.isBuiltIn }

    Section("Built-in") {
        ForEach(builtIn) { t in
            Text(t.name).tag(Optional(t))
        }
    }
    if !user.isEmpty {
        Section("My Templates") {
            ForEach(user) { t in
                Text(t.name).tag(Optional(t))
            }
        }
    }
    Divider()
    Text("Custom prompt...").tag(nil as Template?)
}
.frame(width: 200)
```

Add the description bar below the picker:
```swift
if let template = selectedTemplate {
    HStack(spacing: 0) {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 3)
        Text(template.description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 4))
}
```

Handle `nil` selection (Custom prompt) by opening the custom prompt sheet.

- [ ] **Step 2: Update handleSummarize to use Template**

Change `handleSummarize()` to pass `selectedTemplate` (a `Template`) instead of `SummaryTemplate`:

```swift
state.summarizeRecordings(
    [recording],
    template: selectedTemplate!,
    customPrompt: isCustom ? customPromptText : nil,
    provider: provider,
    model: effectiveModel
)
```

- [ ] **Step 3: Update re-summarize template detection**

When a summary exists, map `summary.templateUsed` to the new template IDs. The old `"call"` maps to `"consultation"`, old `"recording"` maps to `"meeting"`.

- [ ] **Step 4: Build and test**

Run: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/DockTape/Views/SummaryTabView.swift
git commit -m "feat: grouped template picker with descriptions in Summary tab"
```

---

### Task 6: Settings > Templates Tab (Split View)

**Files:**
- Create: `Sources/DockTape/Views/TemplateSettingsView.swift`
- Modify: `Sources/DockTape/Views/SettingsView.swift`

- [ ] **Step 1: Create TemplateSettingsView**

```swift
// Sources/DockTape/Views/TemplateSettingsView.swift
import SwiftUI
import HiDockKit

struct TemplateSettingsView: View {
    @Bindable var state: AppState
    @State private var templates: [Template] = []
    @State private var selectedID: String?
    @State private var editName: String = ""
    @State private var editDescription: String = ""
    @State private var editPrompt: String = ""
    @State private var confirmDelete: Bool = false

    var body: some View {
        HSplitView {
            templateList
                .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)
            templateEditor
                .frame(minWidth: 250)
        }
        .task {
            await loadTemplates()
        }
    }

    // MARK: - Left Panel

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedID) {
                Section("Built-in") {
                    ForEach(templates.filter(\.isBuiltIn)) { t in
                        Text(t.name)
                            .tag(t.id)
                            .font(.body)
                    }
                }
                let user = templates.filter { !$0.isBuiltIn }
                Section("My Templates") {
                    ForEach(user) { t in
                        Text(t.name)
                            .tag(t.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    selectedID = t.id
                                    confirmDelete = true
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedID) { _, newID in
                loadEditor(for: newID)
            }

            Divider()
            HStack {
                Button {
                    addNewTemplate()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Template")
                Spacer()
            }
            .padding(8)
        }
        .alert("Delete Template?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("This template will be permanently deleted.")
        }
    }

    // MARK: - Right Panel

    @ViewBuilder
    private var templateEditor: some View {
        if let id = selectedID, let template = templates.first(where: { $0.id == id }) {
            Form {
                if template.isBuiltIn {
                    LabeledContent("Name", value: template.name)
                } else {
                    TextField("Name", text: $editName)
                        .onSubmit { saveEdits() }
                }

                TextField("Description", text: $editDescription)
                    .onSubmit { saveEdits() }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $editPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 150)
                        .border(.separator)
                }

                HStack {
                    Spacer()
                    if template.isBuiltIn {
                        let isModified = editPrompt != TemplateStore.builtInDefaults.first(where: { $0.id == id })?.promptText
                            || editDescription != TemplateStore.builtInDefaults.first(where: { $0.id == id })?.description
                        if isModified {
                            Button("Reset to Default") {
                                Task {
                                    try? await state.templateStore.resetToDefault(id: id)
                                    await loadTemplates()
                                    loadEditor(for: id)
                                }
                            }
                            .font(.caption)
                        }
                    } else {
                        Button("Delete Template", role: .destructive) {
                            confirmDelete = true
                        }
                        .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: editName) { _, _ in saveEditsDebounced() }
            .onChange(of: editDescription) { _, _ in saveEditsDebounced() }
            .onChange(of: editPrompt) { _, _ in saveEditsDebounced() }
        } else {
            ContentUnavailableView {
                Label("No Template Selected", systemImage: "doc.text")
            } description: {
                Text("Select a template to edit its prompt.")
            }
        }
    }

    // MARK: - Actions

    private func loadTemplates() async {
        templates = await state.templateStore.allTemplates()
        if selectedID == nil {
            selectedID = templates.first?.id
        }
    }

    private func loadEditor(for id: String?) {
        guard let id, let template = templates.first(where: { $0.id == id }) else { return }
        editName = template.name
        editDescription = template.description
        editPrompt = template.promptText
    }

    private func addNewTemplate() {
        let new = Template.makeUserTemplate(
            name: "New Template",
            description: "",
            promptText: ""
        )
        Task {
            try? await state.templateStore.addUserTemplate(new)
            await loadTemplates()
            selectedID = new.id
        }
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        Task {
            try? await state.templateStore.delete(id: id)
            selectedID = nil
            await loadTemplates()
        }
    }

    @State private var saveTask: Task<Void, Never>?

    private func saveEditsDebounced() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveEdits()
        }
    }

    private func saveEdits() {
        guard let id = selectedID else { return }
        guard var template = templates.first(where: { $0.id == id }) else { return }
        if !template.isBuiltIn { template.name = editName }
        template.description = editDescription
        template.promptText = editPrompt
        Task {
            try? await state.templateStore.update(template)
            await loadTemplates()
        }
    }
}
```

- [ ] **Step 2: Add Templates tab to SettingsView**

In `SettingsView.swift`, add the tab after "AI":

```swift
TemplateSettingsView(state: state)
    .tabItem { Label("Templates", systemImage: "doc.plaintext") }
```

- [ ] **Step 3: Build and test**

Run: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/DockTape/Views/TemplateSettingsView.swift Sources/DockTape/Views/SettingsView.swift
git commit -m "feat: Settings > Templates tab with split-view editor"
```

---

### Task 7: Clean Up AISettingsView and Remove Old SummaryTemplate

**Files:**
- Modify: `Sources/DockTape/Views/AISettingsView.swift`
- Delete: `Sources/HiDockKit/Summarization/SummaryTemplate.swift`
- Delete: `Tests/HiDockKitTests/SummaryTemplateTests.swift`

- [ ] **Step 1: Remove template editors from AISettingsView**

Remove the `@AppStorage` properties for `templatePrompt_meeting`, `templatePrompt_call`, `templatePrompt_memo`, `templatePrompt_recording`.

Remove the entire `Section("Templates")` block and the `templateEditor()` method.

Update the auto-summarize default template picker to use templates from `TemplateStore`:

```swift
Section("Automation") {
    Toggle("Auto-summarize after transcription", isOn: $autoSummarize)
        .disabled(providerName != "custom" && apiKey.isEmpty)

    if autoSummarize {
        Picker("Default template", selection: $autoSummarizeTemplate) {
            ForEach(TemplateStore.builtInDefaults) { t in
                Text(t.name).tag(t.id)
            }
        }
    }
}
```

- [ ] **Step 2: Delete old SummaryTemplate files**

```bash
git rm Sources/HiDockKit/Summarization/SummaryTemplate.swift
git rm Tests/HiDockKitTests/SummaryTemplateTests.swift
```

- [ ] **Step 3: Move parseSections and extractJSON tests to TemplateStoreTests**

Add to `TemplateStoreTests.swift`:

```swift
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
        let sections = try Template.parseSections(from: json)
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
        let sections = try Template.parseSections(from: response)
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
        let sections = try Template.parseSections(from: rawText)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].heading, "Summary")
        XCTAssertEqual(sections[0].content, rawText)
    }

    func testBuildCustomPrompt() {
        let prompt = Template.buildCustomPrompt("Extract customer objections")
        XCTAssertTrue(prompt.contains("Extract customer objections"))
        XCTAssertTrue(prompt.contains("JSON"))
    }
```

- [ ] **Step 4: Fix any remaining references to SummaryTemplate**

Search for `SummaryTemplate` across the codebase and replace with `Template` or `TemplateStore` as appropriate. Key files:
- `LLMProvider.swift` — no references expected
- `Summary.swift` — no references expected
- Any test files

- [ ] **Step 5: Build and run full test suite**

Run: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5`
Run: `swift test 2>&1 | grep "Executed" | tail -1`
Expected: BUILD SUCCEEDED, all tests pass

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove SummaryTemplate enum, consolidate into Template + TemplateStore"
```

---

### Task 8: Integration Testing and Final Polish

**Files:**
- All modified files from previous tasks

- [ ] **Step 1: Verify template picker in Summary tab**

Build the app: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build`

Verify:
- Template picker shows grouped sections (Built-in / My Templates / Custom prompt)
- Description bar appears below picker
- Auto-selection works based on device mode
- Custom prompt... opens sheet
- Summarize works with new templates

- [ ] **Step 2: Verify Settings > Templates tab**

Verify:
- Split view shows list on left, editor on right
- Built-in templates show read-only name, editable description and prompt
- Reset to Default restores original prompt
- Can create, edit, and delete user templates
- Changes persist across app restart

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | grep "Executed" | tail -1`
Expected: All tests pass (count should be ~140+)

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "polish: template redesign integration testing complete"
```
