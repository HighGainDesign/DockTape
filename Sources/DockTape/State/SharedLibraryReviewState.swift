// © 2026 High Gain Design. All rights reserved.
import Foundation
import Observation
import HiDockKit

@Observable @MainActor
final class SharedLibraryReviewState {
    struct Choice: Identifiable {
        let id: String
        let value: SharedFieldValue
        let label: String
        let detail: String
        let isAvailable: Bool
        let sources: [String]
        var comparisonTitle: String { sources.isEmpty ? label : label + " · " + sources.joined(separator: ", ") }
    }
    struct Field: Identifiable {
        let id: String
        let title: String
        let choices: [Choice]
        let explanation: String?
        let component: SharedComponent?
        let generation: UUID?
        let isOlderEdits: Bool
    }
    struct Item: Identifiable {
        var id: UUID { snapshot.state.id }
        let title: String
        let snapshot: SharedLibraryViewSnapshot
        let fields: [Field]
        let reviewSignature: String
        let folderRequests: [String: SharedFolderDeletionRequestReview]
        let recordingPaths: [String: SharedRecordingPathReview]
        let folderPaths: [String: SharedFolderPathReview]
        let folderLifecycles: [String: SharedFolderLifecycleReview]

        func visibleFields(selections: [String: String]) -> [Field] {
            if snapshot.state.lifecycle == .conflicted {
                return fields.filter { $0.id == "$lifecycle" }
            }
            if let path = fields.first(where: { $0.id == "recording.path" || $0.id == "folder.path" }) { return [path] }
            return fields.filter { field in
                guard let component = field.component, let generation = field.generation else { return true }
                let content = fields.first { $0.id == component.rawValue + ".content" }
                let selected = content.flatMap { row in row.choices.first { $0.id == selections[row.id] } }
                let selectedID: UUID?
                if case .document(let document)? = selected?.value { selectedID = document.id }
                else { selectedID = snapshot.state.currentDocument(for: component)?.id }
                return selectedID == generation
            }
        }
    }
    private(set) var items: [Item] = []
    private(set) var revision: UInt64 = 0
    private(set) var isLoading = false
    private(set) var isApplying = false
    private(set) var message: String?
    private var binding: SharedLibraryCoordinator?
    private var request = UUID()
    private var workID = UUID()
    private var action: Task<Bool, Never>?

    func clear() {
        request = UUID(); workID = UUID(); action?.cancel(); action = nil
        binding = nil; items = []; revision &+= 1; message = nil; isLoading = false; isApplying = false
    }
    func refresh(using coordinator: SharedLibraryCoordinator) async {
        if binding !== coordinator { clear(); binding = coordinator }
        let ticket = UUID(); request = ticket; isLoading = true; message = nil
        defer { if request == ticket { isLoading = false } }
        do {
            let views = try await coordinator.snapshots(kinds: [.recording, .folder, .template])
            guard request == ticket, binding === coordinator, !Task.isCancelled else { return }
            let conflicted = views.filter { !$0.state.conflicts.isEmpty }
            let labels: [UUID: String]
            if let library = conflicted.first?.libraryID {
                guard conflicted.allSatisfy({ $0.libraryID == library }) else { throw SharedLibraryCoordinatorError.differentBinding }
                labels = try await coordinator.writerLabels(libraryID: library)
            } else { labels = [:] }
            var loaded: [Item] = []
            for view in conflicted {
                let requests = view.state.kind == .folder ? try await coordinator.folderDeletionRequestChoices(view) : []
                let paths = view.state.kind == .recording ? try await coordinator.recordingPathChoices(view) : []
                let folders = view.state.kind == .folder ? try await coordinator.folderPathChoices(view) : []
                let lifecycle = view.state.kind == .folder ? try await coordinator.folderLifecycleChoices(view) : []
                loaded.append(Self.item(view, writerLabels: labels, folderRequests: requests, recordingPaths: paths, folderPaths: folders, folderLifecycles: lifecycle))
            }
            guard request == ticket, binding === coordinator, !Task.isCancelled else { return }
            items = loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            revision &+= 1
        } catch {
            if request == ticket, binding === coordinator { message = error.localizedDescription }
        }
    }
    func apply(item: Item, selections: [String: String], using coordinator: SharedLibraryCoordinator) async -> Bool {
        guard binding === coordinator, !isApplying, !isLoading else { return false }
        let fields = item.visibleFields(selections: selections).filter { !$0.choices.isEmpty }
        if let field = fields.first(where: { $0.id == "recording.path" }) {
            guard let selected = selections[field.id], let review = item.recordingPaths[selected], fields.count == 1 else { return false }
            return await applyRecordingPath(review, using: coordinator)
        }
        if let field = fields.first(where: { $0.id == "folder.path" }) {
            guard let selected = selections[field.id], let review = item.folderPaths[selected], fields.count == 1 else { return false }
            return await applyFolderPath(review, using: coordinator)
        }
        if let field = fields.first(where: { $0.id == "deletionRequest" }), item.snapshot.state.kind == .folder {
            guard let selected = selections[field.id], let review = item.folderRequests[selected], fields.count == 1 else { return false }
            return await applyFolderRequest(review, using: coordinator)
        }
        if item.snapshot.state.kind == .folder, let lifecycle = fields.first(where: { $0.id == "$lifecycle" }) {
            guard fields.count == 1, let selected = selections[lifecycle.id], let review = item.folderLifecycles[selected] else { return false }
            return await applyFolderLifecycle(review, using: coordinator)
        }
        let supportsLifecycle = item.snapshot.state.kind == .recording || item.snapshot.state.kind == .template
        let decidingLifecycle = supportsLifecycle && item.snapshot.state.lifecycle == .conflicted
        let preservingDeletion = supportsLifecycle && item.snapshot.state.lifecycle == .deleted
        guard !fields.isEmpty, item.snapshot.state.lifecycle == .alive || decidingLifecycle || preservingDeletion else { return false }
        // These mutations are one atomic owner-envelope commit. The temporary
        // restoration permits reviewed content edits; no alive state is published.
        var changes: [SharedLibraryMutation] = preservingDeletion ? [.restore] : []
        // Choose content before applying edits scoped to the chosen generation.
        for field in fields.sorted(by: { ($0.generation == nil ? 0 : 1) < ($1.generation == nil ? 0 : 1) }) {
            guard let choice = field.choices.first(where: { $0.id == selections[field.id] && $0.isAvailable }) else { return false }
            if decidingLifecycle {
                guard field.id == "$lifecycle", case .flag(let keep) = choice.value else { return false }
                changes.append(keep ? .restore : .delete)
            } else if let component = field.component {
                if field.isOlderEdits || field.id == component.rawValue + ".content" {
                    guard case .document(let document) = choice.value else { return false }
                    changes.append(.generation(document, component: component))
                } else if let generation = field.generation {
                    let prefix = "\(component.rawValue).edits.\(generation.uuidString.lowercased())."
                    changes.append(.generationEdit(component: component, generation: generation,
                        key: String(field.id.dropFirst(prefix.count)), value: choice.value))
                }
            } else { changes.append(.assign(field: field.id, value: choice.value)) }
        }
        if preservingDeletion { changes.append(.delete) }
        let ticket = request, work = UUID(); workID = work
        isApplying = true; message = nil
        let task = Task { [weak self] in
            do {
                guard try await coordinator.mayEdit() else { throw SharedLibraryCoordinatorError.enrollmentPending }
                try Task.checkCancellation()
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                let accepted = try await coordinator.resolve(.init(base: item.snapshot, changes: changes))
                var publication: String?
                if (decidingLifecycle || preservingDeletion) && accepted.state.kind == .recording {
                    if accepted.state.lifecycle == .deleted {
                        publication = "Deletion choice saved. Original files remain pending safe cleanup; deletion has not completed."
                        if accepted.state.conflicts.isEmpty {
                            do {
                                let outcome = try await coordinator.prepareReviewedDeletion(accepted)
                                publication = outcome.result == .complete ? "Deletion completed."
                                    : "Deletion choice saved. Open Pending Files to review or approve the remaining cleanup."
                            } catch {
                                publication = "Deletion choice saved. Cleanup could not be prepared yet; retry after sync finishes. Existing files remain protected."
                            }
                        } else { publication = "Deletion choice saved. Competing content still needs recovery review before files can be removed." }
                    } else { publication = "Recording kept with its edits. Review any remaining changes before continuing pending file operations." }
                } else if (decidingLifecycle || preservingDeletion) && accepted.state.kind == .template {
                    publication = accepted.state.lifecycle == .deleted
                        ? "Template deleted. Any remaining competing edits are retained for review."
                        : "Template kept with its edits. Review any remaining competing changes."
                }
                do { _ = try await coordinator.projectOutputs() }
                catch SharedProjectionWriteError.untracked(let path) { publication = "Choice saved. " + path + " changed outside DockTape and needs a file review before publishing." }
                catch { publication = (publication.map { $0 + " " } ?? "Choice saved. ") + "Readable files could not be updated yet. Reload the review or retry after sync finishes." }
                guard self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return true }
                if let publication { self.message = publication }
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                if error as? SharedLibraryCoordinatorError == .staleReview || error as? SharedLibraryRepositoryError == .staleRevision || error as? SharedEntityError == .staleGeneration || error as? SharedEntityError == .deletedOrConflictedLifecycle {
                    self.message = "This item changed during review. Reload the choices before deciding."
                } else if error as? SharedLibraryCoordinatorError == .enrollmentPending { self.message = "This Mac must join the shared library before applying choices." }
                else if error as? SharedLibraryCoordinatorError == .differentBinding { self.message = "The library changed. Reopen its review before deciding." }
                else if !(error is CancellationError) { self.message = "The choices could not be saved. Reload the review and try again." }
                return false
            }
        }
        action = task
        let result = await task.value
        if binding === coordinator, workID == work { isApplying = false; action = nil }
        return result
    }
    private func applyRecordingPath(_ review: SharedRecordingPathReview, using coordinator: SharedLibraryCoordinator) async -> Bool {
        let ticket = request, work = UUID(); workID = work
        isApplying = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                _ = try await coordinator.resolveRecordingPath(review)
                guard self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return true }
                self.message = "Location selected. Existing files are preserved. Review any remaining competing content, then open Pending Files to review the updated file plan."
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                if !(error is CancellationError) { self.message = "The recording, folders or participating Macs changed. Reload the location choices before deciding." }
                return false
            }
        }
        action = task
        let result = await task.value
        if binding === coordinator, workID == work { isApplying = false; action = nil }
        return result
    }
    private func applyFolderLifecycle(_ review: SharedFolderLifecycleReview, using coordinator: SharedLibraryCoordinator) async -> Bool {
        let ticket = request, work = UUID(); workID = work; isApplying = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                _ = try await coordinator.resolveFolderLifecycle(review)
                guard let self, self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return true }
                self.message = review.keep
                    ? "Folder kept. Child recording decisions are preserved. Open Pending Folders to review remaining file work."
                    : "Folder deletion selected. Files remain until the child scope and fresh approvals are reviewed in Pending Folders."
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                if !(error is CancellationError) { self.message = "The folder, its children or participating Macs changed. Reload its lifecycle choices before deciding." }
                return false
            }
        }
        action = task; let result = await task.value
        if binding === coordinator, workID == work { isApplying = false; action = nil }
        return result
    }
    private func applyFolderPath(_ review: SharedFolderPathReview, using coordinator: SharedLibraryCoordinator) async -> Bool {
        let ticket = request, work = UUID(); workID = work
        isApplying = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                _ = try await coordinator.resolveFolderPath(review)
                guard let self, self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return true }
                self.message = "Folder location selected. Existing files are preserved. Open Pending Folders to review the updated plan."
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                if !(error is CancellationError) { self.message = "The folder, its children or participating Macs changed. Reload the folder location choices before deciding." }
                return false
            }
        }
        action = task
        let result = await task.value
        if binding === coordinator, workID == work { isApplying = false; action = nil }
        return result
    }
    private func applyFolderRequest(_ review: SharedFolderDeletionRequestReview, using coordinator: SharedLibraryCoordinator) async -> Bool {
        let ticket = request, work = UUID(); workID = work
        isApplying = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                _ = try await coordinator.resolveFolderDeletionRequest(review)
                guard self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return true }
                self.message = "Deletion request selected. Files have not been removed. Open Pending Folders to review and continue cleanup."
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                if error as? SharedLibraryCoordinatorError == .staleReview || error as? SharedLibraryRepositoryError == .staleRevision {
                    self.message = "This folder changed during review. Reload the choices before deciding."
                } else if error as? SharedLibraryCoordinatorError == .enrollmentPending { self.message = "This Mac must join the shared library before applying choices." }
                else if !(error is CancellationError) { self.message = "The request could not be saved. Reload the review and try again." }
                return false
            }
        }
        action = task
        let result = await task.value
        if binding === coordinator, workID == work { isApplying = false; action = nil }
        return result
    }
    private static func item(_ snapshot: SharedLibraryViewSnapshot, writerLabels: [UUID: String], folderRequests requests: [SharedFolderDeletionRequestReview] = [], recordingPaths: [SharedRecordingPathReview] = [], folderPaths: [SharedFolderPathReview] = [], folderLifecycles: [SharedFolderLifecycleReview] = []) -> Item {
        let state = snapshot.state
        let requestChoices = Dictionary(uniqueKeysWithValues: requests.map { (identity($0.value), $0) })
        let title = text(state.value(for: state.kind == .recording ? "title" : "name"))
            ?? text(state.value(for: "initialPath")) ?? (state.kind == .template ? "Summary template" : "Library item")
        var fields: [Field] = []
        let pathChoices = Dictionary(recordingPaths.map { (identity(.text($0.destination)), $0) }, uniquingKeysWith: { first, _ in first })
        let lifecycleChoices = Dictionary(folderLifecycles.map { (identity(.flag($0.keep)), $0) }, uniquingKeysWith: { first, _ in first })
        let folderChoices = Dictionary(folderPaths.map { (identity(.text($0.destination)), $0) }, uniquingKeysWith: { first, _ in first })
        let folderConflict = state.kind == .folder && (state.fields["name"]?.isConflicted == true || state.fields["parent"]?.isConflicted == true)
        if folderConflict, state.lifecycle == .alive {
            let choices = folderPaths.map { review -> Choice in
                let contributors = Set(review.values.flatMap { sources($0.value, field: $0.key, state: state, labels: writerLabels) }).sorted()
                let name = review.values["name"].map { attributedPreview($0, field: "name", state: state, labels: writerLabels) } ?? ""
                let parents = review.values["parent"].map { sources($0, field: "parent", state: state, labels: writerLabels) } ?? []
                let parent = (review.destination as NSString).deletingLastPathComponent
                let detail = "Selected folder: " + review.destination + "\n\nName:\n" + name + "\n\nParent:\n" + sourceNote(parents) + (parent.isEmpty ? "Library root" : parent)
                    + "\n\nSelecting a location does not move or remove files. Review the updated directory plan in Pending Folders."
                return .init(id: identity(.text(review.destination)), value: .text(review.destination), label: review.destination, detail: detail, isAvailable: true, sources: contributors)
            }
            fields.append(.init(id: "folder.path", title: "Folder name and location", choices: choices,
                explanation: choices.isEmpty ? "The candidate folder locations conflict with another owner or an unavailable ancestor. Resolve the affected folders before choosing a location." : "Choose the complete folder location. Directory changes require a separate reviewed plan.", component: nil, generation: nil, isOlderEdits: false))
        }
        let pathConflict = state.kind == .recording && (state.fields["title"]?.isConflicted == true || state.fields["folder"]?.isConflicted == true)
        if pathConflict, state.lifecycle != .conflicted {
            let choices = recordingPaths.map { review -> Choice in
                let contributors = Set(review.values.flatMap { sources($0.value, field: $0.key, state: state, labels: writerLabels) }).sorted()
                let name = review.values["title"].map { attributedPreview($0, field: "title", state: state, labels: writerLabels) } ?? ""
                let folder = (review.destination as NSString).deletingLastPathComponent
                let folderSources = review.values["folder"].map { sources($0, field: "folder", state: state, labels: writerLabels) } ?? []
                let detail = "Selected path: " + review.destination + "\n\nName:\n" + name + "\n\nFolder:\n" + sourceNote(folderSources)
                    + (folder.isEmpty ? "Library root" : folder) + "\n\nSelecting a location does not move or remove files. Review the updated physical plan in Pending Files."
                return .init(id: identity(.text(review.destination)), value: .text(review.destination), label: review.destination, detail: detail, isAvailable: true, sources: contributors)
            }
            fields.append(.init(id: "recording.path", title: "Recording name and location", choices: choices,
                explanation: choices.isEmpty ? "The candidate locations are unavailable or conflict with another owner. Resolve the affected folders before choosing a location."
                    : "Choose the complete recording path. File changes remain subject to a separate reviewed plan.", component: nil, generation: nil, isOlderEdits: false))
        }
        for conflict in state.conflicts where conflict.inactiveGeneration == nil
            && !conflict.field.hasPrefix("externalAdoption.")
            && !conflict.field.hasPrefix("externalAdoptionGeneration.")
            && !(pathConflict && ["title", "folder"].contains(conflict.field))
            && !(folderConflict && ["name", "parent"].contains(conflict.field)) {
            let parts = conflict.field.split(separator: ".").map(String.init)
            let component = parts.first.flatMap(SharedComponent.init(rawValue:))
            let generation = parts.count >= 4 && parts[1] == "edits" ? UUID(uuidString: parts[2]) : nil
            let isContent = component != nil && parts.count == 2 && parts[1] == "content"
            let safeScalar = ["prompt", "description"].contains(conflict.field) || conflict.field == "metadata.mode" || (state.kind == .template && conflict.field == "name")
            let lifecycleChoice = (state.kind == .recording || state.kind == .template || state.kind == .folder) && state.lifecycle == .conflicted && conflict.field == "$lifecycle"
            let editableContent = state.lifecycle == .alive || ((state.kind == .recording || state.kind == .template) && state.lifecycle == .deleted)
            let folderRequest = state.kind == .folder && conflict.field == "deletionRequest" && (state.lifecycle == .alive || state.lifecycle == .deleted)
            let supported = folderRequest || lifecycleChoice || (editableContent && (isContent || generation != nil || safeScalar))
            let choices = supported ? conflict.values.compactMap { value -> Choice? in
                if isContent { guard case .document = value else { return nil } }
                let contributors = sources(value, field: conflict.field, state: state, labels: writerLabels)
                let origin = sourceNote(contributors)
                if folderRequest {
                    let id = identity(value)
                    guard let request = requestChoices[id] else {
                        return .init(id: id, value: value, label: "Unavailable deletion request", detail: origin + "This request could not be validated. It cannot authorize cleanup.", isAvailable: false, sources: contributors)
                    }
                    let detail = "Folder: " + request.path + "\n\n" + (request.members.isEmpty ? "No recorded children." : request.members.map(\.path).joined(separator: "\n"))
                        + "\n\nSelecting this request saves its scope. Files remain until cleanup is reviewed in Pending Folders."
                    return .init(id: id, value: value, label: "Delete " + request.path + " (\(request.members.count) items)", detail: origin + detail, isAvailable: true, sources: contributors)
                }
                if lifecycleChoice {
                    guard case .flag(let keep) = value else { return nil }
                    if state.kind == .folder {
                        guard let reviewed = lifecycleChoices[identity(value)] else { return nil }
                        let children = reviewed.members.map { member in
                            let status = member.state.lifecycle == .deleted ? "Pending deletion" : member.state.lifecycle == .alive ? "Kept" : "Needs review"
                            return member.path + " · " + status + "\n" + lifecyclePreview(member.state, labels: writerLabels)
                        }.joined(separator: "\n\n")
                        let detail = (keep ? "Keep the folder and cancel its pending deletion request. Child decisions and edits are preserved separately." : "Choose deletion for the folder. Children and original files remain protected until their scope and fresh cleanup approvals are reviewed.")
                            + "\n\n" + lifecyclePreview(state, labels: writerLabels) + "\n\n" + (children.isEmpty ? "No owned descendants." : children)
                        return .init(id: identity(value), value: value, label: keep ? "Keep Folder" : "Delete Folder", detail: origin + detail, isAvailable: true, sources: contributors)
                    }
                    let template = state.kind == .template
                    let label = template ? (keep ? "Keep Template and Edits" : "Delete Template") : (keep ? "Keep Recording and Edits" : "Delete Recording")
                    let explanation = template
                        ? (keep ? "Keep this template and its retained edits. Other competing changes still need review." : "Remove this template from the catalog. Its retained competing edits remain available for review.")
                        : (keep ? "Keep this recording and the retained edits below. Other competing changes will still need review." : "Hide this recording. Original files remain until safe cleanup is approved by the participating Macs.")
                    let detail = explanation + "\n\n" + lifecyclePreview(state, labels: writerLabels)
                    return .init(id: identity(value), value: value, label: label, detail: origin + detail, isAvailable: true, sources: contributors)
                }
                let detail = preview(value, field: conflict.field)
                let label = isContent ? contentLabel(value, component: component!) : detail
                let available: Bool
                if isContent, case .document(let document) = value {
                    available = component == .transcript ? (try? document.decode(Transcript.self)) != nil : (try? document.decode(Summary.self)) != nil
                } else { available = true }
                return .init(id: identity(value), value: value, label: label, detail: origin + detail, isAvailable: available, sources: contributors)
            }.sorted { ($0.label, $0.id) < ($1.label, $1.id) } : []
            var heading = fieldTitle(conflict.field)
            if component == .summary, let generation, parts.count >= 4,
               let document = state.fields["summary.content"]?.values.compactMap({ value -> SharedDocument? in if case .document(let document) = value, document.id == generation { return document }; return nil }).first,
               let summary = try? document.decode(Summary.self),
               let entry = summary.sections.flatMap({ $0.items ?? [] }).first(where: { $0.id.uuidString.lowercased() == parts.dropFirst(3).joined(separator: ".") }) {
                heading = "Action item: " + entry.text
            }
            fields.append(.init(id: conflict.field, title: heading, choices: choices,
                explanation: lifecycleChoice ? (state.kind == .folder ? "Choose the folder's lifecycle first. Child decisions remain separate; file work requires a Pending Folders review." : state.kind == .template ? "Choose whether to keep the template before reviewing its retained competing edits." : "Choose whether to keep this recording before reviewing any other competing changes. Files are removed only after the participating Macs approve safe cleanup.") : supported ? (isContent ? "Edits attached to other versions will be discarded when you choose a version." : nil) : "This file or lifecycle change needs a recovery review.",
                component: component, generation: generation, isOlderEdits: false))
        }
        for component in [SharedComponent.transcript, .summary] {
            let old = state.conflicts.filter { $0.inactiveGeneration != nil && $0.field.hasPrefix(component.rawValue + ".") }
            guard !old.isEmpty, let document = state.currentDocument(for: component),
                  state.lifecycle == .alive || (state.kind == .recording && state.lifecycle == .deleted) else { continue }
            let detail = old.flatMap { conflict in conflict.values.map { attributedPreview($0, field: conflict.field, state: state, labels: writerLabels) } }.sorted().joined(separator: "\n\n")
            let value = SharedFieldValue.document(document)
            fields.append(.init(id: component.rawValue + ".olderEdits", title: "Edits for an older " + component.rawValue,
                choices: [.init(id: identity(value), value: value, label: "Keep current version and discard older edits",
                    detail: "Current version:\n" + attributedPreview(value, field: component.rawValue + ".content", state: state, labels: writerLabels) + "\n\nEdits to discard:\n" + detail,
                    isAvailable: component == .transcript ? (try? document.decode(Transcript.self)) != nil : (try? document.decode(Summary.self)) != nil,
                    sources: sources(value, field: component.rawValue + ".content", state: state, labels: writerLabels))],
                explanation: "These edits belong to a replaced version. They will not be applied to the current version.", component: component, generation: nil, isOlderEdits: true))
        }
        // Only reviewed registers/content affect a choice. Unrelated record
        // updates must not clear a user's selection or expand its consent.
        var context: [String: String] = ["title": title, "lifecycle": String(describing: state.lifecycle)]
        let keys = Set(state.conflicts.map(\.field)).union(fields.compactMap { $0.component.map { $0.rawValue + ".content" } })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for key in keys { if let register = state.fields[key] { context[key] = (try? encoder.encode(register))?.base64EncodedString() } }
        for (id, review) in pathChoices { context["recording.path." + id] = review.contextFingerprint }
        for (id, review) in folderChoices { context["folder.path." + id] = review.contextFingerprint }
        for (id, review) in lifecycleChoices { context["folder.lifecycle." + id] = review.contextFingerprint }
        let signature = SharedLibraryOperation.fingerprint((try? encoder.encode(context)) ?? Data())
        return .init(title: title, snapshot: snapshot, fields: fields, reviewSignature: signature, folderRequests: requestChoices, recordingPaths: pathChoices, folderPaths: folderChoices, folderLifecycles: lifecycleChoices)
    }
    private static func lifecyclePreview(_ state: SharedEntityState, labels: [UUID: String]) -> String {
        var sections: [String] = []
        if state.kind == .folder {
            let names = (state.fields["name"]?.values ?? []).map { attributedPreview($0, field: "name", state: state, labels: labels) }.sorted()
            return "Folder names:\n" + names.joined(separator: "\n\n")
        }
        if state.kind == .template {
            for (field, label) in [("name", "Name"), ("description", "Description"), ("prompt", "Instructions")] {
                let alternatives = (state.fields[field]?.values ?? []).map { attributedPreview($0, field: field, state: state, labels: labels) }.sorted()
                if !alternatives.isEmpty { sections.append(label + ":\n" + alternatives.joined(separator: "\n\n")) }
            }
            return sections.joined(separator: "\n\n")
        }
        for component in [SharedComponent.transcript, .summary] {
            for document in state.generationValues(for: component).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                sections.append(attributedPreview(.document(document), field: component.rawValue + ".content", state: state, labels: labels))
            }
            for (field, register) in state.fields.sorted(by: { $0.key < $1.key }) where field.hasPrefix(component.rawValue + ".edits.") {
                for value in register.values.sorted(by: { identity($0) < identity($1) }) {
                    sections.append((component == .transcript ? "Speaker:\n" : "Action item:\n") + attributedPreview(value, field: field, state: state, labels: labels))
                }
            }
        }
        return sections.isEmpty ? "The recording and its stored edits remain associated with this item." : sections.joined(separator: "\n\n")
    }

    private static func sources(_ value: SharedFieldValue, field: String, state: SharedEntityState, labels: [UUID: String]) -> [String] {
        (state.fields[field]?.writers(for: value) ?? []).map { labels[$0] ?? ("Unknown Mac · " + $0.uuidString.lowercased()) }.sorted()
    }
    private static func sourceNote(_ sources: [String]) -> String {
        sources.isEmpty ? "" : "From: " + sources.joined(separator: ", ") + "\n"
    }
    private static func attributedPreview(_ value: SharedFieldValue, field: String, state: SharedEntityState, labels: [UUID: String]) -> String {
        sourceNote(sources(value, field: field, state: state, labels: labels)) + preview(value, field: field)
    }

    private static func fieldTitle(_ field: String) -> String {
        if field.hasPrefix("transcript.edits.") { return "Speaker name" }
        if field.hasPrefix("summary.edits.") { return "Action item status" }
        switch field {
        case "transcript.content": return "Transcript version"
        case "summary.content": return "Summary version"
        case "prompt": return "Template instructions"
        case "description": return "Template description"
        case "metadata.mode": return "Recording type"
        case "title", "name": return "Name"
        case "folder", "parent": return "Folder"
        case "deletionRequest": return "Folder deletion request"
        case "$lifecycle": return "Keep or delete"
        default: return "File change"
        }
    }
    private static func identity(_ value: SharedFieldValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SharedLibraryOperation.fingerprint((try? encoder.encode(value)) ?? Data())
    }
    private static func text(_ value: SharedFieldValue?) -> String? { if case .text(let text)? = value { return text }; return nil }
    private static func contentLabel(_ value: SharedFieldValue, component: SharedComponent) -> String {
        guard case .document(let document) = value else { return "Version" }
        if component == .transcript, let transcript = try? document.decode(Transcript.self) {
            return transcript.transcriptionModel + " · " + transcript.createdAt.formatted(date: .abbreviated, time: .shortened)
        }
        if component == .summary, let summary = try? document.decode(Summary.self) {
            return summary.model + " · " + summary.createdAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "Version"
    }
    private static func preview(_ value: SharedFieldValue, field: String) -> String {
        switch value {
        case .text(let text):
            if field == "metadata.mode", let data = text.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String { return decoded }
            return text
        case .flag(let value): return value ? "Completed" : "Not completed"
        case .unset: return "Use the original value"
        case .document(let document):
            if field.hasPrefix("transcript"), let transcript = try? document.decode(Transcript.self) { return transcript.plainText() }
            if field.hasPrefix("summary"), let summary = try? document.decode(Summary.self) {
                return summary.sections.map { section in
                    ([section.heading, section.content] + (section.items ?? []).map { ($0.isCompleted ? "☑ " : "☐ ") + $0.text }).joined(separator: "\n")
                }.joined(separator: "\n\n")
            }
            return "This version could not be displayed."
        }
    }
}
