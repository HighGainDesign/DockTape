import SwiftUI
import HiDockKit

struct TemplateSettingsView: View {
    @Bindable var state: AppState

    @State private var templates: [Template] = []
    @State private var selectedID: String?
    @State private var editingTemplate: Template?
    @State private var showDeleteConfirmation = false
    @State private var templateToDelete: String?

    // Debounce save
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        HSplitView {
            listPanel
                .frame(minWidth: 160, idealWidth: 180)

            detailPanel
                .frame(minWidth: 280)
        }
        .task {
            await loadTemplates()
        }
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
                                        templateToDelete = t.id
                                        showDeleteConfirmation = true
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedID) { _, newID in
                editingTemplate = templates.first { $0.id == newID }
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
            if let template = editingTemplate {
                templateForm(template)
            } else {
                VStack {
                    Spacer()
                    Text("Select a template")
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
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
                    .border(.separator)
            }

            HStack {
                Spacer()
                if template.isBuiltIn {
                    Button("Reset to Default") {
                        resetBuiltIn(id: template.id)
                    }
                    .disabled(!isOverridden(template))
                } else {
                    Button("Delete Template", role: .destructive) {
                        templateToDelete = template.id
                        showDeleteConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings with debounced save

    private func bindingForName(_ template: Template) -> Binding<String> {
        Binding(
            get: { editingTemplate?.name ?? template.name },
            set: { newValue in
                editingTemplate?.name = newValue
                debouncedSave()
            }
        )
    }

    private func bindingForDescription(_ template: Template) -> Binding<String> {
        Binding(
            get: { editingTemplate?.description ?? template.description },
            set: { newValue in
                editingTemplate?.description = newValue
                debouncedSave()
            }
        )
    }

    private func bindingForPrompt(_ template: Template) -> Binding<String> {
        Binding(
            get: { editingTemplate?.promptText ?? template.promptText },
            set: { newValue in
                editingTemplate?.promptText = newValue
                debouncedSave()
            }
        )
    }

    // MARK: - Actions

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let template = editingTemplate else { return }
            await state.templateStore.update(template)
            await loadTemplates()
        }
    }

    private func addNewTemplate() {
        let newTemplate = Template.makeUserTemplate(
            name: "New Template",
            description: "",
            promptText: ""
        )
        Task {
            await state.templateStore.addUserTemplate(newTemplate)
            await loadTemplates()
            selectedID = newTemplate.id
        }
    }

    private func deleteTemplate(id: String) {
        Task {
            await state.templateStore.delete(id: id)
            if selectedID == id {
                selectedID = nil
                editingTemplate = nil
            }
            templateToDelete = nil
            await loadTemplates()
        }
    }

    private func resetBuiltIn(id: String) {
        Task {
            await state.templateStore.resetToDefault(id: id)
            await loadTemplates()
            editingTemplate = templates.first { $0.id == id }
        }
    }

    private func isOverridden(_ template: Template) -> Bool {
        guard let builtIn = TemplateStore.builtInDefaults.first(where: { $0.id == template.id }) else {
            return false
        }
        return template.promptText != builtIn.promptText
            || template.description != builtIn.description
    }

    private func loadTemplates() async {
        templates = await state.templateStore.allTemplates()
        // Refresh editingTemplate if it's still selected
        if let id = selectedID {
            editingTemplate = templates.first { $0.id == id }
        }
    }
}
