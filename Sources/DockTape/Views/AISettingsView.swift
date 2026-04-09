import SwiftUI
import HiDockKit

struct AISettingsView: View {
    @AppStorage("aiProvider") private var providerName: String = "anthropic"
    @AppStorage("aiModel") private var selectedModel: String = "claude-sonnet-4-6"
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
                }
                .onChange(of: providerName) { _, newValue in
                    apiKey = KeychainHelper.read(
                        service: keychainService,
                        account: newValue
                    ) ?? ""
                    selectedModel = makeProvider(name: newValue, apiKey: "")?.defaultModel ?? ""
                    verifyResult = nil
                }

                Picker("Model", selection: $selectedModel) {
                    let provider = makeProvider(name: providerName, apiKey: "")
                    ForEach(provider?.availableModels ?? [], id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }

            Section("API Key") {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveKey() }

                HStack {
                    Button("Save Key") { saveKey() }
                        .disabled(apiKey.isEmpty)

                    Button("Verify") { verifyKey() }
                        .disabled(apiKey.isEmpty || isVerifying)

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
                    .disabled(apiKey.isEmpty)

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

    private func makeProvider(name: String, apiKey: String) -> (any LLMProvider)? {
        switch name {
        case "anthropic": return AnthropicProvider(apiKey: apiKey)
        case "openai":    return OpenAIProvider(apiKey: apiKey)
        case "openrouter": return OpenRouterProvider(apiKey: apiKey)
        default: return nil
        }
    }
}
