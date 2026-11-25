// © 2026 High Gain Design. All rights reserved.
import SwiftUI
import HiDockKit

struct SharedLibraryReviewView: View {
    @Bindable var state: AppState
    let onClose: () -> Void
    @State private var selected: UUID?
    @State private var selections: [String: String] = [:]
    private var review: SharedLibraryReviewState { state.sharedLibrary.review }
    private var item: SharedLibraryReviewState.Item? { review.items.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Shared Library Review").font(.title2)
                    Text(state.library.store.baseDirectory.lastPathComponent).foregroundStyle(.secondary)
                }
                Spacer()
                if review.isLoading || review.isApplying { ProgressView().controlSize(.small).accessibilityLabel("Updating review") }
                Button("Reload Choices") { Task { await reload() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(review.isApplying || review.isLoading || state.sharedLibrary.coordinator == nil)
            }.padding()
            Divider()
            HSplitView {
                List(review.items, selection: $selected) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                        Text("\(entry.fields.count) changes to review").font(.caption).foregroundStyle(.secondary)
                    }.tag(entry.id)
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                ScrollView {
                    if let item {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(item.title).font(.headline)
                            Text(item.snapshot.state.lifecycle == .deleted
                                ? (item.snapshot.state.kind == .template
                                    ? "This template is marked for deletion. Its competing content is retained for review."
                                    : "This recording is marked for deletion. Resolve its competing content before cleanup can continue.")
                                : "Choose the values to keep. Independent changes have already been combined.")
                                .foregroundStyle(.secondary)
                            ForEach(item.visibleFields(selections: selections)) { field in
                                SharedReviewFieldView(field: field, selection: Binding(
                                    get: { selections[field.id] }, set: { selections[field.id] = $0 }))
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: review.isLoading ? "arrow.triangle.2.circlepath" : "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                            Text(review.isLoading ? "Loading shared library review…" : (review.items.isEmpty ? "No competing edits to review" : "Select an item to compare its changes"))
                            Text("Pending file operations are reviewed separately.").font(.caption).foregroundStyle(.secondary)
                        }.padding(32).frame(maxWidth: .infinity)
                    }
                }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if let message = review.message {
                Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top])
            }
            HStack {
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                if state.sharedLibrary.phase == .readOnly { Text("Join this library before making changes.").font(.caption).foregroundStyle(.secondary) }
                Button("Apply Reviewed Choices") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }.padding()
        }
        .frame(minWidth: 640, minHeight: 420)
        .task(id: state.sharedLibrary.revision) { await reload() }
        .onChange(of: selected) { _, _ in selections = [:] }
        .onChange(of: item?.reviewSignature) { _, _ in selections = [:] }
        .onChange(of: review.revision) { _, _ in
            if !review.items.contains(where: { $0.id == selected }) { selected = review.items.first?.id }
        }
    }
    private var canApply: Bool {
        guard let item, state.sharedLibrary.phase == .ready, !review.isApplying, !review.isLoading else { return false }
        let fields = item.visibleFields(selections: selections).filter { !$0.choices.isEmpty }
        return !fields.isEmpty && fields.allSatisfy { field in field.choices.contains { $0.id == selections[field.id] && $0.isAvailable } }
    }
    private func reload() async {
        guard let coordinator = state.sharedLibrary.coordinator else { review.clear(); return }
        await review.refresh(using: coordinator)
        if selected == nil { selected = review.items.first?.id }
    }
    private func apply() {
        guard let item, let coordinator = state.sharedLibrary.coordinator else { return }
        let choices = selections
        Task {
            if await review.apply(item: item, selections: choices, using: coordinator), state.sharedLibrary.coordinator === coordinator {
                await state.refreshAll()
            }
        }
    }
}

private struct SharedReviewFieldView: View {
    let field: SharedLibraryReviewState.Field
    @Binding var selection: String?
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let explanation = field.explanation { Text(explanation).font(.callout).foregroundStyle(.secondary) }
                if !field.choices.isEmpty {
                    Picker(field.title, selection: $selection) {
                        Text("Choose a value…").tag(nil as String?)
                        ForEach(field.choices) { choice in Text(choice.comparisonTitle).tag(Optional(choice.id)).disabled(!choice.isAvailable) }
                    }.labelsHidden().accessibilityLabel(field.title)
                    ForEach(field.choices) { choice in
                        DisclosureGroup("Compare: " + choice.comparisonTitle) {
                            Text(choice.detail).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityLabel("Read " + choice.comparisonTitle)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        } label: { Text(field.title).font(.headline) }
    }
}
