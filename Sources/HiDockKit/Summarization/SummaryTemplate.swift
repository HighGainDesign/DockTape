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
        case .custom:  return ""
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
