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

        func visibleFields(selections: [String: String]) -> [Field] {
            if snapshot.state.lifecycle == .conflicted {
                return fields.filter { $0.id == "$lifecycle" }
            }
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
    private var action: Task<Bool, Never>?

    func clear() {
        request = UUID(); action?.cancel(); action = nil
        binding = nil; items = []; revision &+= 1; message = nil; isLoading = false; isApplying = false
    }
    func refresh(using coordinator: SharedLibraryCoordinator) async {
        if binding !== coordinator { clear(); binding = coordinator }
        let ticket = UUID(); request = ticket; isLoading = true; message = nil
        defer { if request == ticket { isLoading = false } }
        do {
            let views = try await coordinator.snapshots(kinds: [.recording, .folder, .template])
            guard request == ticket, binding === coordinator, !Task.isCancelled else { return }
            items = views.filter { !$0.state.conflicts.isEmpty }.map(Self.item).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            revision &+= 1
        } catch {
            if request == ticket, binding === coordinator { message = error.localizedDescription }
        }
    }
    func apply(item: Item, selections: [String: String], using coordinator: SharedLibraryCoordinator) async -> Bool {
        guard binding === coordinator, !isApplying, !isLoading else { return false }
        let fields = item.visibleFields(selections: selections).filter { !$0.choices.isEmpty }
        let decidingLifecycle = item.snapshot.state.kind == .recording && item.snapshot.state.lifecycle == .conflicted
        let preservingDeletion = item.snapshot.state.kind == .recording && item.snapshot.state.lifecycle == .deleted
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
        let ticket = request
        isApplying = true; message = nil
        let task = Task { [weak self] in
            do {
                guard try await coordinator.mayEdit() else { throw SharedLibraryCoordinatorError.enrollmentPending }
                try Task.checkCancellation()
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                let accepted = try await coordinator.resolve(.init(base: item.snapshot, changes: changes))
                var publication: String?
                if decidingLifecycle || preservingDeletion {
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
                }
                do { _ = try await coordinator.projectOutputs() }
                catch SharedProjectionWriteError.untracked(let path) { publication = "Choice saved. " + path + " changed outside DockTape and needs a file review before publishing." }
                catch { publication = (publication.map { $0 + " " } ?? "Choice saved. ") + "Readable files could not be updated yet. Reload the review or retry after sync finishes." }
                guard self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                await self.refresh(using: coordinator)
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
        if binding === coordinator { isApplying = false; action = nil }
        return result
    }
    private static func item(_ snapshot: SharedLibraryViewSnapshot) -> Item {
        let state = snapshot.state
        let title = text(state.value(for: state.kind == .recording ? "title" : "name"))
            ?? text(state.value(for: "initialPath")) ?? (state.kind == .template ? "Summary template" : "Library item")
        var fields: [Field] = []
        for conflict in state.conflicts where conflict.inactiveGeneration == nil
            && !conflict.field.hasPrefix("externalAdoption.")
            && !conflict.field.hasPrefix("externalAdoptionGeneration.") {
            let parts = conflict.field.split(separator: ".").map(String.init)
            let component = parts.first.flatMap(SharedComponent.init(rawValue:))
            let generation = parts.count >= 4 && parts[1] == "edits" ? UUID(uuidString: parts[2]) : nil
            let isContent = component != nil && parts.count == 2 && parts[1] == "content"
            let safeScalar = ["prompt", "description"].contains(conflict.field) || conflict.field == "metadata.mode" || (state.kind == .template && conflict.field == "name")
            let lifecycleChoice = state.kind == .recording && state.lifecycle == .conflicted && conflict.field == "$lifecycle"
            let editableContent = state.lifecycle == .alive || (state.kind == .recording && state.lifecycle == .deleted)
            let supported = lifecycleChoice || (editableContent && (isContent || generation != nil || safeScalar))
            let choices = supported ? conflict.values.compactMap { value -> Choice? in
                if isContent { guard case .document = value else { return nil } }
                if lifecycleChoice {
                    guard case .flag(let keep) = value else { return nil }
                    let label = keep ? "Keep Recording and Edits" : "Delete Recording"
                    let detail = (keep ? "Keep this recording and the retained edits below. Other competing changes will still need review." : "Hide this recording. Original files remain until safe cleanup is approved by the participating Macs.")
                        + "\n\n" + lifecyclePreview(state)
                    return .init(id: identity(value), value: value, label: label, detail: detail, isAvailable: true)
                }
                let detail = preview(value, field: conflict.field)
                let label = isContent ? contentLabel(value, component: component!) : detail
                let available: Bool
                if isContent, case .document(let document) = value {
                    available = component == .transcript ? (try? document.decode(Transcript.self)) != nil : (try? document.decode(Summary.self)) != nil
                } else { available = true }
                return .init(id: identity(value), value: value, label: label, detail: detail, isAvailable: available)
            }.sorted { ($0.label, $0.id) < ($1.label, $1.id) } : []
            var heading = fieldTitle(conflict.field)
            if component == .summary, let generation, parts.count >= 4,
               let document = state.fields["summary.content"]?.values.compactMap({ value -> SharedDocument? in if case .document(let document) = value, document.id == generation { return document }; return nil }).first,
               let summary = try? document.decode(Summary.self),
               let entry = summary.sections.flatMap({ $0.items ?? [] }).first(where: { $0.id.uuidString.lowercased() == parts.dropFirst(3).joined(separator: ".") }) {
                heading = "Action item: " + entry.text
            }
            fields.append(.init(id: conflict.field, title: heading, choices: choices,
                explanation: lifecycleChoice ? "Choose whether to keep this recording before reviewing any other competing changes. Files are removed only after the participating Macs approve safe cleanup." : supported ? (isContent ? "Edits attached to other versions will be discarded when you choose a version." : nil) : "This file or lifecycle change needs a recovery review.",
                component: component, generation: generation, isOlderEdits: false))
        }
        for component in [SharedComponent.transcript, .summary] {
            let old = state.conflicts.filter { $0.inactiveGeneration != nil && $0.field.hasPrefix(component.rawValue + ".") }
            guard !old.isEmpty, let document = state.currentDocument(for: component),
                  state.lifecycle == .alive || (state.kind == .recording && state.lifecycle == .deleted) else { continue }
            let detail = old.flatMap { $0.values }.map { preview($0, field: component.rawValue) }.sorted().joined(separator: "\n")
            let value = SharedFieldValue.document(document)
            fields.append(.init(id: component.rawValue + ".olderEdits", title: "Edits for an older " + component.rawValue,
                choices: [.init(id: identity(value), value: value, label: "Keep current version and discard older edits",
                    detail: "Current version:\n" + preview(value, field: component.rawValue) + "\n\nEdits to discard:\n" + detail,
                    isAvailable: component == .transcript ? (try? document.decode(Transcript.self)) != nil : (try? document.decode(Summary.self)) != nil)],
                explanation: "These edits belong to a replaced version. They will not be applied to the current version.", component: component, generation: nil, isOlderEdits: true))
        }
        // Only reviewed registers/content affect a choice. Unrelated record
        // updates must not clear a user's selection or expand its consent.
        var context: [String: String] = ["title": title, "lifecycle": String(describing: state.lifecycle)]
        let keys = Set(state.conflicts.map(\.field)).union(fields.compactMap { $0.component.map { $0.rawValue + ".content" } })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for key in keys { if let register = state.fields[key] { context[key] = (try? encoder.encode(register))?.base64EncodedString() } }
        let signature = SharedLibraryOperation.fingerprint((try? encoder.encode(context)) ?? Data())
        return .init(title: title, snapshot: snapshot, fields: fields, reviewSignature: signature)
    }
    private static func lifecyclePreview(_ state: SharedEntityState) -> String {
        var sections: [String] = []
        for component in [SharedComponent.transcript, .summary] {
            for document in state.generationValues(for: component).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                sections.append(preview(.document(document), field: component.rawValue + ".content"))
            }
            for (_, value) in state.generationEdits(for: component).sorted(by: { $0.key < $1.key }) {
                sections.append((component == .transcript ? "Speaker: " : "Action item: ") + preview(value, field: component.rawValue))
            }
        }
        return sections.isEmpty ? "The recording and its stored edits remain associated with this item." : sections.joined(separator: "\n\n")
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
