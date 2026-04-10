import Foundation

public struct OpenRouterProvider: LLMProvider, Sendable {
    public let name = "OpenRouter"
    public let defaultModel = "anthropic/claude-sonnet-4-6"
    public let availableModels = [
        "anthropic/claude-sonnet-4-6", "anthropic/claude-haiku-4-5-20251001",
        "openai/gpt-4o", "openai/gpt-4o-mini",
        "google/gemini-2.5-pro", "google/gemini-2.5-flash",
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
            "model": model, "max_tokens": 4096,
            "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": transcript]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw LLMError.apiError("HTTP \(http.statusCode): \(body.prefix(200))")
        }
        return try OpenAIProvider.extractText(from: data)
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
