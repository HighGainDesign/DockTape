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
                            if item.purpose == .retain { Text("Keep this folder by reviewing its current files. The previous deletion will not restart.") }
                            if item.purpose == .delete { Text("Continue deletion of this folder after related recordings and folders have the required approvals. Unknown files are preserved for review.") }
                            if item.canReviewDeletionScope { Text("The child list changed. Review the updated list before preparing deletions.").foregroundStyle(.secondary) }
                            else if item.canReviewCleanupPlan { Text("This Mac completed a rename before receiving the deletion. Review a separate cleanup plan after pending child files are removed.").foregroundStyle(.secondary) }
                            else if item.needsReplanning { Text("Competing changes prevent this plan from continuing. Review the competing edits before trying again.").foregroundStyle(.secondary) }
                            if !item.waitingForMacs.isEmpty { Text("Waiting for: " + item.waitingForMacs.joined(separator: ", ")).foregroundStyle(.secondary) }
                            Text("Paths involved").font(.headline)
                            ForEach(item.paths, id: \.self) { Text($0).textSelection(.enabled) }
                            VStack(alignment: .leading, spacing: 8) {
                                if item.purpose == .delete {
                                    Button("Approve Folder Deletion on This Mac") { perform(.acknowledge, item) }
                                        .disabled(!item.canAcknowledge || disabled)
                                        .accessibilityLabel("Approve deletion of folder " + item.name + " on this Mac")
                                }
                                if item.canReviewDeletionScope {
                                    Button("Review Updated Child List…") {
                                        guard let coordinator = state.sharedLibrary.coordinator else { return }
                                        Task { await model.prepareDeletionScope(item, using: coordinator) }
                                    }.disabled(disabled)
                                }
                                if item.canPrepareChildren {
                                    Button("Prepare Child Deletions") { perform(.prepareChildren, item) }
                                        .disabled(disabled)
                                        .accessibilityLabel("Prepare child deletions in " + item.name)
                                }
                                if item.canReviewCleanupPlan {
                                    Button("Review Folder Cleanup Plan…") {
                                        guard let coordinator = state.sharedLibrary.coordinator else { return }
                                        Task { await model.prepareCleanupPlan(item, using: coordinator) }
                                    }.disabled(disabled)
                                        .accessibilityLabel("Review cleanup plan for " + item.name)
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
        .sheet(item: Binding(get: { model.deletionScope }, set: { if $0 == nil { model.dismissDeletionScope() } })) { scope in
            VStack(alignment: .leading, spacing: 16) {
                Text("Review Updated Child List").font(.title2)
                Text(scope.path).font(.headline).textSelection(.enabled)
                Text("Review the current recordings and folders included in this deletion. Saving the list removes no files and grants no cleanup approval. Unknown files are preserved.")
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(scope.members, id: \.state.id) { member in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.path).textSelection(.enabled)
                                Text(member.state.lifecycle == .deleted ? "Already pending deletion; original cleanup plan is preserved." : "Will be prepared for deletion in a separate step.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if scope.members.isEmpty { Text("No owned child recordings or folders.").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { model.dismissDeletionScope() }.keyboardShortcut(.cancelAction).disabled(model.isWorking)
                    Spacer()
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Button("Save Child List") {
                        guard let coordinator = state.sharedLibrary.coordinator else { return }
                        Task { if await model.applyDeletionScope(using: coordinator), state.sharedLibrary.coordinator === coordinator { await state.refreshAll() } }
                    }.keyboardShortcut(.defaultAction).disabled(model.isWorking || model.isLoading)
                        .accessibilityLabel("Save reviewed child list for " + scope.path)
                }
            }.padding(24).frame(width: 520).interactiveDismissDisabled(model.isWorking)
        }
        .sheet(item: Binding(get: { model.cleanupPlan }, set: { if $0 == nil { model.dismissCleanupPlan() } })) { plan in
            VStack(alignment: .leading, spacing: 16) {
                Text("Review Folder Cleanup Plan").font(.title2)
                Text(plan.path).font(.headline).textSelection(.enabled)
                Text("This Mac completed its earlier rename. Save a separate plan for removing the now-empty folder. Saving removes nothing, preserves the rename progress and grants no deletion approval.")
                if !plan.retainedPaths.isEmpty {
                    Text("Earlier locations remain protected").font(.headline)
                    ScrollView { VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.retainedPaths, id: \.self) { Text($0).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                    Text("If files reappear at an earlier location, cleanup stops for review. Unknown files are preserved.").font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { model.dismissCleanupPlan() }.keyboardShortcut(.cancelAction).disabled(model.isWorking)
                    Spacer()
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Button("Save Cleanup Plan") {
                        guard let coordinator = state.sharedLibrary.coordinator else { return }
                        Task { if await model.applyCleanupPlan(using: coordinator), state.sharedLibrary.coordinator === coordinator { await state.refreshAll() } }
                    }.keyboardShortcut(.defaultAction).disabled(model.isWorking || model.isLoading)
                        .accessibilityLabel("Save reviewed cleanup plan for " + plan.path)
                }
            }.padding(24).frame(width: 520).interactiveDismissDisabled(model.isWorking)
        }
        .task(id: state.sharedLibrary.revision) { await reload() }
        .onChange(of: model.items.map(\.id)) { _, ids in if !ids.contains(where: { $0 == selected }) { selected = ids.first } }
    }
    private var disabled: Bool { model.isWorking || model.isLoading || state.sharedLibrary.phase != .ready }
    private func status(_ row: SharedFolderOperationReview) -> String {
        if row.needsReplanning { return "Needs plan review" }
        if row.hasActiveWork { return "Waiting for active work" }
        if !row.waitingForMacs.isEmpty { return "Waiting for folder approval" }
        if row.purpose == .retain { return "Folder retention needs review" }
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
