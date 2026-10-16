// © 2026 High Gain Design. All rights reserved.
import SwiftUI
import HiDockKit

struct PendingRecordingFilesView: View {
    @Bindable var state: AppState
    let onClose: () -> Void
    @State private var selected: UUID?
    private var model: RecordingFileReviewState { state.sharedLibrary.fileReview }
    private var item: SharedRecordingOperationReview? { model.items.first { $0.id == selected } }
    private var preparation: RecordingFileReviewState.DeletionPreparation? { model.deletionPreparations.first { $0.id == selected } }
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
                List(selection: $selected) {
                    ForEach(model.items) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                            Text(status(row)).font(.caption).foregroundStyle(.secondary)
                        }.tag(row.id)
                    }
                    ForEach(model.deletionPreparations) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                            Text("Cleanup needs preparation").font(.caption).foregroundStyle(.secondary)
                        }.tag(row.id)
                    }
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
                                if item.canReplan {
                                    Button("Review Updated Plan…") {
                                        guard let coordinator = state.sharedLibrary.coordinator else { return }
                                        Task { await model.prepareUpdatedPlan(item, using: coordinator) }
                                    }.disabled(model.isWorking || model.isLoading)
                                }
                                Button("Resume") { perform(.resume, item) }
                                    .disabled(!item.canResume || model.isWorking)
                                    .accessibilityLabel("Resume file change for " + item.title)
                            }
                            if model.canKeepForReview(id: item.id) { keepForReviewButton(id: item.id) }
                            if !item.canResume && !item.canAcknowledge && !item.needsReplanning && !item.hasActiveWork && item.waitingForMacs.isEmpty {
                                Text("Resume this change on the Mac that started it.").foregroundStyle(.secondary)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    } else if let preparation {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(preparation.title).font(.headline)
                            Text("Deletion is saved, but cleanup has not been prepared. Existing files are protected.")
                            Text("Make the recording and its companion files available, review any external changes, then retry. Participating Macs must approve before removal.").foregroundStyle(.secondary)
                            Button("Retry Cleanup Preparation") {
                                guard let coordinator = state.sharedLibrary.coordinator else { return }
                                Task { if await model.prepareDeletion(preparation, using: coordinator), state.sharedLibrary.coordinator === coordinator { await state.refreshAll() } }
                            }.disabled(model.isWorking || model.isLoading || state.sharedLibrary.phase != .ready)
                                .accessibilityLabel("Retry cleanup preparation for " + preparation.title)
                            keepForReviewButton(id: preparation.id)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(model.isLoading ? "Loading pending files…" : model.inspectionFailed ? "Some file changes could not be inspected" : model.visibleIDs.isEmpty ? "No pending recording file changes" : "Select a recording to review its file change")
                            .foregroundStyle(.secondary).padding(32).frame(maxWidth: .infinity)
                    }
                }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if let message = model.message { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top]) }
            HStack { Button("Close", action: onClose).keyboardShortcut(.cancelAction); Spacer() }.padding()
        }.frame(minWidth: 640, minHeight: 420)
        .sheet(item: Binding(get: { model.updatedPlan }, set: { if $0 == nil { model.dismissUpdatedPlan() } })) { preview in
            let plan = preview.review
            VStack(alignment: .leading, spacing: 16) {
                Text("Review Updated File Plan").font(.title2)
                Text(plan.isDeletion ? "Review deletion cleanup for the remaining files. Removal waits for approval from participating Macs." : "Move the available recording and companion files to the current recording location.")
                Text("Current files").font(.headline)
                ScrollView { VStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.sources, id: \.self) { Text($0).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                if !plan.isDeletion {
                    Text("Destination").font(.headline)
                    Text(plan.destination).textSelection(.enabled)
                }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { model.dismissUpdatedPlan() }.keyboardShortcut(.cancelAction).disabled(model.isWorking)
                    Spacer()
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Button("Apply Updated Plan") {
                        guard let coordinator = state.sharedLibrary.coordinator else { return }
                        Task {
                            if await model.applyUpdatedPlan(preview, using: coordinator), state.sharedLibrary.coordinator === coordinator { await state.refreshAll() }
                        }
                    }.keyboardShortcut(.defaultAction).disabled(model.isWorking || model.isLoading)
                }
            }.padding(24).frame(width: 480).interactiveDismissDisabled(model.isWorking)
        }
        .task(id: state.sharedLibrary.revision) { await reload() }
        .onChange(of: model.visibleIDs) { _, ids in if !ids.contains(where: { $0 == selected }) { selected = ids.first } }
    }
    private func keepForReviewButton(id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To compare or recover externally changed files, keep the recording first. You can delete it again after review. Files already removed are not restored automatically.")
                .foregroundStyle(.secondary)
            Button("Keep Recording and Review Files") {
                guard let coordinator = state.sharedLibrary.coordinator else { return }
                Task {
                    if await model.keepForReview(id: id, using: coordinator), state.sharedLibrary.coordinator === coordinator {
                        await state.refreshAll()
                        guard state.sharedLibrary.coordinator === coordinator else { return }
                        state.sharedLibrary.reviewTab = .externalFiles
                        state.sharedLibrary.showsReview = true
                    }
                }
            }.disabled(model.isWorking || model.isLoading || state.sharedLibrary.phase != .ready)
        }
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
        if selected == nil { selected = model.visibleIDs.first }
    }
    private func perform(_ action: RecordingFileReviewState.Action, _ item: SharedRecordingOperationReview) {
        guard let coordinator = state.sharedLibrary.coordinator else { return }
        Task {
            if await model.perform(action, review: item, using: coordinator), state.sharedLibrary.coordinator === coordinator { await state.refreshAll() }
        }
    }
}
