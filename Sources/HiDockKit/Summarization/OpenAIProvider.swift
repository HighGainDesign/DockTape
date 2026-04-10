import Foundation

public struct OpenAIProvider: LLMProvider, Sendable {
    public let name: String
    public let defaultModel = "gpt-4o"
    public let availableModels = ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini"]
    private let apiKey: String
    private let session: URLSession
    private let baseURL: String

    public init(
        apiKey: String,
        baseURL: String = "https://api.openai.com",
        name: String = "OpenAI",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.name = name
        self.session = session
    }

    /// Normalize the base URL: strip trailing /v1 or /v1/ if present, since we add /v1/ ourselves.
    private var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if url.hasSuffix("/v1") {
            url = String(url.dropLast(3))
        }
        return url
    }

    public func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(normalizedBaseURL)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300  // 5 minutes — local models on long transcripts can be slow
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
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
        return try Self.extractText(from: data)
    }

    public func verifyKey() async throws {
        var request = URLRequest(url: URL(string: "\(normalizedBaseURL)/v1/models")!)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw LLMError.apiError("Invalid API key")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "Verification failed"
            throw LLMError.apiError(msg)
        }
    }

    public static func extractText(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw LLMError.apiError(message)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first, let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        return content
    }
}
