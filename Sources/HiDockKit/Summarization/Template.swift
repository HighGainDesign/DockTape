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
                let parsed = try JSONDecoder().decode(TemplateSectionsResponse.self, from: data)
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

    /// Extract the JSON object from an LLM response.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return trimmed
        }
        return String(trimmed[start...end])
    }
}

// MARK: - Response parsing types

private struct TemplateSectionsResponse: Decodable {
    let sections: [TemplateRawSection]
}

private struct TemplateRawSection: Decodable {
    let heading: String
    let content: String?
    let items: [TemplateRawItem]?
}

/// Accepts both `{"text": "...", "isCompleted": false}` objects and plain `"string"` values.
/// LLMs (especially local models like Gemma) sometimes return string arrays instead of objects.
private struct TemplateRawItem: Decodable {
    let text: String
    let isCompleted: Bool?

    init(from decoder: Decoder) throws {
        // Try decoding as an object first
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.text = try container.decode(String.self, forKey: .text)
            self.isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted)
        } else {
            // Fall back to a plain string
            let container = try decoder.singleValueContainer()
            self.text = try container.decode(String.self)
            self.isCompleted = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case text, isCompleted
    }
}
