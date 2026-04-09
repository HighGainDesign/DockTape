import Foundation

public protocol LLMProvider: Sendable {
    var name: String { get }
    var defaultModel: String { get }
    var availableModels: [String] { get }
    func summarize(transcript: String, systemPrompt: String, model: String) async throws -> String
    func verifyKey() async throws
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
