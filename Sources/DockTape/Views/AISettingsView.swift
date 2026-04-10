import SwiftUI
import HiDockKit

struct AISettingsView: View {
    @AppStorage("aiProvider") private var providerName: String = "anthropic"
    @AppStorage("aiModel") private var selectedModel: String = "claude-sonnet-4-6"
    @AppStorage("aiCustomBaseURL") private var customBaseURL: String = "http://localhost:11434/v1"
    @AppStorage("aiCustomModel") private var customModel: String = ""
    @AppStorage("autoSummarize") private var autoSummarize: Bool = false
    @AppStorage("autoSummarizeTemplate") private var autoSummarizeTemplate: String = "recording"

    @State private var apiKey: String = ""
    @State private var isVerifying: Bool = false
    @State private var verifyResult: VerifyResult?

    private let keychainService = "com.docktape.ai"

    enum VerifyResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $providerName) {
                    Text("Anthropic").tag("anthropic")
                    Text("OpenAI").tag("openai")
                    Text("OpenRouter").tag("openrouter")
                    Divider()
                    Text("Custom (OpenAI-compatible)").tag("custom")
                }
                .onChange(of: providerName) { _, newValue in
                    apiKey = KeychainHelper.read(
                        service: keychainService,
                        account: newValue
                    ) ?? ""
                    if newValue != "custom" {
                        selectedModel = makeProvider(name: newValue, apiKey: "")?.defaultModel ?? ""
                    }
                    verifyResult = nil
                }

                if providerName == "custom" {
                    TextField("Base URL", text: $customBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .help("e.g., http://localhost:11434/v1 for Ollama")

                    TextField("Model name", text: $customModel)
                        .textFieldStyle(.roundedBorder)
                        .help("e.g., llama3.1, mistral, gemma2")
                } else {
                    Picker("Model", selection: $selectedModel) {
                        let provider = makeProvider(name: providerName, apiKey: "")
                        ForEach(provider?.availableModels ?? [], id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            }

            Section(providerName == "custom" ? "API Key (optional)" : "API Key") {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveKey() }

                HStack {
                    Button("Save Key") { saveKey() }
                        .disabled(apiKey.isEmpty)

                    Button("Verify") { verifyKey() }
                        .disabled(isVerifying || (providerName != "custom" && apiKey.isEmpty))

                    if isVerifying {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()

                    if let result = verifyResult {
                        switch result {
                        case .success:
                            Label("Valid", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Section("Automation") {
                Toggle("Auto-summarize after transcription", isOn: $autoSummarize)
                    .disabled(providerName != "custom" && apiKey.isEmpty)

                if autoSummarize {
                    Picker("Default template", selection: $autoSummarizeTemplate) {
                        Text("Meeting").tag("meeting")
                        Text("Call").tag("call")
                        Text("Memo").tag("memo")
                        Text("Recording").tag("recording")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = KeychainHelper.read(
                service: keychainService,
                account: providerName
            ) ?? ""
        }
    }

    private func saveKey() {
        try? KeychainHelper.save(
            key: apiKey,
            service: keychainService,
            account: providerName
        )
        verifyResult = nil
    }

    private func verifyKey() {
        guard let provider = makeProvider(name: providerName, apiKey: apiKey) else { return }
        isVerifying = true
        verifyResult = nil
        Task {
            do {
                try await provider.verifyKey()
                verifyResult = .success
            } catch {
                verifyResult = .failure(error.localizedDescription)
            }
            isVerifying = false
        }
    }

    /// The effective model name — custom provider uses free-text field.
    var effectiveModel: String {
        providerName == "custom" ? customModel : selectedModel
    }

    private func makeProvider(name: String, apiKey: String) -> (any LLMProvider)? {
        switch name {
        case "anthropic": return AnthropicProvider(apiKey: apiKey)
        case "openai":    return OpenAIProvider(apiKey: apiKey)
        case "openrouter": return OpenRouterProvider(apiKey: apiKey)
        case "custom":    return OpenAIProvider(apiKey: apiKey, baseURL: customBaseURL)
        default: return nil
        }
    }
}
