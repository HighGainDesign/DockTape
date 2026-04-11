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

    /// Add a new user-created template.
    public func addUserTemplate(_ template: Template) async {
        userTemplates.append(template)
        await save()
    }

    /// Update an existing template.
    /// For built-ins, stores as an override. For user templates, replaces in place.
    public func update(_ template: Template) async {
        if template.isBuiltIn {
            builtInOverrides[template.id] = template
        } else {
            if let index = userTemplates.firstIndex(where: { $0.id == template.id }) {
                userTemplates[index] = template
            }
        }
        await save()
    }

    /// Delete a user-created template by ID. No-op for built-ins.
    public func delete(id: String) async {
        userTemplates.removeAll { $0.id == id }
        await save()
    }

    /// Reset a built-in template to its default prompt, removing any override.
    public func resetToDefault(id: String) async {
        builtInOverrides.removeValue(forKey: id)
        await save()
    }

    // MARK: - Persistence

    private var storeURL: URL {
        baseDirectory.appendingPathComponent(".templates.json")
    }

    /// Load templates from disk. Call once after init.
    public func load() async {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let stored = try JSONDecoder().decode(StoredTemplates.self, from: data)
            for t in stored.builtInOverrides {
                builtInOverrides[t.id] = t
            }
            userTemplates = stored.userTemplates
        } catch {
            // Start fresh on decode error
        }
    }

    private func save() async {
        let stored = StoredTemplates(
            builtInOverrides: Array(builtInOverrides.values),
            userTemplates: userTemplates
        )
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Silently ignore write errors
        }
    }

    // MARK: - Migration

    /// Migrate prompt overrides from UserDefaults into built-in overrides.
    /// Clears the UserDefaults keys after migration.
    public func migrateFromUserDefaults(_ defaults: UserDefaults) async {
        let migrations: [(key: String, templateID: String)] = [
            ("templatePrompt_meeting", "meeting"),
            ("templatePrompt_call", "consultation"),
            ("templatePrompt_memo", "memo"),
            ("templatePrompt_recording", "meeting"),
        ]

        var didMigrate = false
        for (key, id) in migrations {
            if let custom = defaults.string(forKey: key), !custom.isEmpty {
                if var template = template(forID: id) {
                    template.promptText = custom
                    builtInOverrides[id] = template
                    didMigrate = true
                }
                defaults.removeObject(forKey: key)
            }
        }

        if didMigrate {
            await save()
        }
    }

    // MARK: - Storage format

    private struct StoredTemplates: Codable {
        let builtInOverrides: [Template]
        let userTemplates: [Template]
    }
}
