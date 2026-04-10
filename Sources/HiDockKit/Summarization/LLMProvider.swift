import Foundation

public protocol LLMProvider: Sendable {
    var name: String { get }
    var defaultModel: String { get }
    var availableModels: [String] { get }
    func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String
    func verifyKey() async throws
}

/// Build a provider by name.
public func makeLLMProvider(
    name: String,
    apiKey: String,
    baseURL: String = "http://localhost:11434/v1"
) -> (any LLMProvider)? {
    switch name {
    case "anthropic":  return AnthropicProvider(apiKey: apiKey)
    case "openai":     return OpenAIProvider(apiKey: apiKey)
    case "openrouter": return OpenRouterProvider(apiKey: apiKey)
    case "custom":     return OpenAIProvider(apiKey: apiKey, baseURL: baseURL, name: "Custom")
    default:           return nil
    }
}

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
