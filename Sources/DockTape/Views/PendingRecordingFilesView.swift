// © 2026 High Gain Design. All rights reserved.
import SwiftUI
import HiDockKit

struct PendingRecordingFilesView: View {
    @Bindable var state: AppState
    let onClose: () -> Void
    @State private var selected: UUID?
    private var model: RecordingFileReviewState { state.sharedLibrary.fileReview }
    private var item: SharedRecordingOperationReview? { model.items.first { $0.id == selected } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pending Recording Files").font(.title2)
                Spacer()
                if model.isLoading || model.isWorking { ProgressView().controlSize(.small).accessibilityLabel("Updating file review") }
                Button("Reload") { Task { await reload() } }.keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isLoading || model.isWorking)
            }.padding()
            Divider()
            HSplitView {
                List(model.items, selection: $selected) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title)
                        Text(status(row)).font(.caption).foregroundStyle(.secondary)
                    }.tag(row.id)
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                ScrollView {
                    if let item {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(item.title).font(.headline)
                            Text(status(item))
                            if item.purpose == .delete {
                                Text("Delete this recording and its companion files after participating Macs approve.")
                            } else if item.purpose == .replaceAudio {
                                Text("Replace this recording’s audio after participating Macs approve.")
                            }
                            if item.needsReplanning { Text("A newer edit prevents this plan from continuing. The affected files need a new plan review.").foregroundStyle(.secondary) }
                            if !item.waitingForMacs.isEmpty { Text("Waiting for: " + item.waitingForMacs.joined(separator: ", ")).foregroundStyle(.secondary) }
                            Text("Files involved").font(.headline)
                            ForEach(item.paths, id: \.self) { path in Text(path).textSelection(.enabled) }
                            HStack {
                                if !item.waitingForMacs.isEmpty {
                                    Button(item.purpose == .delete ? "Approve Deletion on This Mac" : "Approve Audio Replacement") { perform(.acknowledge, item) }
                                        .disabled(!item.canAcknowledge || model.isWorking)
                                        .accessibilityLabel((item.purpose == .delete ? "Approve deletion of " : "Approve audio replacement for ") + item.title + " on this Mac")
                                }
                                Button("Resume") { perform(.resume, item) }
                                    .disabled(!item.canResume || model.isWorking)
                                    .accessibilityLabel("Resume file change for " + item.title)
                            }
                            if !item.canResume && !item.canAcknowledge && !item.needsReplanning && !item.hasActiveWork && item.waitingForMacs.isEmpty {
                                Text("Resume this change on the Mac that started it.").foregroundStyle(.secondary)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(model.isLoading ? "Loading pending files…" : model.inspectionFailed ? "Some file changes could not be inspected" : model.items.isEmpty ? "No pending recording file changes" : "Select a recording to review its file change")
                            .foregroundStyle(.secondary).padding(32).frame(maxWidth: .infinity)
                    }
                }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if let message = model.message { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top]) }
            HStack { Button("Close", action: onClose).keyboardShortcut(.cancelAction); Spacer() }.padding()
        }.frame(minWidth: 640, minHeight: 420)
        .task(id: state.sharedLibrary.revision) { await reload() }
        .onChange(of: model.items.map(\.id)) { _, ids in if !ids.contains(where: { $0 == selected }) { selected = ids.first } }
    }
    private func status(_ row: SharedRecordingOperationReview) -> String {
        if row.needsReplanning { return "Needs plan review" }
        if row.hasActiveWork { return "Waiting for active work" }
        if !row.waitingForMacs.isEmpty { return "Waiting for approval" }
        return row.canResume ? "Ready to resume" : "Pending on another Mac"
    }
    private func reload() async {
        guard let coordinator = state.sharedLibrary.coordinator else { model.clear(); return }
        await model.refresh(using: coordinator)
        if selected == nil { selected = model.items.first?.id }
    }
    private func perform(_ action: RecordingFileReviewState.Action, _ item: SharedRecordingOperationReview) {
        guard let coordinator = state.sharedLibrary.coordinator else { return }
        Task {
            if await model.perform(action, review: item, using: coordinator), state.sharedLibrary.coordinator === coordinator { await state.refreshAll() }
        }
    }
}
