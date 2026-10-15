// © 2026 High Gain Design. All rights reserved.
import Foundation

public actor SharedTemplateAdapter {
    public nonisolated let coordinator: SharedLibraryCoordinator
    private var displayed: [String: SharedLibraryViewSnapshot] = [:]
    private var loadRequest: UUID?
    public init(coordinator: SharedLibraryCoordinator) { self.coordinator = coordinator }
    public nonisolated func requireRoot(_ root: URL) throws {
        guard root.standardizedFileURL.resolvingSymlinksInPath() == coordinator.root else {
            throw SharedLibraryCoordinatorError.differentBinding
        }
    }
    public func load() async throws -> [Template] {
        let request = UUID(); loadRequest = request
        let views = try await coordinator.snapshots(kinds: [.template])
        var seen: [String: SharedLibraryViewSnapshot] = [:]
        var values: [Template] = []
        for view in views {
            guard case .text(let id)? = view.state.value(for: "templateID") else { throw SharedSidecarError.invalidContent }
            guard seen[id] == nil else { throw SharedSidecarError.ambiguousPath }
            seen[id] = view
            if view.state.lifecycle == .alive { values.append(try Self.render(view)) }
            else if view.state.lifecycle == .conflicted { throw SharedSidecarError.conflictedContent }
        }
        try Task.checkCancellation()
        if loadRequest == request { displayed = seen }
        return values.sorted { $0.id < $1.id }
    }
    func editingSnapshot(id: String, refreshing: Bool = false) async throws -> SharedLibraryViewSnapshot {
        if !refreshing, let snapshot = displayed[id] { return snapshot }
        guard refreshing || TemplateStore.builtInDefaults.contains(where: { $0.id == id }) else { throw SharedSidecarError.reloadRequired }
        let path = try SharedLibraryIdentity.normalized("template-" + id)
        return try await coordinator.read(.init(id: SharedLibraryIdentity.legacy(relativePath: path), kind: .template))
    }
    public func save(_ template: Template, before: Template?, adding: Bool) async throws -> Template {
        try await saveResult(template, before: before, adding: adding).template
    }
    func saveDraft(_ template: Template, before: Template, base: SharedLibraryViewSnapshot) async throws -> (template: Template, snapshot: SharedLibraryViewSnapshot) {
        try await saveResult(template, before: before, adding: false, base: base)
    }
    private func saveResult(_ template: Template, before: Template?, adding: Bool,
                            base captured: SharedLibraryViewSnapshot? = nil) async throws -> (template: Template, snapshot: SharedLibraryViewSnapshot) {
        loadRequest = nil
        let builtIn = TemplateStore.builtInDefaults.contains { $0.id == template.id }
        guard builtIn == template.isBuiltIn, !adding || !builtIn else { throw SharedSidecarError.invalidContent }
        let path = try SharedLibraryIdentity.normalized("template-" + template.id)
        let entity = SharedEntityIdentity(id: try SharedLibraryIdentity.legacy(relativePath: path), kind: .template)
        let fresh = try await coordinator.read(entity)
        if let captured {
            guard captured.libraryID == fresh.libraryID, captured.state.id == entity.id, captured.state.kind == .template else {
                throw SharedLibraryCoordinatorError.differentBinding
            }
            if captured.state.lifecycle == .uninitialized, fresh.state.lifecycle != .uninitialized { throw SharedLibraryCoordinatorError.staleReview }
        }
        if adding, fresh.state.lifecycle != .uninitialized {
            guard fresh.state.lifecycle == .alive, try Self.render(fresh) == template else { throw SharedSidecarError.invalidContent }
            return (try Self.render(fresh), fresh)
        }
        guard fresh.state.lifecycle == .uninitialized || fresh.state.lifecycle == .alive else {
            throw SharedSidecarError.conflictedContent
        }
        if fresh.state.lifecycle == .uninitialized {
            guard adding || builtIn else { throw SharedSidecarError.reloadRequired }
            let changes: [SharedLibraryMutation] = [
                .assign(field: "initialPath", value: .text(path)), .assign(field: "templateID", value: .text(template.id)),
                .assign(field: "name", value: .text(template.name)), .assign(field: "description", value: .text(template.description)),
                .assign(field: "prompt", value: .text(template.promptText)), .assign(field: "isBuiltIn", value: .flag(builtIn))]
            let accepted = try await coordinator.edit(.init(base: captured ?? fresh, changes: changes))
            displayed[template.id] = accepted
            return (try Self.render(accepted), accepted)
        }
        guard let base = captured ?? displayed[template.id], let before, before.isBuiltIn == template.isBuiltIn else {
            throw SharedSidecarError.reloadRequired
        }
        var changes: [SharedLibraryMutation] = []
        for (field, old, new) in [("name", before.name, template.name),
                                   ("description", before.description, template.description),
                                   ("prompt", before.promptText, template.promptText)] where old != new {
            guard base.state.fields[field]?.isConflicted != true else { throw SharedSidecarError.conflictedContent }
            changes.append(.assign(field: field, value: .text(new)))
        }
        if changes.isEmpty { return (try Self.render(fresh), fresh) }
        let accepted = try await coordinator.edit(.init(base: base, changes: changes))
        displayed[template.id] = accepted
        return (try Self.render(accepted), accepted)
    }
    func deleteDraft(id: String, base: SharedLibraryViewSnapshot) async throws {
        guard !TemplateStore.builtInDefaults.contains(where: { $0.id == id }),
              base.state.id == (try SharedLibraryIdentity.legacy(relativePath: "template-" + id)), base.state.kind == .template else {
            throw SharedSidecarError.invalidContent
        }
        loadRequest = nil
        displayed[id] = try await coordinator.edit(.init(base: base, changes: [.delete]))
    }
    public func delete(id: String) async throws {
        loadRequest = nil
        guard !TemplateStore.builtInDefaults.contains(where: { $0.id == id }) else { return }
        guard let base = displayed[id] else { throw SharedSidecarError.reloadRequired }
        displayed[id] = try await coordinator.edit(.init(base: base, changes: [.delete]))
    }
    func resetDraft(id: String, base: SharedLibraryViewSnapshot) async throws -> (template: Template, snapshot: SharedLibraryViewSnapshot) {
        guard let original = TemplateStore.builtInDefaults.first(where: { $0.id == id }),
              base.state.id == (try SharedLibraryIdentity.legacy(relativePath: "template-" + id)), base.state.kind == .template else {
            throw SharedSidecarError.invalidContent
        }
        loadRequest = nil
        let fresh = try await coordinator.read(.init(id: base.state.id, kind: .template))
        guard fresh.libraryID == base.libraryID else { throw SharedLibraryCoordinatorError.differentBinding }
        if base.state.lifecycle == .uninitialized {
            guard fresh.state.lifecycle == .uninitialized else { throw SharedLibraryCoordinatorError.staleReview }
            return (original, fresh)
        }
        guard base.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
        let accepted = try await coordinator.edit(.init(base: base, changes: [
            .assign(field: "name", value: .unset), .assign(field: "description", value: .unset), .assign(field: "prompt", value: .unset)]))
        displayed[id] = accepted
        return (try Self.render(accepted), accepted)
    }
    public func reset(id: String) async throws -> Template? {
        loadRequest = nil
        guard let original = TemplateStore.builtInDefaults.first(where: { $0.id == id }) else { return nil }
        guard let base = displayed[id] else { return original }
        guard base.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
        let accepted = try await coordinator.edit(.init(base: base, changes: [
            .assign(field: "name", value: .unset), .assign(field: "description", value: .unset), .assign(field: "prompt", value: .unset)]))
        displayed[id] = accepted
        return try Self.render(accepted)
    }
    static func render(_ view: SharedLibraryViewSnapshot) throws -> Template {
        guard case .text(let id)? = view.state.value(for: "templateID"),
              case .flag(let builtIn)? = view.state.value(for: "isBuiltIn") else { throw SharedSidecarError.invalidContent }
        let fallback = TemplateStore.builtInDefaults.first { $0.id == id }
        guard (fallback != nil) == builtIn else { throw SharedSidecarError.invalidContent }
        func text(_ field: String, default defaultText: String?) throws -> String {
            let register = view.state.fields[field]
            let value = register?.isConflicted == true ? view.confirmedState?.fields[field]?.resolvedValue : register?.resolvedValue
            if case .text(let result)? = value { return result }
            if value == nil || value == .unset, let defaultText { return defaultText }
            throw SharedSidecarError.conflictedContent
        }
        return try Template(id: id, name: text("name", default: fallback?.name),
                            description: text("description", default: fallback?.description),
                            promptText: text("prompt", default: fallback?.promptText), isBuiltIn: builtIn)
    }
}
