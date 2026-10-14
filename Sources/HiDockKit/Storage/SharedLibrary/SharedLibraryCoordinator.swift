// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum SharedLibraryCoordinatorError: Error, Equatable, Sendable {
    case notEnabled, bootstrapPending, enrollmentPending, differentBinding, staleReview, staleJob, unrecognizedWriter
}
public struct SharedLibraryViewSnapshot: Sendable {
    public let libraryID: UUID
    let repository: SharedLibrarySnapshot
    public var state: SharedEntityState { repository.state }
    public var fingerprint: String { repository.fingerprint }
    public var confirmedState: SharedEntityState? { repository.projection?.state }
}
public struct SharedCoordinatorEdit: Sendable {
    public let base: SharedLibraryViewSnapshot
    public let changes: [SharedLibraryMutation]
    public init(base: SharedLibraryViewSnapshot, changes: [SharedLibraryMutation]) {
        self.base = base
        self.changes = changes
    }
}
public struct SharedLibraryJobToken: Sendable {
    let library: UUID
    let entity: SharedEntityIdentity
    let lifecycle: String
    let component: SharedComponent?
    let input: String
}
public struct SharedExternalContent: Equatable, Sendable {
    public let id: UUID
    public let entity: SharedEntityIdentity
    public let component: SharedComponent
    public let url: URL
    public let fingerprint: String
    public let document: SharedDocument
}
public enum SharedLibraryChange: Sendable {
    case entity(UUID, SharedEntityIdentity, String)
    case failure(String)
}

/// Identity/revision-bound reads and semantic mutations. Reads don't wait for
/// unrelated entity hydration or writer enrollment. Edits require admitted
/// membership; refresh publishes observations, never an alive lifecycle write.
public actor SharedLibraryCoordinator {
    public nonisolated let root: URL
    public nonisolated let writerID: UUID
    private let bootstrap: LegacyLibraryBootstrap
    private let repository: SharedLibraryRepository
    private var manifest: SharedBootstrapManifest?
    private var members: SharedMemberRepository?
    private var cache: [SharedEntityIdentity: SharedLibraryViewSnapshot] = [:]
    private var requests: [SharedEntityIdentity: UInt64] = [:]
    private var monitor: SharedLibraryChangeMonitor?
    private var monitorRefresh: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<SharedLibraryChange>.Continuation] = [:]
    public init(root: URL, writerID: UUID) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.writerID = writerID
        bootstrap = LegacyLibraryBootstrap(root: root, writerID: writerID)
        repository = SharedLibraryRepository(root: root, writerID: writerID)
    }
    public func enable() async throws -> SharedBootstrapManifest {
        let manifest = try await bootstrap.enable()
        try await install(manifest)
        let members = try memberRepository()
        let initial = try await members.load()
        _ = try await members.commit(base: initial, membership: initial.membership)
        return manifest
    }
    private func install(_ manifest: SharedBootstrapManifest) async throws {
        if let previous = self.manifest,
            previous.libraryID != manifest.libraryID || previous.fingerprint != manifest.fingerprint
        {
            cache.removeAll()
            throw SharedLibraryCoordinatorError.differentBinding
        }
        try await repository.configure(manifest: manifest)
        self.manifest = manifest
        if members == nil { members = SharedMemberRepository(root: root, writer: writerID, manifest: manifest) }
    }
    private func bind(force: Bool = false) async throws -> SharedBootstrapManifest {
        if !force, let manifest { return manifest }
        let header = try await bootstrap.publishedManifest()
        switch header {
        case .notEnabled: throw SharedLibraryCoordinatorError.notEnabled
        case .ready(let manifest), .pending(let manifest):
            try await install(manifest)
            return manifest
        }
    }
    private func memberRepository() throws -> SharedMemberRepository {
        guard let members else { throw SharedLibraryCoordinatorError.notEnabled }
        return members
    }
    public func mayEdit() async throws -> Bool {
        _ = try await bind(force: true)
        guard case .ready = try await bootstrap.publishedManifest() else { return false }
        let members = try memberRepository()
        let snapshot = try await members.load()
        guard snapshot.membership.mayEdit(writerID) else { return false }
        _ = try await members.commit(base: snapshot, membership: snapshot.membership)
        return true
    }
    public func requestEnrollment(requestID: UUID, label: String) async throws {
        let manifest = try await bind(force: true)
        guard manifest.complete else { throw SharedLibraryCoordinatorError.bootstrapPending }
        let members = try memberRepository()
        let base = try await members.load()
        var membership = base.membership
        if !membership.mayEdit(writerID) {
            try membership.requestJoin(.init(writer: writerID, requestID: requestID, label: label))
        }
        _ = try await members.commit(base: base, membership: membership)
        try await refresh()
    }

    public func startMonitoring() async throws {
        _ = try await bind(force: true)
        await stopMonitoring()
        monitor = SharedLibraryChangeMonitor(root: root) { [weak self] in await self?.scheduleRefresh() }
    }
    public func stopMonitoring() async {
        let existing = monitor
        monitor = nil
        await existing?.close()
        let task = monitorRefresh
        monitorRefresh = nil
        task?.cancel()
        await task?.value
    }
    private func scheduleRefresh() {
        guard monitor != nil else { return }
        monitorRefresh?.cancel()
        monitorRefresh = Task { [weak self] in
            guard let self else { return }
            do { try await self.refresh() } catch {
                guard !Task.isCancelled else { return }
                await self.reportRefreshError(error.localizedDescription)
            }
        }
    }
    private func reportRefreshError(_ message: String) {
        guard monitor != nil else { return }
        for listener in listeners.values { listener.yield(.failure(message)) }
    }

    public func events() -> AsyncStream<SharedLibraryChange> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        }
    }
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func publish(_ snapshot: SharedLibraryViewSnapshot, entity: SharedEntityIdentity, request: UInt64) {
        guard requests[entity] == request else { return }
        let changed = cache[entity]?.fingerprint != snapshot.fingerprint
        cache[entity] = snapshot
        if changed {
            for listener in listeners.values {
                listener.yield(.entity(snapshot.libraryID, entity, snapshot.fingerprint))
            }
        }
    }
    private func beginRead(_ entity: SharedEntityIdentity) -> UInt64 {
        let next = (requests[entity] ?? 0) &+ 1
        requests[entity] = next
        return next
    }
    public func read(_ entity: SharedEntityIdentity) async throws -> SharedLibraryViewSnapshot {
        let manifest = try await bind()
        let request = beginRead(entity)
        let snapshot = try await repository.load(entity: entity)
        let view = SharedLibraryViewSnapshot(libraryID: manifest.libraryID, repository: snapshot)
        publish(view, entity: entity, request: request)
        return view
    }

    public func refresh() async throws {
        let manifest = try await bind(force: true)
        let members = try memberRepository()
        var membershipSnapshot = try await members.load()
        let entities = try await repository.scan()
        let tickets = entities.map { ($0, beginRead($0)) }
        let repository = self.repository
        var snapshots: [SharedLibrarySnapshot] = []
        try await withThrowingTaskGroup(of: (SharedEntityIdentity, UInt64, SharedLibrarySnapshot).self) { group in
            for (entity, ticket) in tickets {
                group.addTask { (entity, ticket, try await repository.load(entity: entity)) }
            }
            for try await (entity, ticket, snapshot) in group {
                snapshots.append(snapshot)
                publish(.init(libraryID: manifest.libraryID, repository: snapshot), entity: entity, request: ticket)
            }
        }
        var observedMembership = membershipSnapshot.membership
        for snapshot in snapshots {
            if let proof = snapshot.observedMembership {
                observedMembership = try observedMembership.merged(with: proof)
            }
        }
        if observedMembership != membershipSnapshot.membership {
            membershipSnapshot = try await members.commit(
                base: membershipSnapshot, membership: observedMembership, observing: true)
        }
        let membership = membershipSnapshot.membership
        if membership.mayEdit(writerID) {
            membershipSnapshot = try await members.commit(base: membershipSnapshot, membership: membership)
            for snapshot in snapshots { _ = try await repository.commit(.init(base: snapshot, changes: [])) }
        }
        guard !membership.pendingWriters.isEmpty || membership.hasConcurrentEnrollment,
            membership.cohort.contains(writerID) || membership.pendingWriters.contains(writerID),
            snapshots.allSatisfy({ $0.state.conflicts.isEmpty }),
            case .ready = try await bootstrap.readiness()
        else {
            try await advanceProjections(entities)
            return
        }
        struct Checkpoint: Encodable {
            struct Entry: Encodable {
                let id: UUID
                let kind: SharedEntityKind
                let revision: String
            }
            let bootstrap: String
            let entries: [Entry]
        }
        let checkpoint = try SharedStateFingerprint.of(
            Checkpoint(
                bootstrap: manifest.fingerprint,
                entries: snapshots.map {
                    .init(id: $0.state.id, kind: $0.state.kind, revision: $0.fingerprint)
                }.sorted { ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString) }))
        let proposal = try membership.proposal(checkpoint: checkpoint)
        let vote = SharedMembershipVote(writer: writerID, proposal: proposal.fingerprint, checkpoint: checkpoint)
        membershipSnapshot = try await members.commit(base: membershipSnapshot, membership: membership, vote: vote)
        let voters = membership.requiredVoters(for: proposal).compactMap { membershipSnapshot.votes[$0] }
        let certificate: SharedMembershipCertificate
        do {
            certificate = try membershipSnapshot.membership.certify(proposal, votes: voters)
        } catch SharedMembershipError.incompleteVotes { return } catch SharedMembershipError.staleProposal { return }
        var accepted = membershipSnapshot.membership
        try accepted.accept(certificate)
        _ = try await members.commit(base: membershipSnapshot, membership: accepted)
        try await advanceProjections(entities)
    }

    private func advanceProjections(_ entities: [SharedEntityIdentity]) async throws {
        let members = try memberRepository()
        for entity in entities {
            try Task.checkCancellation()
            var memberSnapshot = try await members.load()
            let base = try await repository.load(entity: entity)
            if let proof = base.observedMembership {
                let observed = try memberSnapshot.membership.merged(with: proof)
                if observed != memberSnapshot.membership {
                    memberSnapshot = try await members.commit(
                        base: memberSnapshot, membership: observed, observing: true)
                }
            }
            let membership = memberSnapshot.membership
            guard membership.mayEdit(writerID), membership.pendingWriters.isEmpty,
                !membership.hasConcurrentEnrollment, base.writers.isSubset(of: membership.cohort),
                base.state.conflicts.isEmpty
            else { continue }
            let proposal = try SharedProjectionProposal(state: base.state, membership: membership)
            do {
                _ = try await repository.acknowledgeProjection(proposal, base: base)
            } catch SharedLibraryRepositoryError.staleRevision { continue }
            let observed = try await repository.load(entity: entity)
            let currentMembership = try await members.load().membership
            guard currentMembership.fingerprint == proposal.cohort else { continue }
            let actual = try? SharedProjectionProposal(state: observed.state, membership: currentMembership)
            guard actual?.revision == proposal.revision else { continue }
            let votes = observed.projectionVotes.values.filter {
                membership.cohort.contains($0.writer) && $0.revision == proposal.revision
                    && $0.cohort == proposal.cohort
            }
            guard votes.count == membership.cohort.count else { continue }
            let certificate = try proposal.certify(votes: Array(votes))
            _ = try await repository.publishProjection(certificate, base: observed, membership: currentMembership)
            _ = try await read(entity)
        }
    }

    public func edit(_ edit: SharedCoordinatorEdit) async throws -> SharedLibraryViewSnapshot {
        try await commit(edit, review: false)
    }
    public func resolve(_ edit: SharedCoordinatorEdit) async throws -> SharedLibraryViewSnapshot {
        try await commit(edit, review: true)
    }
    private func commit(_ edit: SharedCoordinatorEdit, review: Bool) async throws -> SharedLibraryViewSnapshot {
        let manifest = try await bind(force: true)
        guard manifest.libraryID == edit.base.libraryID, repository.accepts(edit.base.repository) else {
            throw SharedLibraryCoordinatorError.differentBinding
        }
        guard try await mayEdit() else { throw SharedLibraryCoordinatorError.enrollmentPending }
        let membership = try await memberRepository().load().membership
        let entity = SharedEntityIdentity(id: edit.base.state.id, kind: edit.base.state.kind)
        let fresh = try await repository.load(entity: entity)
        guard fresh.writers.isSubset(of: membership.cohort) else {
            throw SharedLibraryCoordinatorError.unrecognizedWriter
        }
        for change in edit.changes {
            if !Self.reviewMatches(edit.base.state, fresh.state, change: change, review: review) {
                throw SharedLibraryCoordinatorError.staleReview
            }
        }
        _ = try await repository.commit(.init(base: fresh, changes: edit.changes))
        // A remote write can arrive after preflight. Its unseen dot survives the
        // commit and appears here as a conflict; no distributed lock is claimed.
        return try await read(entity)
    }
    private static func reviewMatches(
        _ before: SharedEntityState, _ after: SharedEntityState, change: SharedLibraryMutation, review: Bool
    ) -> Bool {
        let fields: Set<String>
        switch change {
        case .assign(let field, _): fields = [field]
        case .generation(_, let component):
            fields = Set(before.fields.keys.filter { $0.hasPrefix(component.rawValue + ".") }).union(
                after.fields.keys.filter { $0.hasPrefix(component.rawValue + ".") })
        case .generationEdit(let component, let generation, let key, _):
            fields = [
                component.rawValue + ".content",
                "\(component.rawValue).edits.\(generation.uuidString.lowercased()).\(key)",
            ]
        case .delete, .restore: return before == after
        }
        return fields.allSatisfy {
            review
                ? before.fields[$0] == after.fields[$0]
                : (before.fields[$0]?.values ?? []) == (after.fields[$0]?.values ?? [])
        }
    }

    public func pinJob(_ entity: SharedEntityIdentity, input: SharedComponent? = nil) async throws
        -> SharedLibraryJobToken
    {
        let snapshot = try await read(entity)
        guard snapshot.state.lifecycle == .alive else { throw SharedLibraryCoordinatorError.staleJob }
        return .init(
            library: snapshot.libraryID, entity: entity, lifecycle: try Self.lifecycleRevision(snapshot.state),
            component: input, input: try Self.inputRevision(snapshot.state, component: input))
    }
    public func validateJob(_ token: SharedLibraryJobToken) async throws {
        let snapshot = try await read(token.entity)
        guard snapshot.libraryID == token.library, snapshot.state.lifecycle == .alive,
            try Self.lifecycleRevision(snapshot.state) == token.lifecycle,
            try Self.inputRevision(snapshot.state, component: token.component) == token.input
        else { throw SharedLibraryCoordinatorError.staleJob }
    }
    private static func lifecycleRevision(_ state: SharedEntityState) throws -> String {
        try SharedStateFingerprint.of(state.fields["$lifecycle"])
    }
    private static func inputRevision(_ state: SharedEntityState, component: SharedComponent?) throws -> String {
        if let component {
            struct Input: Encodable {
                let document: SharedDocument?
                let edits: [String: SharedFieldValue]
            }
            return try SharedStateFingerprint.of(
                Input(document: state.currentDocument(for: component), edits: state.generationEdits(for: component)))
        }
        return try SharedStateFingerprint.of(state.value(for: "audioFingerprint") ?? state.value(for: "legacyMetadata"))
    }
    public func inspectExternal(_ entity: SharedEntityIdentity, component: SharedComponent, at url: URL) async throws
        -> SharedExternalContent?
    {
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw SharedLibraryRepositoryError.invalidPath
        }
        let snapshot = try await read(entity)
        let bytes = try await CoordinatedFileAccess().read(at: url)
        let fingerprint = try SharedStateFingerprint.of(bytes)
        let id = try SharedLibraryIdentity.legacy(
            relativePath: "external-\(entity.id.uuidString)-\(component.rawValue)-\(fingerprint).json")
        let document = try SharedDocument(id: id, json: bytes)
        if snapshot.state.currentDocument(for: component)?.json == document.json { return nil }
        return .init(
            id: id, entity: entity, component: component, url: url, fingerprint: fingerprint, document: document)
    }
}
