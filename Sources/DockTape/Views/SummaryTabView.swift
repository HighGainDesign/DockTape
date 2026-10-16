// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

struct SummaryTabView: View {
    @Bindable var state: AppState
    let recording: RecordingMetadata

    @AppStorage("aiProvider") private var providerName: String = "anthropic"
    @AppStorage("aiModel") private var selectedModel: String = "claude-sonnet-4-6"

    @State private var summaryState = RecordingContentState<Summary>()
    @State private var summaryRetry = 0
    private var summary: Summary? { summaryState.content }
    @State private var hasTranscript: Bool = false
    @State private var selectedTemplate: Template?
    @State private var templates: [Template] = []
    @State private var showCustomPromptSheet = false
    @State private var customPromptText = ""
    @State private var showAPIKeySetup = false

    private let keychainService = KeychainHelper.aiService

    init(state: AppState, recording: RecordingMetadata) {
        self.state = state
        self.recording = recording
    }

    private var contentID: String {
        state.library.contentID(for: recording.filename, fallbackRevision: state.sharedLibrary.revision)
    }

    var body: some View {
        Group {
            if state.summarization.summarizingFile == recording.filename {
                summarizingView
            } else if summaryState.filename != contentID || summaryState.isLoading {
                VStack(spacing: 12) {
                    ProgressView(summaryState.isDownloading
                        ? "Downloading summary from iCloud Drive…" : "Loading summary…")
                    if summaryState.isDownloading {
                        Text("This file is not available on this Mac yet. You can select another recording while it downloads.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = summaryState.errorMessage {
                ContentUnavailableView {
                    Label("Unable to Load Summary", systemImage: "exclamationmark.icloud")
                } description: { Text(error) } actions: {
                    Button("Retry") { summaryRetry += 1 }
                }
            } else if let summary {
                summaryContentView(summary)
            } else if showAPIKeySetup {
                apiKeySetupView
            } else {
                noSummaryView
            }
        }
        .sheet(isPresented: $showCustomPromptSheet) {
            customPromptSheet
        }
        .task(id: "\(contentID)|\(summaryRetry)") {
            await reloadSummary()
        }
        .task(id: "\(contentID)|templates-\(state.sharedLibrary.revision)") {
            await refreshTemplateChoices()
        }
        .onChange(of: state.summarization.summarizingFile) { old, new in
            if old == recording.filename && new != recording.filename {
                summaryRetry += 1
            }
        }
    }

    private func reloadSummary() async {
        let filename = recording.filename
        let identity = contentID
        let store = state.summarization.summaryStore
        guard !Task.isCancelled, state.library.selectedRecording == filename, contentID == identity else { return }
        await summaryState.load(for: identity) { waiting in
            try await store.loadSummary(for: filename, reference: recording.reference, onWaiting: waiting)
        }
        guard !Task.isCancelled, state.library.selectedRecording == filename, contentID == identity else { return }
        hasTranscript = await state.transcription.transcriptStore.hasTranscript(for: filename)
        templates = await state.templateStore.allTemplates()
        selectedTemplate = await state.templateStore.defaultTemplate(forMode: recording.mode)
        guard !Task.isCancelled, state.library.selectedRecording == filename, contentID == identity else { return }
        if let existing = summary,
           let template = await state.templateStore.template(forID: mapLegacyTemplateID(existing.templateUsed)) {
            guard !Task.isCancelled, state.library.selectedRecording == filename, contentID == identity else { return }
            selectedTemplate = template
        }
    }

    /// Refresh shared template choices without replacing this view or discarding
    /// a custom prompt draft. A deleted selection falls back to the mode default.
    private func refreshTemplateChoices() async {
        let identity = contentID, revision = state.sharedLibrary.revision
        let store = state.templateStore
        let choices = await store.allTemplates()
        let fallback = await store.defaultTemplate(forMode: recording.mode)
        guard !Task.isCancelled, state.templateStore === store,
              contentID == identity, state.sharedLibrary.revision == revision else { return }
        templates = choices
        if let selected = selectedTemplate {
            selectedTemplate = choices.first { $0.id == selected.id } ?? fallback
        }
    }

    /// Map legacy template IDs to current Template IDs.
    private func mapLegacyTemplateID(_ id: String) -> String {
        switch id {
        case "call": return "consultation"
        case "recording": return "meeting"
        default: return id
        }
    }

    // MARK: - Built-in / User template split

    private var builtInTemplates: [Template] {
        templates.filter { $0.isBuiltIn }
    }

    private var userTemplates: [Template] {
        templates.filter { !$0.isBuiltIn }
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
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        templatePicker

                        Button("Summarize") {
                            handleSummarize()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedTemplate == nil && customPromptText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let t = selectedTemplate {
                        templateDescriptionBar(t.description)
                    }
                }
                .onChange(of: selectedTemplate) { _, newValue in
                    if newValue == nil {
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
    }

    private var templatePicker: some View {
        Picker("Template", selection: $selectedTemplate) {
            Section("Built-in") {
                ForEach(builtInTemplates) { t in
                    Text(t.name).tag(Optional(t))
                }
            }
            if !userTemplates.isEmpty {
                Section("My Templates") {
                    ForEach(userTemplates) { t in
                        Text(t.name).tag(Optional(t))
                    }
                }
            }
            Divider()
            Text("Custom prompt...").tag(Template?.none)
        }
        .frame(width: 180)
    }

    private func templateDescriptionBar(_ description: String) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(width: 3)

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
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
                    // Restore to default template
                    Task {
                        selectedTemplate = await state.templateStore.defaultTemplate(forMode: recording.mode)
                    }
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
                }

                Divider()

                // Sections
                ForEach(summary.sections) { section in
                    sectionView(section)
                }
            }
            .padding()
        }
    }

    /// Sections whose items are actionable (checkable).
    private static let actionableSections: Set<String> = [
        "Action Items", "Commitments", "Follow-ups", "Next Steps"
    ]

    private func sectionView(_ section: Summary.Section) -> some View {
        let isActionable = Self.actionableSections.contains(section.heading)
        let editRequest = state.recordingEditRequest(for: recording)

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
                                    if await state.editRecording(editRequest, action: .toggle(item.id)) { await reloadSummary() }
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
                            Text("\u{2022}")
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

        // Custom prompt mode (selectedTemplate is nil)
        if selectedTemplate == nil {
            // Use a fallback template for the Summary record, but pass customPrompt
            Task {
                let fallback = await state.templateStore.defaultTemplate(forMode: recording.mode)
                state.summarizeRecordings(
                    [recording],
                    template: fallback,
                    customPrompt: customPromptText,
                    provider: provider,
                    model: effectiveModel
                )
            }
            return
        }

        state.summarizeRecordings(
            [recording],
            template: selectedTemplate!,
            customPrompt: nil,
            provider: provider,
            model: effectiveModel
        )
    }
}
