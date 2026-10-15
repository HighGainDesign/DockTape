// © 2026 High Gain Design. All rights reserved.
import SwiftUI

struct ExternalSidecarReviewView: View {
    @Bindable var state: AppState
    let onClose: () -> Void
    @State private var selected: String?
    private var model: ExternalSidecarReviewState { state.sharedLibrary.externalReview }
    private var item: ExternalSidecarReviewState.Item? { model.items.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Files Changed Outside DockTape").font(.title2)
                    Text("Compare the file with DockTape’s current content before choosing.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoading || model.isApplying { ProgressView().controlSize(.small).accessibilityLabel("Checking changed files") }
                Button("Reload Files") { Task { await reload() } }
                    .disabled(model.isLoading || model.isApplying)
            }.padding()
            Divider()
            HSplitView {
                List(model.items, selection: $selected) { entry in Text(entry.title).tag(entry.id) }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let item {
                            Text(item.title).font(.headline)
                            if let review = item.review {
                                GroupBox("Current in DockTape") { preview(review.currentText) }
                                GroupBox("Changed file") {
                                    preview(review.changedText ?? "This file cannot be read as a valid " + review.component.rawValue + ". Restore the current content, or fix the file outside DockTape and reload.")
                                }
                                Text("Your choice replaces this file and updates its readable exports. Unrelated recordings are unchanged.")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else if let error = item.error { Text(error).foregroundStyle(.orange) }
                        } else {
                            Text(model.isLoading ? "Checking files…" : (model.items.isEmpty ? "No external file changes found" : "Select a file to compare"))
                                .foregroundStyle(.secondary).padding(24)
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if let message = model.message { Text(message).foregroundStyle(.orange).padding([.horizontal, .top]).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore Current Content") { apply(useChangedFile: false) }.disabled(!canApply)
                Button("Use Changed File") { apply(useChangedFile: true) }
                    .disabled(!canApply || item?.review?.changedText == nil)
            }.padding()
        }
        .task(id: state.sharedLibrary.revision) { await reload() }
        .onChange(of: model.items.map(\.id)) { _, ids in if !ids.contains(selected ?? "") { selected = ids.first } }
    }
    private var canApply: Bool { item?.review != nil && state.sharedLibrary.phase == .ready && !model.isApplying }
    private func preview(_ text: String) -> some View {
        Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(4)
    }
    private func reload() async {
        guard let coordinator = state.sharedLibrary.coordinator else { model.clear(); return }
        await model.refresh(using: coordinator)
        if selected == nil { selected = model.items.first?.id }
    }
    private func apply(useChangedFile: Bool) {
        guard let item, let coordinator = state.sharedLibrary.coordinator else { return }
        Task {
            if await model.apply(item, useChangedFile: useChangedFile, using: coordinator), state.sharedLibrary.coordinator === coordinator { await state.refreshAll() }
        }
    }
}
