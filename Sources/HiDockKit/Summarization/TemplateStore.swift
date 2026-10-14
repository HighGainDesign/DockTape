// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Actor that manages built-in and user-created summary templates.
/// Built-in templates can be overridden (prompt text customized) but not deleted.
/// User-created templates can be added, edited, and deleted.
public actor TemplateStore {

    // MARK: - State

    private var builtInOverrides: [String: Template] = [:]
    private var userTemplates: [Template] = []
    private let baseDirectory: URL

    // MARK: - Init

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    // MARK: - Built-in defaults

    /// All built-in template definitions. Static so callers can reference without an actor instance.
    public static let builtInDefaults: [Template] = [
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
            You are summarizing a lecture or class recording transcript. Produce a structured summary with these sections in this order:
            1. "Key Concepts" — main ideas and definitions, as items
            2. "Summary" — 2-3 paragraph overview of the content covered
            3. "Questions Raised" — questions posed or left open, as items
            4. "Takeaways" — practical lessons or insights, as items
            """,
            isBuiltIn: true
        ),
        Template(
            id: "interview",
            name: "Interview",
            description: "Q&A pairs, key quotes, and assessment",
            promptText: """
            You are summarizing an interview transcript. Produce a structured summary with these sections in this order:
            1. "Q&A" — key question and answer pairs, as items
            2. "Key Quotes" — notable direct quotes, as items
            3. "Assessment" — 1-2 paragraph overall impressions or findings
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
            You are summarizing a discussion transcript. Produce a structured summary with these sections in this order:
            1. "Topics" — main topics discussed, as items
            2. "Perspectives" — different viewpoints or positions taken, as items
            3. "Notable Quotes" — memorable or significant quotes, as items
            """,
            isBuiltIn: true
        ),
        Template(
            id: "consultation",
            name: "Consultation",
            description: "Expert insights, recommendations, and follow-ups",
            promptText: """
            You are summarizing a consultation transcript. Produce a structured summary with these sections in this order:
            1. "Key Insights" — expert observations and findings, as items
            2. "Recommendations" — advice or suggested actions, as items
            3. "Q&A" — questions asked and answers given, as items
            4. "Follow-ups" — next steps or scheduled actions, as items
            """,
            isBuiltIn: true
        ),
        Template(
            id: "coaching",
            name: "Coaching/Counseling",
            description: "Themes, observations, goals, and plan",
            promptText: """
            You are summarizing a coaching or counseling session transcript. Produce a structured summary with these sections in this order:
            1. "Themes" — recurring themes or topics explored, as items
            2. "Observations" — notable behavioral or emotional observations, as items
            3. "Goals Discussed" — goals mentioned or set, as items
            4. "Plan" — agreed-upon actions or next steps, as items
            """,
            isBuiltIn: true
        ),
    ]

    // MARK: - Query

    /// All templates: built-ins (with any overrides applied) + user-created.
    public func allTemplates() -> [Template] {
        builtInTemplates() + userTemplates
    }

    /// Built-in templates with any user overrides applied.
    public func builtInTemplates() -> [Template] {
        Self.builtInDefaults.map { template in
            builtInOverrides[template.id] ?? template
        }
    }

    /// User-created templates only.
    public func userCreatedTemplates() -> [Template] {
        userTemplates
    }

    /// Look up a template by ID (built-in or user).
    public func template(forID id: String) -> Template? {
        allTemplates().first { $0.id == id }
    }

    /// Return the default template for a recording mode string.
    /// Mee → meeting, Pho → consultation, Wip → memo, anything else → meeting.
    public func defaultTemplate(forMode mode: String) -> Template {
        let id: String
        switch mode {
        case "Mee": id = "meeting"
        case "Pho": id = "consultation"
        case "Wip": id = "memo"
        default:    id = "meeting"
        }
        return template(forID: id) ?? builtInTemplates()[0]
    }

    // MARK: - Mutations

    /// Add a new user-created template without replacing another store's additions.
    public func addUserTemplate(_ template: Template) async throws {
        try await mutateTemplate(template, adding: true)
    }

    /// Updates only changed editable fields against freshly coordinated JSON.
    public func update(_ template: Template) async throws {
        try await mutateTemplate(template, adding: false)
    }

    public func delete(id: String) async throws {
        guard !Self.builtInDefaults.contains(where: { $0.id == id }) else { return }
        try await mutateStored { object in
            var values = object["userTemplates"] as! [[String: Any]]
            values.removeAll { $0["id"] as? String == id }
            object["userTemplates"] = values
        }
    }

    public func resetToDefault(id: String) async throws {
        guard Self.builtInDefaults.contains(where: { $0.id == id }) else { return }
        try await mutateStored { object in
            var values = object["builtInOverrides"] as! [[String: Any]]
            values.removeAll { $0["id"] as? String == id }
            object["builtInOverrides"] = values
        }
    }

    private func mutateTemplate(_ template: Template, adding: Bool) async throws {
        let bytes = try JSONEncoder().encode(template)
        let baseline = try self.template(forID: template.id).map { try JSONEncoder().encode($0) }
        let collection = template.isBuiltIn ? "builtInOverrides" : "userTemplates"
        try await mutateStored { object in
            let desired = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let before = try baseline.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
            var values = object[collection] as! [[String: Any]]
            if let index = values.firstIndex(where: { $0["id"] as? String == template.id }) {
                if adding {
                    let existing = try JSONDecoder().decode(Template.self, from: JSONSerialization.data(withJSONObject: values[index]))
                    guard existing == template else { throw HiDockError.storageError("A template with this ID already exists. Edit it instead.") }
                    return
                }
                var current = values[index]
                for field in ["name", "description", "promptText", "isBuiltIn"] {
                    let old = try before[field].map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
                    let new = try desired[field].map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
                    if old != new { current[field] = desired[field] }
                }
                values[index] = current
            } else if adding || template.isBuiltIn { values.append(desired) }
            object[collection] = values
        }
    }

    private var persistenceTicket: UInt64 = 0
    private var storeURL: URL { baseDirectory.appendingPathComponent(".templates.json") }

    public func load() async throws {
        persistenceTicket += 1; let ticket = persistenceTicket
        let bytes = try await RecordingFileAccess().readDataIfPresent(at: storeURL)
        let stored = try bytes.map { try JSONDecoder().decode(StoredTemplates.self, from: $0) }
            ?? StoredTemplates(builtInOverrides: [], userTemplates: [])
        guard persistenceTicket == ticket else { return }
        let ids = (stored.builtInOverrides + stored.userTemplates).map(\.id)
        guard Set(ids).count == ids.count else { throw HiDockError.storageError("Template IDs are duplicated. Resolve the file before editing.") }
        builtInOverrides = Dictionary(uniqueKeysWithValues: stored.builtInOverrides.map { ($0.id, $0) })
        userTemplates = stored.userTemplates
    }

    private func mutateStored(_ mutation: @escaping @Sendable (inout [String: Any]) throws -> Void) async throws {
        persistenceTicket += 1; let ticket = persistenceTicket
        let initial = try JSONEncoder().encode(StoredTemplates(builtInOverrides: [], userTemplates: []))
        let bytes = try await LegacyLibraryFileAccess().mutateObject(at: storeURL, root: baseDirectory, initialObject: initial) { object in
            let original = try JSONDecoder().decode(StoredTemplates.self, from: JSONSerialization.data(withJSONObject: object))
            let ids = (original.builtInOverrides + original.userTemplates).map(\.id)
            guard Set(ids).count == ids.count else { throw HiDockError.storageError("Template IDs are duplicated. Resolve the file before editing.") }
            try mutation(&object)
        }
        let stored = try JSONDecoder().decode(StoredTemplates.self, from: bytes)
        if persistenceTicket == ticket {
            builtInOverrides = Dictionary(uniqueKeysWithValues: stored.builtInOverrides.map { ($0.id, $0) })
            userTemplates = stored.userTemplates
        }
    }

    // MARK: - Migration

    /// Migrate prompt overrides from UserDefaults into built-in overrides.
    /// Clears the UserDefaults keys after migration.
    public func migrateFromUserDefaults(_ defaults: UserDefaults) async throws {
        let migrations: [(key: String, templateID: String)] = [
            ("templatePrompt_meeting", "meeting"), ("templatePrompt_call", "consultation"),
            ("templatePrompt_memo", "memo"), ("templatePrompt_recording", "meeting")]
        for (key, id) in migrations {
            guard let custom = defaults.string(forKey: key), !custom.isEmpty,
                  var template = template(forID: id) else { continue }
            template.promptText = custom
            try await update(template)
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Storage format

    private struct StoredTemplates: Codable {
        let builtInOverrides: [Template]
        let userTemplates: [Template]
    }
}
