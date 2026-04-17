// © 2026 High Gain Design. All rights reserved.

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

    /// The full system prompt sent to the LLM (speaker context + prompt text + JSON schema).
    /// Pass the recording mode to inject speaker context.
    public func systemPrompt(forMode mode: String = "") -> String {
        if promptText.isEmpty { return "" }
        let context = Self.speakerContext(forMode: mode)
        if context.isEmpty {
            return "\(promptText)\n\n\(Self.jsonSchemaInstruction)"
        }
        return "\(context)\n\n\(promptText)\n\n\(Self.jsonSchemaInstruction)"
    }

    /// The full system prompt without mode context (backward compat).
    public var systemPrompt: String {
        systemPrompt(forMode: "")
    }

    /// Speaker context preamble based on recording mode.
    public static func speakerContext(forMode mode: String) -> String {
        switch mode {
        case "Rec":
            return "This is a general recording. Speakers are participants whose roles are not known in advance."
        case "Pho":
            return "This is a phone or video call recording. Speakers are call participants."
        case "Mee":
            return "This is a meeting recording. Speakers are meeting participants with roughly equal roles."
        case "Wip":
            return "This is a voice memo by a single person. There are no other speakers. Treat the entire transcript as first-person narration — omit speaker labels in your summary."
        default:
            return ""
        }
    }

    /// Wrap a user-provided one-shot custom prompt with speaker context and JSON output schema.
    public static func buildCustomPrompt(_ userPrompt: String, mode: String = "") -> String {
        let context = speakerContext(forMode: mode)
        let preamble = context.isEmpty
            ? "You are analyzing a transcript of an audio recording."
            : "You are analyzing a transcript of an audio recording. \(context)"
        return """
        \(preamble) The user wants:

        \(userPrompt)

        \(jsonSchemaInstruction)
        """
    }

    /// Parse the LLM response into Summary.Section array.
    /// Sanitizes smart quotes first (local models mix them with straight quotes),
    /// then tries JSON decode, falls back to raw text.
    public static func parseSections(from response: String) -> [Summary.Section] {
        // Sanitize BEFORE extracting JSON — smart quotes can appear as JSON delimiters
        let sanitized = sanitizeSmartQuotes(response)
        let jsonString = extractJSON(from: sanitized)

        if let data = jsonString.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(TemplateSectionsResponse.self, from: data) {
            return parsed.sections.map { raw in
                Summary.Section(
                    heading: raw.heading,
                    content: raw.content ?? "",
                    items: raw.items?.map { item in
                        Summary.Item(text: item.text, isCompleted: item.isCompleted ?? false)
                    }
                )
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

    /// Extract the JSON object from an LLM response, sanitizing smart quotes
    /// that local models (Gemma, etc.) use as JSON delimiters.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            // Smart quote might be used as opening brace context — try with sanitized text
            let sanitized = sanitizeSmartQuotes(trimmed)
            guard let s2 = sanitized.firstIndex(of: "{"),
                  let e2 = sanitized.lastIndex(of: "}") else { return trimmed }
            return String(sanitized[s2...e2])
        }
        return sanitizeSmartQuotes(String(trimmed[start...end]))
    }

    /// Normalize all quote-like characters to straight ASCII quotes.
    /// Smart double quotes become straight double quotes, smart singles become apostrophes.
    /// After normalization, any unescaped inner quotes within JSON strings are escaped.
    private static func sanitizeSmartQuotes(_ text: String) -> String {
        var result = text
        // Replace smart quotes with their straight equivalents
        result = result.replacingOccurrences(of: "\u{201C}", with: "\"")
        result = result.replacingOccurrences(of: "\u{201D}", with: "\"")
        result = result.replacingOccurrences(of: "\u{2018}", with: "'")
        result = result.replacingOccurrences(of: "\u{2019}", with: "'")

        // Now fix doubled straight quotes that result from inner quotes
        // colliding with delimiters. A sequence like "" inside a JSON array
        // element means an inner quote bumped into the delimiter.
        // Strategy: try parsing as-is; if it fails, escape inner quotes.
        if let data = result.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) {
            return result  // Already valid JSON
        }

        // Escape inner double quotes: within items arrays, strings often have
        // unescaped quotes from the LLM. Replace sequences where a quote follows
        // a non-delimiter character (not : , [ { whitespace) with an escaped quote.
        var chars = Array(result)
        var fixed: [Character] = []
        var inString = false
        var i = 0

        while i < chars.count {
            let ch = chars[i]

            if ch == "\\" && inString && i + 1 < chars.count {
                // Escaped character — pass through both
                fixed.append(ch)
                fixed.append(chars[i + 1])
                i += 2
                continue
            }

            if ch == "\"" {
                if !inString {
                    inString = true
                    fixed.append(ch)
                } else {
                    // Is this the end of the string, or an unescaped inner quote?
                    // Look ahead: if next non-whitespace is , ] } : it's a delimiter
                    var j = i + 1
                    while j < chars.count && (chars[j] == " " || chars[j] == "\n" || chars[j] == "\r" || chars[j] == "\t") {
                        j += 1
                    }
                    let nextSignificant: Character? = j < chars.count ? chars[j] : nil
                    if nextSignificant == "," || nextSignificant == "]" || nextSignificant == "}" || nextSignificant == ":" || nextSignificant == nil {
                        // This is a string terminator
                        inString = false
                        fixed.append(ch)
                    } else {
                        // This is an inner quote — escape it
                        fixed.append("\\")
                        fixed.append(ch)
                    }
                }
            } else {
                fixed.append(ch)
            }
            i += 1
        }

        return String(fixed)
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
