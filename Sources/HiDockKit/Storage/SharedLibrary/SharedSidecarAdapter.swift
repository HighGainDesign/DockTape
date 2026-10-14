// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum SharedSidecarError: Error, Equatable, Sendable {
    case unknownRecording, ambiguousPath, invalidContent, reloadRequired, conflictedContent
}

/// Store boundary for shared content. Each store retains the exact snapshot its
/// user saw; edits target that generation and affected field, never cached JSON.
/// Physical sidecars are projections and are not implicitly adopted on reads.
public actor SharedSidecarAdapter {
    public nonisolated let coordinator: SharedLibraryCoordinator
    private struct Key: Hashable { let entity: UUID; let component: SharedComponent }
    private var displayed: [Key: SharedLibraryViewSnapshot] = [:]
    private var readRequests: [String: UUID] = [:]
    public init(coordinator: SharedLibraryCoordinator) { self.coordinator = coordinator }
    public nonisolated func requireRoot(_ root: URL) throws {
        guard root.standardizedFileURL.resolvingSymlinksInPath() == coordinator.root else {
            throw SharedLibraryCoordinatorError.differentBinding
        }
    }

    public func transcript(for filename: String) async throws -> Transcript? {
        let request = UUID(); readRequests[filename] = request
        let view = try await coordinator.recording(at: filename)
        let result = try Self.transcript(view, filename: filename)
        try Task.checkCancellation()
        if readRequests[filename] == request { displayed[Key(entity: view.state.id, component: .transcript)] = view }
        return result
    }
    public func summary(for filename: String) async throws -> Summary? {
        let request = UUID(); readRequests[filename] = request
        let view = try await coordinator.recording(at: filename)
        let result = try Self.summary(view, filename: filename)
        try Task.checkCancellation()
        if readRequests[filename] == request { displayed[Key(entity: view.state.id, component: .summary)] = view }
        return result
    }
    public func save(_ transcript: Transcript, filename: String) async throws -> Transcript {
        readRequests[filename] = UUID()
        guard transcript.recordingFilename == filename else { throw SharedSidecarError.invalidContent }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let fresh = try await coordinator.recording(at: filename)
        let seen = displayed[Key(entity: fresh.state.id, component: .transcript)]
        guard seen != nil || fresh.state.generationValues(for: .transcript).isEmpty else {
            throw SharedSidecarError.reloadRequired
        }
        let base = seen ?? fresh
        guard !base.state.conflicts.contains(where: { $0.field.hasPrefix("transcript.") }) else {
            throw SharedSidecarError.conflictedContent
        }
        let document = try SharedDocument(id: UUID(), json: encoder.encode(transcript))
        let result = try await coordinator.edit(.init(base: base, changes: [.generation(document, component: .transcript)]))
        displayed[Key(entity: fresh.state.id, component: .transcript)] = result
        guard let accepted = try Self.transcript(result, filename: filename) else { throw SharedSidecarError.invalidContent }
        return accepted
    }
    public func save(_ summary: Summary, filename: String) async throws -> Summary {
        readRequests[filename] = UUID()
        guard summary.recordingFilename == filename else { throw SharedSidecarError.invalidContent }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let fresh = try await coordinator.recording(at: filename)
        let seen = displayed[Key(entity: fresh.state.id, component: .summary)]
        guard seen != nil || fresh.state.generationValues(for: .summary).isEmpty else {
            throw SharedSidecarError.reloadRequired
        }
        let base = seen ?? fresh
        guard !base.state.conflicts.contains(where: { $0.field.hasPrefix("summary.") }) else {
            throw SharedSidecarError.conflictedContent
        }
        let document = try SharedDocument(id: UUID(), json: encoder.encode(summary))
        let result = try await coordinator.edit(.init(base: base, changes: [.generation(document, component: .summary)]))
        displayed[Key(entity: fresh.state.id, component: .summary)] = result
        guard let accepted = try Self.summary(result, filename: filename) else { throw SharedSidecarError.invalidContent }
        return accepted
    }
    public func updateSpeakerNames(filename: String, names: [String: String]) async throws -> Transcript? {
        readRequests[filename] = UUID()
        let fresh = try await coordinator.recording(at: filename)
        let key = Key(entity: fresh.state.id, component: .transcript)
        guard let base = displayed[key], let generation = base.state.currentDocument(for: .transcript),
              let before = try Self.transcript(base, filename: filename) else { throw SharedSidecarError.reloadRequired }
        let changes: [SharedLibraryMutation] = Set(before.speakerNames.keys).union(names.keys).sorted().compactMap { speaker in
            guard before.speakerNames[speaker] != names[speaker] else { return nil }
            return .generationEdit(component: .transcript, generation: generation.id, key: speaker,
                                   value: names[speaker].map(SharedFieldValue.text) ?? .unset)
        }
        for change in changes {
            if case .generationEdit(_, _, let speaker, _) = change {
                let field = "transcript.edits.\(generation.id.uuidString.lowercased()).\(speaker)"
                guard base.state.fields[field]?.isConflicted != true else { throw SharedSidecarError.conflictedContent }
            }
        }
        if changes.isEmpty { return try Self.transcript(fresh, filename: filename) }
        let accepted = try await coordinator.edit(.init(base: base, changes: changes))
        displayed[key] = accepted
        return try Self.transcript(accepted, filename: filename)
    }
    public func toggleItem(_ item: UUID, filename: String) async throws -> Summary? {
        readRequests[filename] = UUID()
        let fresh = try await coordinator.recording(at: filename)
        let key = Key(entity: fresh.state.id, component: .summary)
        guard let base = displayed[key], let generation = base.state.currentDocument(for: .summary),
              let summary = try Self.summary(base, filename: filename),
              let before = summary.sections.flatMap({ $0.items ?? [] }).first(where: { $0.id == item })
        else { throw SharedSidecarError.reloadRequired }
        let field = "summary.edits.\(generation.id.uuidString.lowercased()).\(item.uuidString.lowercased())"
        guard base.state.fields[field]?.isConflicted != true else { throw SharedSidecarError.conflictedContent }
        let accepted = try await coordinator.edit(.init(base: base, changes: [
            .generationEdit(component: .summary, generation: generation.id,
                            key: item.uuidString.lowercased(), value: .flag(!before.isCompleted))
        ]))
        displayed[key] = accepted
        return try Self.summary(accepted, filename: filename)
    }
    private static func content(_ view: SharedLibraryViewSnapshot, component: SharedComponent) throws -> SharedEntityState? {
        guard view.state.lifecycle == .alive else { throw SharedSidecarError.conflictedContent }
        if view.state.currentDocument(for: component) != nil { return view.state }
        if view.state.generationValues(for: component).isEmpty { return nil }
        guard let confirmed = view.confirmedState else { throw SharedSidecarError.conflictedContent }
        return confirmed
    }
    /// Resolve independent edits; each conflicting field keeps the last common
    /// projection rather than reverting to the original generation's value.
    private static func edits(_ state: SharedEntityState, confirmed: SharedEntityState?,
                              component: SharedComponent) -> [String: SharedFieldValue] {
        guard let generation = state.currentDocument(for: component) else { return [:] }
        let prefix = "\(component.rawValue).edits.\(generation.id.uuidString.lowercased())."
        let sameGeneration = confirmed?.currentDocument(for: component)?.id == generation.id
        var result: [String: SharedFieldValue] = [:]
        for (field, register) in state.fields where field.hasPrefix(prefix) {
            let value = register.isConflicted && sameGeneration ? confirmed?.fields[field]?.resolvedValue : register.resolvedValue
            if let value { result[String(field.dropFirst(prefix.count))] = value }
        }
        return result
    }
    private static func transcript(_ view: SharedLibraryViewSnapshot, filename: String) throws -> Transcript? {
        guard let state = try content(view, component: .transcript), let document = state.currentDocument(for: .transcript) else { return nil }
        var transcript = try SharedContentCoding.decoder().decode(Transcript.self, from: document.json)
        for (speaker, value) in edits(state, confirmed: view.confirmedState, component: .transcript) {
            switch value {
            case .text(let name): transcript.speakerNames[speaker] = name
            case .unset: transcript.speakerNames.removeValue(forKey: speaker)
            default: throw SharedSidecarError.invalidContent
            }
        }
        return Transcript(recordingFilename: filename, createdAt: transcript.createdAt,
                          transcriptionModel: transcript.transcriptionModel, hasSpeakerLabels: transcript.hasSpeakerLabels,
                          segments: transcript.segments, speakerNames: transcript.speakerNames, language: transcript.language)
    }
    private static func summary(_ view: SharedLibraryViewSnapshot, filename: String) throws -> Summary? {
        guard let state = try content(view, component: .summary), let document = state.currentDocument(for: .summary) else { return nil }
        let summary = try SharedContentCoding.decoder().decode(Summary.self, from: document.json)
        let edits = edits(state, confirmed: view.confirmedState, component: .summary)
        let sections = summary.sections.map { section in
            Summary.Section(id: section.id, heading: section.heading, content: section.content, items: section.items.map { items in
                items.map { item in
                    var result = item
                    if case .flag(let completed)? = edits[item.id.uuidString.lowercased()] { result.isCompleted = completed }
                    return result
                }
            })
        }
        return Summary(recordingFilename: filename, createdAt: summary.createdAt, model: summary.model,
                       provider: summary.provider, templateUsed: summary.templateUsed,
                       customPrompt: summary.customPrompt, sections: sections)
    }
}
