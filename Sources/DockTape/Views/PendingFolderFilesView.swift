// © 2026 High Gain Design. All rights reserved.
import SwiftUI
import HiDockKit

struct PendingFolderFilesView: View {
    @Bindable var state: AppState
    let onClose: () -> Void
    @State private var selected: UUID?
    private var model: FolderFileReviewState { state.sharedLibrary.folderReview }
    private var item: SharedFolderOperationReview? { model.items.first { $0.id == selected } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pending Folder Changes").font(.title2)
                Spacer()
                if model.isLoading || model.isWorking { ProgressView().controlSize(.small).accessibilityLabel("Updating folder review") }
                Button("Reload") { Task { await reload() } }.keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isLoading || model.isWorking)
            }.padding()
            Divider()
            HSplitView {
                List(model.items, selection: $selected) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name)
                        Text(status(row)).font(.caption).foregroundStyle(.secondary)
                    }.tag(row.id)
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                ScrollView {
                    if let item {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(item.name).font(.headline)
                            Text(status(item))
                            if item.purpose == .delete { Text("Continue deletion of this folder after related recordings and folders have the required approvals. Unknown files are preserved for review.") }
                            if item.needsReplanning { Text("Competing changes prevent this plan from continuing. Review the competing edits before trying again.").foregroundStyle(.secondary) }
                            if !item.waitingForMacs.isEmpty { Text("Waiting for: " + item.waitingForMacs.joined(separator: ", ")).foregroundStyle(.secondary) }
                            Text("Paths involved").font(.headline)
                            ForEach(item.paths, id: \.self) { Text($0).textSelection(.enabled) }
                            HStack {
                                if item.purpose == .delete {
                                    Button("Approve Folder Deletion on This Mac") { perform(.acknowledge, item) }
                                        .disabled(!item.canAcknowledge || disabled)
                                        .accessibilityLabel("Approve deletion of folder " + item.name + " on this Mac")
                                }
                                if item.canReplan {
                                    Button("Review Updated Plan…") {
                                        guard let coordinator = state.sharedLibrary.coordinator else { return }
                                        Task { await model.prepareUpdatedPlan(item, using: coordinator) }
                                    }.disabled(disabled)
                                }
                                Button(item.purpose == .delete ? "Continue Folder Deletion" : "Resume Folder Change") { perform(.resume, item) }
                                    .disabled(!item.canResume || disabled)
                                    .accessibilityLabel("Resume folder change for " + item.name)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(model.isLoading ? "Loading folder changes…" : model.inspectionFailed ? "Some folder changes could not be inspected" : model.items.isEmpty ? "No pending folder changes" : "Select a folder to review its change")
                            .foregroundStyle(.secondary).padding(32).frame(maxWidth: .infinity)
                    }
                }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if let message = model.message { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top]) }
            HStack { Button("Close", action: onClose).keyboardShortcut(.cancelAction); Spacer() }.padding()
        }.frame(minWidth: 640, minHeight: 420)
        .sheet(item: Binding(get: { model.updatedPlan }, set: { if $0 == nil { model.dismissUpdatedPlan() } })) { plan in
            VStack(alignment: .leading, spacing: 16) {
                Text("Review Updated Folder Plan").font(.title2)
                Text(plan.source == plan.destination ? "Keep the available directory at the selected location after verifying its files. Child recordings keep their identities." : "Move the available directory and its files to the selected folder location. Child recordings keep their identities.")
                Text("Current folder").font(.headline)
                Text(plan.source).textSelection(.enabled)
                Text("Selected location").font(.headline)
                Text(plan.destination).textSelection(.enabled)
                ScrollView { VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.files, id: \.self) { Text($0).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { model.dismissUpdatedPlan() }.keyboardShortcut(.cancelAction).disabled(model.isWorking)
                    Spacer()
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Button("Apply Updated Plan") {
                        guard let coordinator = state.sharedLibrary.coordinator else { return }
                        Task { if await model.applyUpdatedPlan(using: coordinator), state.sharedLibrary.coordinator === coordinator { await state.refreshAll() } }
                    }.keyboardShortcut(.defaultAction).disabled(model.isWorking || model.isLoading)
                        .accessibilityLabel("Apply reviewed folder location " + plan.destination)
                }
            }.padding(24).frame(width: 500).interactiveDismissDisabled(model.isWorking)
        }
        .task(id: state.sharedLibrary.revision) { await reload() }
        .onChange(of: model.items.map(\.id)) { _, ids in if !ids.contains(where: { $0 == selected }) { selected = ids.first } }
    }
    private var disabled: Bool { model.isWorking || model.isLoading || state.sharedLibrary.phase != .ready }
    private func status(_ row: SharedFolderOperationReview) -> String {
        if row.needsReplanning { return "Needs plan review" }
        if row.hasActiveWork { return "Waiting for active work" }
        if !row.waitingForMacs.isEmpty { return "Waiting for folder approval" }
        return row.purpose == .delete ? "Folder deletion pending" : row.purpose == .rename ? "Folder rename pending" : "Folder creation pending"
    }
    private func reload() async {
        guard let coordinator = state.sharedLibrary.coordinator else { model.clear(); return }
        await model.refresh(using: coordinator)
        if selected == nil { selected = model.items.first?.id }
    }
    private func perform(_ action: FolderFileReviewState.Action, _ item: SharedFolderOperationReview) {
        guard let coordinator = state.sharedLibrary.coordinator else { return }
        Task {
            if await model.perform(action, review: item, using: coordinator), state.sharedLibrary.coordinator === coordinator { await state.refreshAll() }
        }
    }
}
