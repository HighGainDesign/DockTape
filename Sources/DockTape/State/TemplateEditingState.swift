// © 2026 High Gain Design. All rights reserved.
import Foundation
import Observation
import HiDockKit

@Observable @MainActor final class TemplateEditingState {
    private struct Draft {
        var context: TemplateEditContext
        var template: Template
        var revision: UInt64 = 0
        var isDirty: Bool { template != context.template }
    }
    struct Comparison: Identifiable {
        let id = UUID()
        let latest: TemplateEditContext
        let draft: Template
        let revision: UInt64
    }
    private var drafts: [String: Draft] = [:]
    private var store: TemplateStore?
    private var binding = UUID()
    private var selection = UUID()
    private(set) var selectedID: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var message: String?
    var comparison: Comparison?
    var template: Template? { selectedID.flatMap { drafts[$0]?.template } }
    var hasChanges: Bool { selectedID.flatMap { drafts[$0]?.isDirty } ?? false }

    func select(id: String?, using target: TemplateStore) async {
        if store !== target {
            binding = UUID(); drafts = [:]; comparison = nil; store = target
            isSaving = false; message = nil
        }
        selectedID = id
        let ticket = UUID(); selection = ticket
        guard let id else { isLoading = false; return }
        // A refresh or template selection must never replace unsaved text.
        if drafts[id]?.isDirty == true { isLoading = false; return }
        let bound = binding; isLoading = true
        do {
            let context = try await target.beginEditing(id: id)
            guard binding == bound, selection == ticket, store === target, !Task.isCancelled else { return }
            drafts[id] = .init(context: context, template: context.template)
        } catch {
            if binding == bound, selection == ticket { message = "This template could not be opened. Reload the templates and try again." }
        }
        if binding == bound, selection == ticket { isLoading = false }
    }
    func change(_ edit: (inout Template) -> Void) {
        guard let id = selectedID, var draft = drafts[id] else { return }
        edit(&draft.template); draft.revision &+= 1
        drafts[id] = draft
    }
    @discardableResult func save(using target: TemplateStore) async -> Bool {
        guard store === target, !isSaving, let id = selectedID, let submitted = drafts[id], submitted.isDirty else { return false }
        let bound = binding; isSaving = true; message = nil
        defer { if binding == bound { isSaving = false } }
        do {
            let accepted = try await target.update(submitted.template, basedOn: submitted.context)
            guard binding == bound, store === target, var current = drafts[id] else { return true }
            // Preserve typing that happened while the accepted save was in flight.
            current.template = Self.rebase(current.template, from: submitted.template, onto: accepted.template)
            current.context = accepted
            drafts[id] = current
            return true
        } catch {
            guard binding == bound, store === target else { return false }
            message = error as? SharedLibraryCoordinatorError == .staleReview
                ? "This template changed on another instance. Your draft is kept. Compare with the latest version before saving."
                : "The template could not be saved. Your draft is kept. Compare with the latest version or retry."
            return false
        }
    }
    func compareLatest(using target: TemplateStore) async {
        guard store === target, !isSaving, let id = selectedID, let draft = drafts[id] else { return }
        let bound = binding
        do {
            let latest = try await target.beginEditing(id: id, refreshing: true)
            guard binding == bound, store === target, selectedID == id,
                  drafts[id]?.revision == draft.revision else { return }
            comparison = .init(latest: latest, draft: draft.template, revision: draft.revision)
        } catch { if binding == bound { message = "The latest version is unavailable. Your draft is kept; retry when the library is available." } }
    }
    func acceptComparison(keepingEdits: Bool) {
        guard let comparison, let id = selectedID, var draft = drafts[id],
              draft.revision == comparison.revision, draft.template == comparison.draft,
              comparison.latest.template.id == id else {
            self.comparison = nil; return
        }
        draft.template = keepingEdits ? Self.rebase(draft.template, from: draft.context.template, onto: comparison.latest.template) : comparison.latest.template
        draft.context = comparison.latest; draft.revision &+= 1
        drafts[id] = draft; self.comparison = nil; message = nil
    }
    func reset(id: String, using target: TemplateStore) async -> Bool {
        guard store === target, !isSaving, let submitted = drafts[id], submitted.template.isBuiltIn else { return false }
        let bound = binding; isSaving = true; message = nil
        defer { if binding == bound { isSaving = false } }
        do {
            let accepted = try await target.resetToDefault(id: id, basedOn: submitted.context)
            guard binding == bound, store === target, var current = drafts[id] else { return true }
            current.template = Self.rebase(current.template, from: submitted.template, onto: accepted.template)
            current.context = accepted
            drafts[id] = current
            return true
        } catch {
            if binding == bound { message = "The template changed or could not be reset. Your draft is kept. Compare with the latest version before retrying." }
            return false
        }
    }
    func delete(id: String, using target: TemplateStore) async -> Bool {
        guard store === target, !isSaving, let draft = drafts[id] else { return false }
        let bound = binding; isSaving = true; message = nil
        defer { if binding == bound { isSaving = false } }
        do {
            try await target.delete(id: id, basedOn: draft.context)
            guard binding == bound, store === target else { return true }
            discard(id: id)
            return true
        } catch {
            if binding == bound { message = "The template changed or could not be deleted. Your draft is kept. Compare with the latest version before retrying." }
            return false
        }
    }
    func discard(id: String) { drafts[id] = nil; comparison = nil }
    private static func rebase(_ draft: Template, from before: Template, onto latest: Template) -> Template {
        var result = latest
        if draft.name != before.name { result.name = draft.name }
        if draft.description != before.description { result.description = draft.description }
        if draft.promptText != before.promptText { result.promptText = draft.promptText }
        return result
    }
}
