# AI Transcript Summaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add LLM-powered transcript summaries via cloud API (Anthropic, OpenAI, OpenRouter) with mode-adaptive templates, structured sections, and checkable action items.

**Architecture:** New `Summarization/` module in HiDockKit with `Summary` data model, `SummaryStore` actor, `LLMProvider` protocol + 3 implementations, and `SummaryTemplate` prompts. App layer adds `SummarizationState`, `SummaryTabView`, `AISettingsView`, and wires auto-summarize into the existing transcription flow.

**Tech Stack:** Swift 5.10, macOS 14+, URLSession (no SDK dependencies), Security.framework (Keychain), SwiftUI

**Spec:** `docs/superpowers/specs/2026-04-09-ai-transcript-summaries-design.md`

---

### Task 1: Summary Data Model

**Files:**
- Create: `Sources/HiDockKit/Summarization/Summary.swift`
- Test: `Tests/HiDockKitTests/SummaryTests.swift`

- [ ] **Step 1: Write the test file**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SummaryTests 2>&1 | tail -5`
Expected: FAIL — `Summary` type does not exist

- [ ] **Step 3: Write the Summary model**

```swift
// Sources/HiDockKit/Summarization/Summary.swift
import Foundation

/// A structured AI-generated summary of a transcript.
public struct Summary: Codable, Sendable, Identifiable {
    public var id: String { recordingFilename }

    public let recordingFilename: String
    public let createdAt: Date
    public let model: String
    public let provider: String
    public let templateUsed: String
    public let customPrompt: String?
    public var sections: [Section]

    public init(
        recordingFilename: String,
        createdAt: Date = Date(),
        model: String,
        provider: String,
        templateUsed: String,
        customPrompt: String? = nil,
        sections: [Section]
    ) {
        self.recordingFilename = recordingFilename
        self.createdAt = createdAt
        self.model = model
        self.provider = provider
        self.templateUsed = templateUsed
        self.customPrompt = customPrompt
        self.sections = sections
    }

    public struct Section: Codable, Sendable, Identifiable {
        public let id: UUID
        public let heading: String
        public let content: String
        public let items: [Item]?

        public init(id: UUID = UUID(), heading: String, content: String, items: [Item]? = nil) {
            self.id = id
            self.heading = heading
            self.content = content
            self.items = items
        }
    }

    public struct Item: Codable, Sendable, Identifiable {
        public let id: UUID
        public let text: String
        public var isCompleted: Bool

        public init(id: UUID = UUID(), text: String, isCompleted: Bool = false) {
            self.id = id
            self.text = text
            self.isCompleted = isCompleted
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SummaryTests 2>&1 | tail -5`
Expected: PASS — all 3 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockKit/Summarization/Summary.swift Tests/HiDockKitTests/SummaryTests.swift
git commit -m "feat: add Summary data model with Codable sections and action items"
```

---

### Task 2: SummaryStore

**Files:**
- Create: `Sources/HiDockKit/Summarization/SummaryStore.swift`
- Test: `Tests/HiDockKitTests/SummaryStoreTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// Tests/HiDockKitTests/SummaryStoreTests.swift
import XCTest
@testable import HiDockKit

final class SummaryStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummaryStoreTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSaveAndLoad() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let summary = Summary(
            recordingFilename: "test.mp3",
            model: "claude-sonnet-4-6",
            provider: "anthropic",
            templateUsed: "meeting",
            sections: [
                Summary.Section(heading: "Summary", content: "A productive meeting.", items: nil)
            ]
        )

        try await store.save(summary, mp3Filename: "test.mp3")

        // Verify file on disk
        let fileURL = tempDir.appendingPathComponent("test.summary.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Verify cache hit
        let loaded = await store.summary(for: "test.mp3")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.sections.count, 1)
        XCTAssertEqual(loaded?.sections[0].content, "A productive meeting.")
    }

    func testLoadAll() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let s1 = Summary(
            recordingFilename: "a.mp3",
            model: "gpt-4o",
            provider: "openai",
            templateUsed: "call",
            sections: [Summary.Section(heading: "Synopsis", content: "Quick sync.", items: nil)]
        )
        let s2 = Summary(
            recordingFilename: "b.mp3",
            model: "gpt-4o",
            provider: "openai",
            templateUsed: "recording",
            sections: [Summary.Section(heading: "Summary", content: "Lecture notes.", items: nil)]
        )

        try await store.save(s1, mp3Filename: "a.mp3")
        try await store.save(s2, mp3Filename: "b.mp3")

        // Create a fresh store to test loadAll from disk
        let store2 = SummaryStore(baseDirectory: tempDir)
        try await store2.loadAll()

        let all = await store2.allSummaries()
        XCTAssertEqual(all.count, 2)
    }

    func testUpdateItemCompletion() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let itemID = UUID()
        let summary = Summary(
            recordingFilename: "tasks.mp3",
            model: "claude-sonnet-4-6",
            provider: "anthropic",
            templateUsed: "meeting",
            sections: [
                Summary.Section(
                    heading: "Action Items",
                    content: "",
                    items: [Summary.Item(id: itemID, text: "Send email", isCompleted: false)]
                )
            ]
        )

        try await store.save(summary, mp3Filename: "tasks.mp3")
        try await store.toggleItem(itemID, inSummaryFor: "tasks.mp3")

        let updated = await store.summary(for: "tasks.mp3")
        XCTAssertTrue(updated?.sections[0].items?[0].isCompleted ?? false)

        // Verify persisted to disk
        let store2 = SummaryStore(baseDirectory: tempDir)
        try await store2.loadAll()
        let reloaded = await store2.summary(for: "tasks.mp3")
        XCTAssertTrue(reloaded?.sections[0].items?[0].isCompleted ?? false)
    }

    func testHasSummary() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let has = await store.hasSummary(for: "nonexistent.mp3")
        XCTAssertFalse(has)

        let summary = Summary(
            recordingFilename: "exists.mp3",
            model: "gpt-4o",
            provider: "openai",
            templateUsed: "memo",
            sections: [Summary.Section(heading: "Gist", content: "Quick note.", items: nil)]
        )
        try await store.save(summary, mp3Filename: "exists.mp3")

        let hasNow = await store.hasSummary(for: "exists.mp3")
        XCTAssertTrue(hasNow)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SummaryStoreTests 2>&1 | tail -5`
Expected: FAIL — `SummaryStore` does not exist

- [ ] **Step 3: Write SummaryStore**

```swift
// Sources/HiDockKit/Summarization/SummaryStore.swift
import Foundation

/// Persists summaries as JSON files alongside recordings.
/// Each summary is stored as `{recording_basename}.summary.json`.
public actor SummaryStore {
    private let baseDirectory: URL
    private var cache: [String: Summary] = [:]  // keyed by MP3 filename

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Load all summaries from disk (recursively, including subfolders).
    public func loadAll() throws {
        cache.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return }

        guard let enumerator = fm.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let basePath = baseDirectory.resolvingSymlinksInPath().path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for case let file as URL in enumerator {
            guard file.pathExtension == "json",
                  file.lastPathComponent.contains(".summary.") else { continue }
            do {
                let data = try Data(contentsOf: file)
                let summary = try decoder.decode(Summary.self, from: data)
                let resolvedPath = file.resolvingSymlinksInPath().path
                let relativePath = resolvedPath.hasPrefix(basePrefix)
                    ? String(resolvedPath.dropFirst(basePrefix.count))
                    : file.lastPathComponent
                let mp3Key = relativePath.replacingOccurrences(of: ".summary.json", with: ".mp3")
                cache[mp3Key] = summary
            } catch {
                continue  // skip corrupt files
            }
        }
    }

    /// Save a summary, keyed by MP3 filename.
    public func save(_ summary: Summary, mp3Filename: String) throws {
        let url = fileURL(for: mp3Filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        try data.write(to: url)
        cache[mp3Filename] = summary
    }

    /// Get a summary for a recording.
    public func summary(for mp3Filename: String) -> Summary? {
        cache[mp3Filename]
    }

    /// Check if a summary exists.
    public func hasSummary(for mp3Filename: String) -> Bool {
        cache[mp3Filename] != nil
    }

    /// Toggle an action item's completion state and persist.
    public func toggleItem(_ itemID: UUID, inSummaryFor mp3Filename: String) throws {
        guard var summary = cache[mp3Filename] else { return }
        for sectionIndex in summary.sections.indices {
            guard var items = summary.sections[sectionIndex].items else { continue }
            if let itemIndex = items.firstIndex(where: { $0.id == itemID }) {
                items[itemIndex].isCompleted.toggle()
                summary.sections[sectionIndex] = Summary.Section(
                    id: summary.sections[sectionIndex].id,
                    heading: summary.sections[sectionIndex].heading,
                    content: summary.sections[sectionIndex].content,
                    items: items
                )
                try save(summary, mp3Filename: mp3Filename)
                return
            }
        }
    }

    /// Delete a summary.
    public func delete(for mp3Filename: String) throws {
        let url = fileURL(for: mp3Filename)
        try? FileManager.default.removeItem(at: url)
        cache.removeValue(forKey: mp3Filename)
    }

    /// All cached summaries.
    public func allSummaries() -> [Summary] {
        Array(cache.values)
    }

    /// Re-key a summary after recording rename.
    public func rename(from oldMp3: String, to newMp3: String) {
        guard let summary = cache.removeValue(forKey: oldMp3) else { return }
        cache[newMp3] = summary
    }

    private func fileURL(for mp3Filename: String) -> URL {
        let basename = (mp3Filename as NSString).deletingPathExtension
        return baseDirectory.appendingPathComponent("\(basename).summary.json")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SummaryStoreTests 2>&1 | tail -5`
Expected: PASS — all 4 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockKit/Summarization/SummaryStore.swift Tests/HiDockKitTests/SummaryStoreTests.swift
git commit -m "feat: add SummaryStore actor for disk persistence and caching"
```

---

### Task 3: KeychainHelper

**Files:**
- Create: `Sources/HiDockKit/Summarization/KeychainHelper.swift`
- Test: `Tests/HiDockKitTests/KeychainHelperTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// Tests/HiDockKitTests/KeychainHelperTests.swift
import XCTest
@testable import HiDockKit

final class KeychainHelperTests: XCTestCase {
    let service = "com.docktape.tests.keychain-\(UUID().uuidString)"

    override func tearDown() {
        // Clean up any test keys
        KeychainHelper.delete(service: service, account: "testkey")
        KeychainHelper.delete(service: service, account: "overwrite")
    }

    func testSaveAndRead() throws {
        try KeychainHelper.save(key: "sk-test-12345", service: service, account: "testkey")
        let read = KeychainHelper.read(service: service, account: "testkey")
        XCTAssertEqual(read, "sk-test-12345")
    }

    func testReadMissing() {
        let read = KeychainHelper.read(service: service, account: "nonexistent")
        XCTAssertNil(read)
    }

    func testOverwrite() throws {
        try KeychainHelper.save(key: "first", service: service, account: "overwrite")
        try KeychainHelper.save(key: "second", service: service, account: "overwrite")
        let read = KeychainHelper.read(service: service, account: "overwrite")
        XCTAssertEqual(read, "second")
    }

    func testDelete() throws {
        try KeychainHelper.save(key: "deleteme", service: service, account: "testkey")
        KeychainHelper.delete(service: service, account: "testkey")
        let read = KeychainHelper.read(service: service, account: "testkey")
        XCTAssertNil(read)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KeychainHelperTests 2>&1 | tail -5`
Expected: FAIL — `KeychainHelper` does not exist

- [ ] **Step 3: Write KeychainHelper**

```swift
// Sources/HiDockKit/Summarization/KeychainHelper.swift
import Foundation
import Security

/// Minimal Keychain wrapper for storing API keys.
public enum KeychainHelper {

    public static func save(key: String, service: String, account: String) throws {
        let data = Data(key.utf8)

        // Delete existing item first (update = delete + add)
        delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    public enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Keychain save failed with status \(status)"
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter KeychainHelperTests 2>&1 | tail -5`
Expected: PASS — all 4 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockKit/Summarization/KeychainHelper.swift Tests/HiDockKitTests/KeychainHelperTests.swift
git commit -m "feat: add KeychainHelper for secure API key storage"
```

---

### Task 4: LLMProvider Protocol and Implementations

**Files:**
- Create: `Sources/HiDockKit/Summarization/LLMProvider.swift`
- Create: `Sources/HiDockKit/Summarization/AnthropicProvider.swift`
- Create: `Sources/HiDockKit/Summarization/OpenAIProvider.swift`
- Create: `Sources/HiDockKit/Summarization/OpenRouterProvider.swift`
- Test: `Tests/HiDockKitTests/LLMProviderTests.swift`

- [ ] **Step 1: Write the test file**

Tests use a mock URLProtocol to avoid real API calls.

```swift
// Tests/HiDockKitTests/LLMProviderTests.swift
import XCTest
@testable import HiDockKit

final class LLMProviderTests: XCTestCase {

    // MARK: - Anthropic response parsing

    func testAnthropicParseResponse() throws {
        let json = """
        {
            "content": [{"type": "text", "text": "Here is the summary."}],
            "model": "claude-sonnet-4-6",
            "role": "assistant"
        }
        """
        let data = Data(json.utf8)
        let text = try AnthropicProvider.extractText(from: data)
        XCTAssertEqual(text, "Here is the summary.")
    }

    func testAnthropicParseErrorResponse() {
        let json = """
        {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try AnthropicProvider.extractText(from: data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid x-api-key"))
        }
    }

    // MARK: - OpenAI response parsing (also covers OpenRouter)

    func testOpenAIParseResponse() throws {
        let json = """
        {
            "choices": [{"message": {"role": "assistant", "content": "Summary text here."}}]
        }
        """
        let data = Data(json.utf8)
        let text = try OpenAIProvider.extractText(from: data)
        XCTAssertEqual(text, "Summary text here.")
    }

    func testOpenAIParseErrorResponse() {
        let json = """
        {"error": {"message": "Invalid API key", "type": "invalid_request_error"}}
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try OpenAIProvider.extractText(from: data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid API key"))
        }
    }

    // MARK: - Provider properties

    func testAnthropicProviderDefaults() {
        let provider = AnthropicProvider(apiKey: "test")
        XCTAssertEqual(provider.name, "Anthropic")
        XCTAssertFalse(provider.availableModels.isEmpty)
        XCTAssertTrue(provider.availableModels.contains(provider.defaultModel))
    }

    func testOpenAIProviderDefaults() {
        let provider = OpenAIProvider(apiKey: "test")
        XCTAssertEqual(provider.name, "OpenAI")
        XCTAssertFalse(provider.availableModels.isEmpty)
        XCTAssertTrue(provider.availableModels.contains(provider.defaultModel))
    }

    func testOpenRouterProviderDefaults() {
        let provider = OpenRouterProvider(apiKey: "test")
        XCTAssertEqual(provider.name, "OpenRouter")
        XCTAssertFalse(provider.availableModels.isEmpty)
        XCTAssertTrue(provider.availableModels.contains(provider.defaultModel))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LLMProviderTests 2>&1 | tail -5`
Expected: FAIL — types do not exist

- [ ] **Step 3: Write LLMProvider protocol**

```swift
// Sources/HiDockKit/Summarization/LLMProvider.swift
import Foundation

/// A cloud LLM provider that can generate text from a prompt.
public protocol LLMProvider: Sendable {
    var name: String { get }
    var defaultModel: String { get }
    var availableModels: [String] { get }

    /// Send a summarization request and return the response text.
    func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String

    /// Verify the API key is valid with a minimal request.
    func verifyKey() async throws
}

/// Errors from LLM API calls.
public enum LLMError: LocalizedError {
    case apiError(String)
    case networkError(Error)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .apiError(let msg): return msg
        case .networkError(let err): return err.localizedDescription
        case .invalidResponse: return "Invalid response from API"
        }
    }
}
```

- [ ] **Step 4: Write AnthropicProvider**

```swift
// Sources/HiDockKit/Summarization/AnthropicProvider.swift
import Foundation

/// Anthropic Messages API provider.
public struct AnthropicProvider: LLMProvider, Sendable {
    public let name = "Anthropic"
    public let defaultModel = "claude-sonnet-4-6"
    public let availableModels = [
        "claude-sonnet-4-6",
        "claude-haiku-4-5-20251001",
    ]

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [["role": "user", "content": transcript]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        return try Self.extractText(from: data)
    }

    public func verifyKey() async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        // If we get a valid response (even a short one), the key works
        _ = try Self.extractText(from: data)
    }

    /// Extract text content from Anthropic Messages API response.
    /// Public for testing.
    public static func extractText(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        // Check for error response
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw LLMError.apiError(message)
        }

        guard let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw LLMError.invalidResponse
        }
        return text
    }
}
```

- [ ] **Step 5: Write OpenAIProvider**

```swift
// Sources/HiDockKit/Summarization/OpenAIProvider.swift
import Foundation

/// OpenAI Chat Completions API provider.
public struct OpenAIProvider: LLMProvider, Sendable {
    public let name = "OpenAI"
    public let defaultModel = "gpt-4o"
    public let availableModels = [
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4.1",
        "gpt-4.1-mini",
    ]

    private let apiKey: String
    private let session: URLSession
    let baseURL: String

    public init(apiKey: String, baseURL: String = "https://api.openai.com", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(baseURL)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        return try Self.extractText(from: data)
    }

    public func verifyKey() async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw LLMError.apiError("Invalid API key")
        }
        // Any 2xx means the key is valid
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "Verification failed"
            throw LLMError.apiError(msg)
        }
    }

    /// Extract text content from OpenAI Chat Completions response.
    /// Public for testing.
    public static func extractText(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw LLMError.apiError(message)
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        return content
    }
}
```

- [ ] **Step 6: Write OpenRouterProvider**

```swift
// Sources/HiDockKit/Summarization/OpenRouterProvider.swift
import Foundation

/// OpenRouter API provider (OpenAI-compatible format).
public struct OpenRouterProvider: LLMProvider, Sendable {
    public let name = "OpenRouter"
    public let defaultModel = "anthropic/claude-sonnet-4-6"
    public let availableModels = [
        "anthropic/claude-sonnet-4-6",
        "anthropic/claude-haiku-4-5-20251001",
        "openai/gpt-4o",
        "openai/gpt-4o-mini",
        "google/gemini-2.5-pro",
        "google/gemini-2.5-flash",
    ]

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("https://github.com/anandman/docktape", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("DockTape", forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        return try OpenAIProvider.extractText(from: data)  // same response format
    }

    public func verifyKey() async throws {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/key")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.apiError("Invalid OpenRouter API key")
        }
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter LLMProviderTests 2>&1 | tail -10`
Expected: PASS — all 7 tests pass

- [ ] **Step 8: Commit**

```bash
git add Sources/HiDockKit/Summarization/LLMProvider.swift \
    Sources/HiDockKit/Summarization/AnthropicProvider.swift \
    Sources/HiDockKit/Summarization/OpenAIProvider.swift \
    Sources/HiDockKit/Summarization/OpenRouterProvider.swift \
    Tests/HiDockKitTests/LLMProviderTests.swift
git commit -m "feat: add LLMProvider protocol with Anthropic, OpenAI, OpenRouter implementations"
```

---

### Task 5: Summary Templates and Prompt Builder

**Files:**
- Create: `Sources/HiDockKit/Summarization/SummaryTemplate.swift`
- Test: `Tests/HiDockKitTests/SummaryTemplateTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// Tests/HiDockKitTests/SummaryTemplateTests.swift
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
        // Memo prompt should not mention action items
        XCTAssertFalse(prompt.contains("Action Items"))
    }

    func testBuildCustomPrompt() {
        let prompt = SummaryTemplate.buildCustomPrompt("Extract customer objections")
        XCTAssertTrue(prompt.contains("Extract customer objections"))
        XCTAssertTrue(prompt.contains("JSON"))  // must still include JSON schema
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SummaryTemplateTests 2>&1 | tail -5`
Expected: FAIL — `SummaryTemplate` does not exist

- [ ] **Step 3: Write SummaryTemplate**

```swift
// Sources/HiDockKit/Summarization/SummaryTemplate.swift
import Foundation

/// Mode-adaptive prompt templates for transcript summarization.
public enum SummaryTemplate: String, Codable, CaseIterable, Sendable {
    case meeting
    case call
    case memo
    case recording
    case custom

    /// Map a RecordingMetadata.mode string to a template.
    public static func forMode(_ mode: String) -> SummaryTemplate {
        switch mode {
        case "Mee": return .meeting
        case "Pho": return .call
        case "Wip": return .memo
        default:    return .recording
        }
    }

    /// The system prompt for this template.
    public var systemPrompt: String {
        switch self {
        case .meeting: return Self.meetingPrompt
        case .call:    return Self.callPrompt
        case .memo:    return Self.memoPrompt
        case .recording: return Self.recordingPrompt
        case .custom:  return ""  // Custom prompts are built via buildCustomPrompt()
        }
    }

    /// Wrap a user-provided custom prompt with the JSON output schema.
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
        // Try to extract JSON from the response (may be wrapped in markdown code fences)
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

        // Fallback: treat entire response as a single summary section
        return [Summary.Section(heading: "Summary", content: response, items: nil)]
    }

    // MARK: - Private

    private static let jsonSchemaInstruction = """
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

    private static let meetingPrompt = """
    You are summarizing a meeting transcript. Produce a structured summary with these sections in this order:
    1. "Action Items" — extracted tasks and follow-ups as items
    2. "Summary" — 2-3 paragraph overview of what was discussed
    3. "Key Decisions" — decisions made, as items
    4. "Next Steps" — upcoming actions or milestones, as items

    \(jsonSchemaInstruction)
    """

    private static let callPrompt = """
    You are summarizing a phone call transcript. Produce a structured summary with these sections in this order:
    1. "Action Items" — tasks or follow-ups agreed upon, as items
    2. "Synopsis" — 1-2 paragraph overview of the call
    3. "Commitments" — what each party committed to, as items
    4. "Follow-ups" — next steps or scheduled actions, as items

    \(jsonSchemaInstruction)
    """

    private static let memoPrompt = """
    You are summarizing a voice memo / dictation. Produce a brief structured summary:
    1. "Gist" — 1-2 sentence summary of the memo content

    Keep it concise. This is a short personal note, not a meeting.

    \(jsonSchemaInstruction)
    """

    private static let recordingPrompt = """
    You are summarizing a general audio recording transcript. Produce a structured summary:
    1. "Summary" — 2-3 paragraph overview
    2. "Key Points" — important points, as items

    \(jsonSchemaInstruction)
    """

    /// Strip markdown code fences if present and extract JSON.
    private static func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove ```json ... ``` fences
        if cleaned.hasPrefix("```") {
            if let endFence = cleaned.range(of: "\n") {
                cleaned = String(cleaned[endFence.upperBound...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

// MARK: - Response parsing types (private)

private struct SectionsResponse: Decodable {
    let sections: [RawSection]
}

private struct RawSection: Decodable {
    let heading: String
    let content: String?
    let items: [RawItem]?
}

private struct RawItem: Decodable {
    let text: String
    let isCompleted: Bool?
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SummaryTemplateTests 2>&1 | tail -5`
Expected: PASS — all 6 tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockKit/Summarization/SummaryTemplate.swift Tests/HiDockKitTests/SummaryTemplateTests.swift
git commit -m "feat: add SummaryTemplate with mode-adaptive prompts and JSON response parsing"
```

---

### Task 6: SummarizationState

**Files:**
- Create: `Sources/DockTape/State/SummarizationState.swift`
- Modify: `Sources/DockTape/AppState.swift`

This task cannot be unit-tested in `HiDockKitTests` because it depends on SwiftUI (`@Observable`). We'll verify it compiles and integrates correctly via xcodebuild.

- [ ] **Step 1: Write SummarizationState**

```swift
// Sources/DockTape/State/SummarizationState.swift
import SwiftUI
import HiDockKit

/// Manages AI summarization queue and progress.
@Observable
@MainActor
final class SummarizationState {
    var summarizingFile: String?
    var phase: String = ""
    var queue: [RecordingMetadata] = []
    var queueIndex: Int = 0

    let summaryStore: SummaryStore

    private var summarizationTask: Task<Void, Never>?

    var isSummarizing: Bool { summarizingFile != nil }

    init(summaryStore: SummaryStore) {
        self.summaryStore = summaryStore
    }

    func summarize(
        recordings: [RecordingMetadata],
        template: SummaryTemplate,
        customPrompt: String?,
        provider: LLMProvider,
        model: String,
        transcriptStore: TranscriptStore,
        onError: @escaping (String) -> Void,
        onComplete: @escaping () -> Void
    ) {
        let newRecs = recordings.filter { rec in !queue.contains(where: { $0.filename == rec.filename }) }
        queue.append(contentsOf: newRecs)

        guard summarizationTask == nil else { return }

        summarizationTask = Task {
            while queueIndex < queue.count {
                let rec = queue[queueIndex]
                summarizingFile = rec.filename
                phase = "Summarizing with \(provider.name)..."

                do {
                    guard let transcript = await transcriptStore.transcript(for: rec.filename) else {
                        onError("No transcript found for \(rec.displayTitle)")
                        queueIndex += 1
                        continue
                    }

                    let transcriptText = transcript.plainText(includeSpeakers: true)
                    let effectiveTemplate = template == .custom
                        ? template
                        : SummaryTemplate.forMode(rec.mode)
                    let systemPrompt = effectiveTemplate == .custom
                        ? SummaryTemplate.buildCustomPrompt(customPrompt ?? "")
                        : effectiveTemplate.systemPrompt

                    let responseText = try await provider.summarize(
                        transcript: transcriptText,
                        systemPrompt: systemPrompt,
                        model: model
                    )

                    try Task.checkCancellation()

                    let sections = try SummaryTemplate.parseSections(from: responseText)
                    let summary = Summary(
                        recordingFilename: rec.filename,
                        model: model,
                        provider: provider.name.lowercased(),
                        templateUsed: effectiveTemplate.rawValue,
                        customPrompt: effectiveTemplate == .custom ? customPrompt : nil,
                        sections: sections
                    )

                    try await summaryStore.save(summary, mp3Filename: rec.filename)
                    queueIndex += 1
                } catch is CancellationError {
                    resetState()
                    return
                } catch {
                    onError("Summarization failed: \(error.localizedDescription)")
                    queueIndex += 1
                }
            }

            resetState()
            onComplete()
        }
    }

    func cancel() {
        summarizationTask?.cancel()
        resetState()
    }

    private func resetState() {
        summarizingFile = nil
        phase = ""
        queue = []
        queueIndex = 0
        summarizationTask = nil
    }
}
```

- [ ] **Step 2: Wire SummarizationState into AppState**

Add to `Sources/DockTape/AppState.swift`:

In the properties section, after `var transcription: TranscriptionState`, add:
```swift
var summarization: SummarizationState
```

In `init()`, after the line `self.transcription = TranscriptionState(transcriptStore: transcriptStore)`, add:
```swift
let summaryStore = SummaryStore(baseDirectory: store.baseDirectory)
self.summarization = SummarizationState(summaryStore: summaryStore)
```

In `setup()`, after `try await library.setup()`, add:
```swift
try await summarization.summaryStore.loadAll()
```

Add a new cross-cutting method after `transcribeRecordings`:
```swift
func summarizeRecordings(
    _ recs: [RecordingMetadata],
    template: SummaryTemplate = .recording,
    customPrompt: String? = nil,
    provider: LLMProvider,
    model: String
) {
    summarization.summarize(
        recordings: recs,
        template: template,
        customPrompt: customPrompt,
        provider: provider,
        model: model,
        transcriptStore: transcription.transcriptStore,
        onError: { [weak self] msg in self?.errorMessage = msg },
        onComplete: {}
    )
}
```

In `renameRecording`, after the transcription rename line, add:
```swift
await summarization.summaryStore.rename(from: rec.filename, to: newFilename)
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/DockTape/State/SummarizationState.swift Sources/DockTape/AppState.swift
git commit -m "feat: add SummarizationState and wire into AppState"
```

---

### Task 7: AI Settings Tab

**Files:**
- Create: `Sources/DockTape/Views/AISettingsView.swift`
- Modify: `Sources/DockTape/Views/SettingsView.swift`

- [ ] **Step 1: Write AISettingsView**

```swift
// Sources/DockTape/Views/AISettingsView.swift
import SwiftUI
import HiDockKit

struct AISettingsView: View {
    @AppStorage("aiProvider") private var providerName: String = "anthropic"
    @AppStorage("aiModel") private var selectedModel: String = "claude-sonnet-4-6"
    @AppStorage("autoSummarize") private var autoSummarize: Bool = false
    @AppStorage("autoSummarizeTemplate") private var autoSummarizeTemplate: String = "recording"

    @State private var apiKey: String = ""
    @State private var isVerifying: Bool = false
    @State private var verifyResult: VerifyResult?

    private let keychainService = "com.docktape.ai"

    enum VerifyResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $providerName) {
                    Text("Anthropic").tag("anthropic")
                    Text("OpenAI").tag("openai")
                    Text("OpenRouter").tag("openrouter")
                }
                .onChange(of: providerName) { _, newValue in
                    // Load key for new provider
                    apiKey = KeychainHelper.read(
                        service: keychainService,
                        account: newValue
                    ) ?? ""
                    // Reset model to provider default
                    selectedModel = makeProvider(name: newValue, apiKey: "")?.defaultModel ?? ""
                    verifyResult = nil
                }

                Picker("Model", selection: $selectedModel) {
                    let provider = makeProvider(name: providerName, apiKey: "")
                    ForEach(provider?.availableModels ?? [], id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }

            Section("API Key") {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveKey() }

                HStack {
                    Button("Save Key") { saveKey() }
                        .disabled(apiKey.isEmpty)

                    Button("Verify") { verifyKey() }
                        .disabled(apiKey.isEmpty || isVerifying)

                    if isVerifying {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()

                    if let result = verifyResult {
                        switch result {
                        case .success:
                            Label("Valid", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Section("Automation") {
                Toggle("Auto-summarize after transcription", isOn: $autoSummarize)
                    .disabled(apiKey.isEmpty)

                if autoSummarize {
                    Picker("Default template", selection: $autoSummarizeTemplate) {
                        Text("Meeting").tag("meeting")
                        Text("Call").tag("call")
                        Text("Memo").tag("memo")
                        Text("Recording").tag("recording")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = KeychainHelper.read(
                service: keychainService,
                account: providerName
            ) ?? ""
        }
    }

    private func saveKey() {
        try? KeychainHelper.save(
            key: apiKey,
            service: keychainService,
            account: providerName
        )
        verifyResult = nil
    }

    private func verifyKey() {
        guard let provider = makeProvider(name: providerName, apiKey: apiKey) else { return }
        isVerifying = true
        verifyResult = nil
        Task {
            do {
                try await provider.verifyKey()
                verifyResult = .success
            } catch {
                verifyResult = .failure(error.localizedDescription)
            }
            isVerifying = false
        }
    }

    private func makeProvider(name: String, apiKey: String) -> (any LLMProvider)? {
        switch name {
        case "anthropic": return AnthropicProvider(apiKey: apiKey)
        case "openai":    return OpenAIProvider(apiKey: apiKey)
        case "openrouter": return OpenRouterProvider(apiKey: apiKey)
        default: return nil
        }
    }
}
```

- [ ] **Step 2: Add AI tab to SettingsView**

In `Sources/DockTape/Views/SettingsView.swift`, add the AI tab after the General tab:

After the line:
```swift
            generalSettings
                .tabItem { Label("General", systemImage: "gear") }
```

Add:
```swift
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
```

- [ ] **Step 3: Build to verify**

Run: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/DockTape/Views/AISettingsView.swift Sources/DockTape/Views/SettingsView.swift
git commit -m "feat: add AI settings tab with provider/key/model config"
```

---

### Task 8: Summary Tab View

**Files:**
- Create: `Sources/DockTape/Views/SummaryTabView.swift`
- Modify: `Sources/DockTape/Views/DetailPane.swift`

- [ ] **Step 1: Write SummaryTabView**

```swift
// Sources/DockTape/Views/SummaryTabView.swift
import SwiftUI
import HiDockKit

struct SummaryTabView: View {
    @Bindable var state: AppState
    let recording: RecordingMetadata

    @AppStorage("aiProvider") private var providerName: String = "anthropic"
    @AppStorage("aiModel") private var selectedModel: String = "claude-sonnet-4-6"

    @State private var summary: Summary?
    @State private var selectedTemplate: SummaryTemplate
    @State private var showCustomPromptSheet = false
    @State private var customPromptText = ""
    @State private var showAPIKeySetup = false

    private let keychainService = "com.docktape.ai"

    init(state: AppState, recording: RecordingMetadata) {
        self.state = state
        self.recording = recording
        self._selectedTemplate = State(initialValue: SummaryTemplate.forMode(recording.mode))
    }

    var body: some View {
        Group {
            if state.summarization.summarizingFile == recording.filename {
                summarizingView
            } else if let summary {
                summaryContentView(summary)
            } else if showAPIKeySetup {
                apiKeySetupView
            } else {
                noSummaryView
            }
        }
        .task(id: recording.filename) {
            summary = await state.summarization.summaryStore.summary(for: recording.filename)
        }
    }

    // MARK: - No Summary

    private var noSummaryView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("No Summary")
                .font(.title3.weight(.medium))

            let hasTranscript = state.transcription.statuses[recording.filename] == .done
            if hasTranscript {
                HStack(spacing: 12) {
                    Picker("Template", selection: $selectedTemplate) {
                        Text("Meeting").tag(SummaryTemplate.meeting)
                        Text("Call").tag(SummaryTemplate.call)
                        Text("Memo").tag(SummaryTemplate.memo)
                        Text("Recording").tag(SummaryTemplate.recording)
                        Divider()
                        Text("Custom...").tag(SummaryTemplate.custom)
                    }
                    .frame(width: 160)

                    Button("Summarize") {
                        handleSummarize()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .onChange(of: selectedTemplate) { _, newValue in
                    if newValue == .custom {
                        showCustomPromptSheet = true
                    }
                }
            } else {
                Text("Transcribe this recording first to generate a summary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showCustomPromptSheet) {
            customPromptSheet
        }
    }

    // MARK: - Custom Prompt Sheet

    private var customPromptSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Summary Prompt")
                .font(.title3.weight(.semibold))

            Text("Describe what you want extracted from the transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $customPromptText)
                .font(.body)
                .frame(minHeight: 120)
                .border(.separator)
                .overlay {
                    if customPromptText.isEmpty {
                        Text("e.g., Extract all customer objections and our responses...")
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }

            HStack {
                Spacer()
                Button("Cancel") {
                    showCustomPromptSheet = false
                    selectedTemplate = SummaryTemplate.forMode(recording.mode)
                }
                .keyboardShortcut(.cancelAction)

                Button("Summarize") {
                    showCustomPromptSheet = false
                    handleSummarize()
                }
                .buttonStyle(.borderedProminent)
                .disabled(customPromptText.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Summarizing

    private var summarizingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text(state.summarization.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") {
                state.summarization.cancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Summary Content

    private func summaryContentView(_ summary: Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generated by \(summary.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(summary.createdAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button {
                        if summary.templateUsed == "custom" {
                            customPromptText = summary.customPrompt ?? ""
                            showCustomPromptSheet = true
                        } else {
                            handleSummarize()
                        }
                    } label: {
                        Label("Re-summarize", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()

                // Sections
                ForEach(summary.sections) { section in
                    sectionView(section)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showCustomPromptSheet) {
            customPromptSheet
        }
    }

    private func sectionView(_ section: Summary.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.heading)
                .font(.headline)

            if !section.content.isEmpty {
                Text(section.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            if let items = section.items {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            Task {
                                try? await state.summarization.summaryStore.toggleItem(
                                    item.id,
                                    inSummaryFor: recording.filename
                                )
                                self.summary = await state.summarization.summaryStore.summary(
                                    for: recording.filename
                                )
                            }
                        } label: {
                            Image(systemName: item.isCompleted
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isCompleted ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)

                        Text(item.text)
                            .font(.body)
                            .strikethrough(item.isCompleted)
                            .foregroundStyle(item.isCompleted ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - API Key Setup (inline)

    private var apiKeySetupView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("API Key Required")
                .font(.title3.weight(.medium))

            Text("Configure an API key in Settings > AI to use summarization.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func handleSummarize() {
        let apiKey = KeychainHelper.read(service: keychainService, account: providerName)
        guard let apiKey, !apiKey.isEmpty else {
            showAPIKeySetup = true
            return
        }

        let provider: any LLMProvider = switch providerName {
        case "openai": OpenAIProvider(apiKey: apiKey)
        case "openrouter": OpenRouterProvider(apiKey: apiKey)
        default: AnthropicProvider(apiKey: apiKey)
        }

        state.summarizeRecordings(
            [recording],
            template: selectedTemplate,
            customPrompt: selectedTemplate == .custom ? customPromptText : nil,
            provider: provider,
            model: selectedModel
        )
    }
}
```

- [ ] **Step 2: Add Summary tab to DetailPane**

In `Sources/DockTape/Views/DetailPane.swift`, make these changes:

Update the `DetailTab` enum to add a summary case:
```swift
enum DetailTab: String, CaseIterable {
    case info = "Info"
    case transcript = "Transcript"
    case summary = "Summary"
}
```

Update `availableTabs(for:)` to include the summary tab:
```swift
private func availableTabs(for rec: RecordingMetadata) -> [DetailTab] {
    let status = state.transcription.statuses[rec.filename] ?? .none
    if status == .done || transcript != nil {
        return [.info, .transcript, .summary]
    }
    return [.info]
}
```

Add the summary case to `tabContent(for:)`:
```swift
case .summary:
    SummaryTabView(state: state, recording: rec)
```

- [ ] **Step 3: Build to verify**

Run: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/DockTape/Views/SummaryTabView.swift Sources/DockTape/Views/DetailPane.swift
git commit -m "feat: add Summary tab with template picker, custom prompt sheet, and action items"
```

---

### Task 9: Context Menu and Auto-Summarize Integration

**Files:**
- Modify: `Sources/DockTape/Views/RecordingListPane.swift`
- Modify: `Sources/DockTape/AppState.swift`

- [ ] **Step 1: Add "Summarize" to recording context menu**

In `Sources/DockTape/Views/RecordingListPane.swift`, in the `recordingContextMenu(for:)` method, after the Transcribe section (after the `Divider()` on line ~199), add:

```swift
let hasTranscript = (state.transcription.statuses[rec.filename] ?? .none) == .done
Button {
    state.contextMenuSummarize(rec)
} label: {
    Label("Summarize", systemImage: "sparkles")
}
.disabled(!hasTranscript)
```

- [ ] **Step 2: Add contextMenuSummarize helper to AppState**

In `Sources/DockTape/AppState.swift`, add after `summarizeRecordings`:

```swift
/// Summarize from context menu using current Settings provider/model.
func contextMenuSummarize(_ rec: RecordingMetadata) {
    let keychainService = "com.docktape.ai"
    let providerName = UserDefaults.standard.string(forKey: "aiProvider") ?? "anthropic"
    let model = UserDefaults.standard.string(forKey: "aiModel") ?? "claude-sonnet-4-6"

    guard let apiKey = KeychainHelper.read(service: keychainService, account: providerName),
          !apiKey.isEmpty else {
        errorMessage = "No API key configured. Go to Settings > AI to add one."
        return
    }

    let provider: any LLMProvider = switch providerName {
    case "openai": OpenAIProvider(apiKey: apiKey)
    case "openrouter": OpenRouterProvider(apiKey: apiKey)
    default: AnthropicProvider(apiKey: apiKey)
    }

    let template = SummaryTemplate.forMode(rec.mode)
    summarizeRecordings([rec], template: template, provider: provider, model: model)
}
```

- [ ] **Step 3: Add auto-summarize after transcription**

In `Sources/DockTape/AppState.swift`, modify `transcribeRecordings` to trigger auto-summarize in the `onComplete` callback. Replace the existing method:

```swift
func transcribeRecordings(_ recs: [RecordingMetadata]) async {
    let recsToSummarize = recs  // capture before transcription
    await transcription.transcribe(
        recordings: recs,
        baseDirectory: library.store.baseDirectory,
        onStatusMessage: { [weak self] msg in self?.statusMessage = msg },
        onError: { [weak self] msg in self?.errorMessage = msg },
        onComplete: { [weak self] in
            await self?.library.refresh()
            // Auto-summarize if enabled
            if let self,
               UserDefaults.standard.bool(forKey: "autoSummarize") {
                self.autoSummarizeRecordings(recsToSummarize)
            }
        }
    )
}

/// Auto-summarize recordings using Settings provider/model/template.
private func autoSummarizeRecordings(_ recs: [RecordingMetadata]) {
    let keychainService = "com.docktape.ai"
    let providerName = UserDefaults.standard.string(forKey: "aiProvider") ?? "anthropic"
    let model = UserDefaults.standard.string(forKey: "aiModel") ?? "claude-sonnet-4-6"
    let templateName = UserDefaults.standard.string(forKey: "autoSummarizeTemplate") ?? "recording"

    guard let apiKey = KeychainHelper.read(service: keychainService, account: providerName),
          !apiKey.isEmpty else { return }

    let provider: any LLMProvider = switch providerName {
    case "openai": OpenAIProvider(apiKey: apiKey)
    case "openrouter": OpenRouterProvider(apiKey: apiKey)
    default: AnthropicProvider(apiKey: apiKey)
    }

    let template = SummaryTemplate(rawValue: templateName) ?? .recording
    for rec in recs {
        let effectiveTemplate = template == .recording ? SummaryTemplate.forMode(rec.mode) : template
        summarizeRecordings([rec], template: effectiveTemplate, provider: provider, model: model)
    }
}
```

- [ ] **Step 4: Build to verify**

Run: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/DockTape/Views/RecordingListPane.swift Sources/DockTape/AppState.swift
git commit -m "feat: add Summarize context menu action and auto-summarize after transcription"
```

---

### Task 10: Run All Tests and Final Verification

- [ ] **Step 1: Run the full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (existing + new Summary, SummaryStore, KeychainHelper, LLMProvider, SummaryTemplate tests)

- [ ] **Step 2: Full xcodebuild to verify app compiles**

Run: `xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Verify file structure matches spec**

Run: `find Sources/HiDockKit/Summarization -type f | sort`
Expected:
```
Sources/HiDockKit/Summarization/AnthropicProvider.swift
Sources/HiDockKit/Summarization/KeychainHelper.swift
Sources/HiDockKit/Summarization/LLMProvider.swift
Sources/HiDockKit/Summarization/OpenAIProvider.swift
Sources/HiDockKit/Summarization/OpenRouterProvider.swift
Sources/HiDockKit/Summarization/Summary.swift
Sources/HiDockKit/Summarization/SummaryStore.swift
Sources/HiDockKit/Summarization/SummaryTemplate.swift
```

- [ ] **Step 4: Commit any remaining changes and push**

```bash
git push
```
