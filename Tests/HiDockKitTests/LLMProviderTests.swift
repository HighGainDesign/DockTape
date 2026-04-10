import XCTest
@testable import HiDockKit

final class LLMProviderTests: XCTestCase {

    func testAnthropicParseResponse() throws {
        let json = """
        {
            "content": [{"type": "text", "text": "Here is the summary."}],
            "model": "claude-sonnet-4-6",
            "role": "assistant"
        }
        """
        let data = Data(json.utf8)
        let text = try AnthropicProvider.extractText(from: data)
        XCTAssertEqual(text, "Here is the summary.")
    }

    func testAnthropicParseErrorResponse() {
        let json = """
        {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try AnthropicProvider.extractText(from: data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid x-api-key"))
        }
    }

    func testOpenAIParseResponse() throws {
        let json = """
        {
            "choices": [{"message": {"role": "assistant", "content": "Summary text here."}}]
        }
        """
        let data = Data(json.utf8)
        let text = try OpenAIProvider.extractText(from: data)
        XCTAssertEqual(text, "Summary text here.")
    }

    func testOpenAIParseErrorResponse() {
        let json = """
        {"error": {"message": "Invalid API key", "type": "invalid_request_error"}}
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try OpenAIProvider.extractText(from: data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid API key"))
        }
    }

    func testAnthropicProviderDefaults() {
        let provider = AnthropicProvider(apiKey: "test")
        XCTAssertEqual(provider.name, "Anthropic")
        XCTAssertFalse(provider.availableModels.isEmpty)
        XCTAssertTrue(provider.availableModels.contains(provider.defaultModel))
    }

    func testOpenAIProviderDefaults() {
        let provider = OpenAIProvider(apiKey: "test")
        XCTAssertEqual(provider.name, "OpenAI")
        XCTAssertFalse(provider.availableModels.isEmpty)
        XCTAssertTrue(provider.availableModels.contains(provider.defaultModel))
    }

    func testOpenRouterProviderDefaults() {
        let provider = OpenRouterProvider(apiKey: "test")
        XCTAssertEqual(provider.name, "OpenRouter")
        XCTAssertFalse(provider.availableModels.isEmpty)
        XCTAssertTrue(provider.availableModels.contains(provider.defaultModel))
    }
}
