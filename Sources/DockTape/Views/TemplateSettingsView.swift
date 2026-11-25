// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

struct TemplateSettingsView: View {
    @Bindable var state: AppState

    @State private var templates: [Template] = []
    @State private var selectedID: String?
    private var editor: TemplateEditingState { state.templateEditor }
    @State private var showDeleteConfirmation = false
    @State private var templateToDelete: String?
    @State private var persistenceError: String?

    var body: some View {
        HSplitView {
            listPanel
                .frame(minWidth: 160, idealWidth: 180)

            detailPanel
                .frame(minWidth: 280)
        }
        .task(id: ObjectIdentifier(state.templateStore)) { await loadTemplates() }
        .onChange(of: state.sharedLibrary.revision) { _, _ in Task { await loadTemplates() } }
        .sheet(item: Binding(get: { editor.comparison }, set: { editor.comparison = $0 })) { comparison in
            templateComparison(comparison)
        }
        .alert("Template Change Failed", isPresented: Binding(
            get: { persistenceError != nil || editor.message != nil }, set: { if !$0 { persistenceError = nil; editor.message = nil } }
        )) {
            Button("OK", role: .cancel) { persistenceError = nil; editor.message = nil }
        } message: { Text(persistenceError ?? editor.message ?? "") }
    }

    // MARK: - List Panel

    private var builtInTemplates: [Template] {
        templates.filter { $0.isBuiltIn }
    }

    private var userTemplates: [Template] {
        templates.filter { !$0.isBuiltIn }
    }

    private var listPanel: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("Built-in") {
                    ForEach(builtInTemplates) { t in
                        Text(t.name)
                            .tag(t.id)
                    }
                }

                if !userTemplates.isEmpty {
                    Section("My Templates") {
                        ForEach(userTemplates) { t in
                            Text(t.name)
                                .tag(t.id)
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        requestDelete(id: t.id)
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedID) { _, newID in
                Task { await editor.select(id: newID, using: state.templateStore) }
            }

            Divider()

            HStack {
                Button {
                    addNewTemplate()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .padding(8)

                Spacer()
            }
        }
        .alert("Delete Template?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                templateToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let id = templateToDelete {
                    deleteTemplate(id: id)
                }
            }
        } message: {
            Text("This template will be permanently removed.")
        }
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        Group {
            if let template = editor.template {
                templateForm(template)
            } else {
                VStack {
                    Spacer()
                    Text(editor.isLoading ? "Loading template…" : "Select a template")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func templateForm(_ template: Template) -> some View {
        Form {
            if template.isBuiltIn {
                LabeledContent("Name") {
                    Text(template.name)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("Name", text: bindingForName(template))
            }

            TextField("Description", text: bindingForDescription(template))

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: bindingForPrompt(template))
                    .accessibilityLabel("Template prompt")
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
                    .border(.separator)
            }

            HStack {
                if editor.hasChanges { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Compare With Latest…") { Task { await editor.compareLatest(using: state.templateStore) } }
                    .disabled(editor.isSaving)
                Button(editor.isSaving ? "Saving…" : "Save Template") {
                    Task { if await editor.save(using: state.templateStore) { await loadTemplates() } }
                }.keyboardShortcut("s", modifiers: .command)
                    .disabled(!editor.hasChanges || editor.isSaving)
            }
            HStack {
                Spacer()
                if template.isBuiltIn {
                    Button("Reset to Default") {
                        resetBuiltIn(id: template.id)
                    }
                    .disabled(!isOverridden(template) || editor.isSaving)
                } else {
                    Button("Delete Template", role: .destructive) {
                        requestDelete(id: template.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Draft bindings

    private func bindingForName(_ template: Template) -> Binding<String> {
        Binding(
            get: { editor.template?.name ?? template.name },
            set: { newValue in
                editor.change { $0.name = newValue }
            }
        )
    }

    private func bindingForDescription(_ template: Template) -> Binding<String> {
        Binding(
            get: { editor.template?.description ?? template.description },
            set: { newValue in
                editor.change { $0.description = newValue }
            }
        )
    }

    private func bindingForPrompt(_ template: Template) -> Binding<String> {
        Binding(
            get: { editor.template?.promptText ?? template.promptText },
            set: { newValue in
                editor.change { $0.promptText = newValue }
            }
        )
    }

    // MARK: - Actions

    private func addNewTemplate() {
        let newTemplate = Template.makeUserTemplate(name: "New Template", description: "", promptText: "")
        Task {
            do {
                try await state.templateStore.addUserTemplate(newTemplate)
                await loadTemplates(); selectedID = newTemplate.id
            } catch { persistenceError = error.localizedDescription }
        }
    }

    private func deleteTemplate(id: String) {
        Task {
            guard await editor.delete(id: id, using: state.templateStore) else { return }
            if selectedID == id { selectedID = nil }
            templateToDelete = nil
            await loadTemplates()
        }
    }

    private func requestDelete(id: String) {
        selectedID = id
        Task {
            await editor.select(id: id, using: state.templateStore)
            guard editor.template?.id == id else { return }
            templateToDelete = id; showDeleteConfirmation = true
        }
    }
    private func resetBuiltIn(id: String) {
        Task { if await editor.reset(id: id, using: state.templateStore) { await loadTemplates() } }
    }

    private func isOverridden(_ template: Template) -> Bool {
        guard let builtIn = TemplateStore.builtInDefaults.first(where: { $0.id == template.id }) else {
            return false
        }
        return template.promptText != builtIn.promptText
            || template.description != builtIn.description
    }

    private func loadTemplates() async {
        let store = state.templateStore
        let current = await store.allTemplates()
        guard state.templateStore === store else { return }
        templates = current
        await editor.select(id: selectedID, using: store)
    }
    private func templateComparison(_ comparison: TemplateEditingState.Comparison) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compare Template Versions").font(.title2)
            Text("Keep My Edits keeps only the fields you edited. Save Template applies them against this reviewed version.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                templateVersion("Your draft", comparison.draft)
                templateVersion("Latest in library", comparison.latest.template)
            }
            HStack {
                Button("Cancel") { editor.comparison = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Latest") { editor.acceptComparison(keepingEdits: false) }
                Button("Keep My Edits") { editor.acceptComparison(keepingEdits: true) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 680, minHeight: 420)
    }
    private func templateVersion(_ title: String, _ template: Template) -> some View {
        GroupBox(title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(template.name).font(.headline)
                    Text(template.description).foregroundStyle(.secondary)
                    Text(template.promptText).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
