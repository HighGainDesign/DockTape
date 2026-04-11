import SwiftUI
import HiDockKit

struct AISettingsView: View {
    @AppStorage("aiProvider") private var providerName: String = "anthropic"
    @AppStorage("aiModel") private var selectedModel: String = "claude-sonnet-4-6"
    @AppStorage("aiCustomBaseURL") private var customBaseURL: String = "http://localhost:11434/v1"
    @AppStorage("aiCustomModel") private var customModel: String = ""
    @AppStorage("autoSummarize") private var autoSummarize: Bool = false
    @AppStorage("autoSummarizeTemplate") private var autoSummarizeTemplate: String = "meeting"

    @State private var apiKey: String = ""
    @State private var isVerifying: Bool = false
    @State private var verifyResult: VerifyResult?
    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels: Bool = false

    private let keychainService = KeychainHelper.aiService

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
                        .onChange(of: customBaseURL) { _, _ in fetchedModels = [] }

                    HStack {
                        if fetchedModels.isEmpty {
                            TextField("Model name", text: $customModel)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("Model", selection: $customModel) {
                                if !fetchedModels.contains(customModel) && !customModel.isEmpty {
                                    Text(customModel).tag(customModel)
                                }
                                ForEach(fetchedModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                        }

                        Button {
                            fetchCustomModels()
                        } label: {
                            if isFetchingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isFetchingModels)
                        .help("Fetch available models from server")
                    }
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
                        .help("Makes a small API call to verify the key works")

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
                        ForEach(TemplateStore.builtInDefaults) { t in
                            Text(t.name).tag(t.id)
                        }
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

    private func fetchCustomModels() {
        isFetchingModels = true
        Task {
            defer { isFetchingModels = false }
            do {
                let provider = OpenAIProvider(apiKey: apiKey, baseURL: customBaseURL, name: "Custom")
                let models = try await provider.listModels()
                fetchedModels = models.sorted()
                if customModel.isEmpty, let first = fetchedModels.first {
                    customModel = first
                }
            } catch {
                // Silently fail — user can still type manually
                fetchedModels = []
            }
        }
    }

    private func makeProvider(name: String, apiKey: String) -> (any LLMProvider)? {
        makeLLMProvider(name: name, apiKey: apiKey, baseURL: customBaseURL)
    }
}
