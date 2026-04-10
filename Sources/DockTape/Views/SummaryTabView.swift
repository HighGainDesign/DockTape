import SwiftUI
import HiDockKit

struct SummaryTabView: View {
    @Bindable var state: AppState
    let recording: RecordingMetadata

    @AppStorage("aiProvider") private var providerName: String = "anthropic"
    @AppStorage("aiModel") private var selectedModel: String = "claude-sonnet-4-6"

    @State private var summary: Summary?
    @State private var hasTranscript: Bool = false
    @State private var selectedTemplate: SummaryTemplate
    @State private var showCustomPromptSheet = false
    @State private var customPromptText = ""
    @State private var showAPIKeySetup = false

    private let keychainService = KeychainHelper.aiService

    init(state: AppState, recording: RecordingMetadata) {
        self.state = state
        self.recording = recording
        self._selectedTemplate = State(initialValue: SummaryTemplate.forMode(recording.mode))
    }

    var body: some View {
        Group {
            if state.summarization.summarizingFile == recording.filename {
                summarizingView
            } else if let summary {
                summaryContentView(summary)
            } else if showAPIKeySetup {
                apiKeySetupView
            } else {
                noSummaryView
            }
        }
        .task(id: recording.filename) {
            summary = await state.summarization.summaryStore.summary(for: recording.filename)
            hasTranscript = await state.transcription.transcriptStore.hasTranscript(for: recording.filename)
        }
        .onChange(of: state.summarization.summarizingFile) { old, new in
            // Reload summary when summarization completes for this recording
            if old == recording.filename && new != recording.filename {
                Task {
                    summary = await state.summarization.summaryStore.summary(for: recording.filename)
                }
            }
        }
    }

    // MARK: - No Summary

    private var noSummaryView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("No Summary")
                .font(.title3.weight(.medium))

            if hasTranscript {
                HStack(spacing: 12) {
                    Picker("Template", selection: $selectedTemplate) {
                        Text("Meeting").tag(SummaryTemplate.meeting)
                        Text("Call").tag(SummaryTemplate.call)
                        Text("Memo").tag(SummaryTemplate.memo)
                        Text("Recording").tag(SummaryTemplate.recording)
                        Divider()
                        Text("Custom...").tag(SummaryTemplate.custom)
                    }
                    .frame(width: 160)

                    Button("Summarize") {
                        handleSummarize()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .onChange(of: selectedTemplate) { _, newValue in
                    if newValue == .custom {
                        showCustomPromptSheet = true
                    }
                }
            } else {
                Text("Transcribe this recording first to generate a summary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showCustomPromptSheet) {
            customPromptSheet
        }
    }

    // MARK: - Custom Prompt Sheet

    private var customPromptSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Summary Prompt")
                .font(.title3.weight(.semibold))

            Text("Describe what you want extracted from the transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $customPromptText)
                .font(.body)
                .frame(minHeight: 120)
                .border(.separator)
                .overlay {
                    if customPromptText.isEmpty {
                        Text("e.g., Extract all customer objections and our responses...")
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }

            HStack {
                Spacer()
                Button("Cancel") {
                    showCustomPromptSheet = false
                    selectedTemplate = SummaryTemplate.forMode(recording.mode)
                }
                .keyboardShortcut(.cancelAction)

                Button("Summarize") {
                    showCustomPromptSheet = false
                    handleSummarize()
                }
                .buttonStyle(.borderedProminent)
                .disabled(customPromptText.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Summarizing

    private var summarizingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text(state.summarization.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") {
                state.summarization.cancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Summary Content

    private func summaryContentView(_ summary: Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generated by \(summary.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(summary.createdAt, style: .date)
                            Text("at")
                            Text(summary.createdAt, style: .time)
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Menu {
                        Button("Meeting") {
                            selectedTemplate = .meeting
                            handleSummarize()
                        }
                        Button("Call") {
                            selectedTemplate = .call
                            handleSummarize()
                        }
                        Button("Memo") {
                            selectedTemplate = .memo
                            handleSummarize()
                        }
                        Button("Recording") {
                            selectedTemplate = .recording
                            handleSummarize()
                        }
                        Divider()
                        Button("Custom...") {
                            customPromptText = summary.customPrompt ?? ""
                            showCustomPromptSheet = true
                        }
                    } label: {
                        Label("Re-summarize", systemImage: "arrow.clockwise")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                }

                Divider()

                // Sections
                ForEach(summary.sections) { section in
                    sectionView(section)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showCustomPromptSheet) {
            customPromptSheet
        }
    }

    /// Sections whose items are actionable (checkable).
    private static let actionableSections: Set<String> = [
        "Action Items", "Commitments", "Follow-ups", "Next Steps"
    ]

    private func sectionView(_ section: Summary.Section) -> some View {
        let isActionable = Self.actionableSections.contains(section.heading)

        return VStack(alignment: .leading, spacing: 8) {
            Text(section.heading)
                .font(.headline)

            if !section.content.isEmpty {
                Text(section.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            if let items = section.items {
                ForEach(items) { item in
                    if isActionable {
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                Task {
                                    try? await state.summarization.summaryStore.toggleItem(
                                        item.id,
                                        inSummaryFor: recording.filename
                                    )
                                    self.summary = await state.summarization.summaryStore.summary(
                                        for: recording.filename
                                    )
                                }
                            } label: {
                                Image(systemName: item.isCompleted
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isCompleted ? .green : .secondary)
                            }
                            .buttonStyle(.borderless)

                            Text(item.text)
                                .font(.body)
                                .strikethrough(item.isCompleted)
                                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(item.text)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: - API Key Setup (inline)

    private var apiKeySetupView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("API Key Required")
                .font(.title3.weight(.medium))

            Text("Configure an API key in Settings > AI to use summarization.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    @AppStorage("aiCustomBaseURL") private var customBaseURL: String = "http://localhost:11434/v1"
    @AppStorage("aiCustomModel") private var customModel: String = ""

    private func handleSummarize() {
        let apiKey = KeychainHelper.read(service: keychainService, account: providerName) ?? ""
        if providerName != "custom" && apiKey.isEmpty {
            showAPIKeySetup = true
            return
        }

        guard let provider = makeLLMProvider(name: providerName, apiKey: apiKey, baseURL: customBaseURL) else { return }

        let effectiveModel = providerName == "custom" ? customModel : selectedModel
        state.summarizeRecordings(
            [recording],
            template: selectedTemplate,
            customPrompt: selectedTemplate == .custom ? customPromptText : nil,
            provider: provider,
            model: effectiveModel
        )
    }
}
