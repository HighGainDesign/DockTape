// © 2026 High Gain Design. All rights reserved.

import Foundation

public struct AnthropicProvider: LLMProvider, Sendable {
    public let name = "Anthropic"
    public let defaultModel = "claude-sonnet-4-6"
    public let availableModels = ["claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private static let apiVersion = "2025-01-01"

    public func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300  // 5 minutes for long transcripts
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model, "max_tokens": 4096, "system": systemPrompt,
            "messages": [["role": "user", "content": transcript]]
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
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001", "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw LLMError.apiError("HTTP \(http.statusCode): \(body.prefix(200))")
        }
        _ = try Self.extractText(from: data)
    }

    public static func extractText(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw LLMError.apiError(message)
        }
        guard let content = json["content"] as? [[String: Any]],
              let first = content.first, let text = first["text"] as? String else {
            throw LLMError.invalidResponse
        }
        return text
    }
}
