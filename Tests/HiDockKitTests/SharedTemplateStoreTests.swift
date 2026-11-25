// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedTemplateStoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator, Template) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let user = Template.makeUserTemplate(name: "Original", description: "Description", promptText: "Prompt")
        try await TemplateStore(baseDirectory: root).addUserTemplate(user)
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID())
        _ = try await coordinator.enable()
        return (root, coordinator, user)
    }
    private func conflictedLifecycleFixture(unconfirmed: Bool = false, conflictingName: Bool = false) async throws -> (URL, SharedLibraryCoordinator, Template, Template) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); roots.append(parent)
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        var user = Template.makeUserTemplate(name: "Contested", description: "Original description", promptText: "Original prompt")
        let other = Template.makeUserTemplate(name: "Unrelated", description: "Keep", promptText: "Other prompt")
        let legacy = TemplateStore(baseDirectory: left); try await legacy.addUserTemplate(user); try await legacy.addUserTemplate(other)
        let a = SharedLibraryCoordinator(root: left, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("a-local"))
        _ = try await a.enable(); _ = try await a.projectOutputs()
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"))
        try await b.requestEnrollment(requestID: UUID(), label: "Template peer")
        func deliver(_ source: URL, _ destination: URL, _ writer: UUID) throws {
            let tree = source.appendingPathComponent(".docktape").resolvingSymlinksInPath()
            guard let files = FileManager.default.enumerator(at: tree, includingPropertiesForKeys: nil) else { return }
            for case let file as URL in files where file.pathExtension == "json" {
                let bytes = try Data(contentsOf: file)
                let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
                let payload = object["payload"] as? [String: Any]
                let owner = (object["writerID"] as? String) ?? (payload?["writer"] as? String) ?? (object["founder"] as? String)
                guard owner.flatMap(UUID.init(uuidString:)) == writer else { continue }
                let target = destination.appendingPathComponent(".docktape/" + String(file.resolvingSymlinksInPath().path.dropFirst(tree.path.count + 1)))
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic)
            }
        }
        for _ in 0..<3 {
            try deliver(right, left, b.writerID); try await a.refresh()
            try deliver(left, right, a.writerID); try await b.refresh()
        }
        let sa = TemplateStore(baseDirectory: left, shared: SharedTemplateAdapter(coordinator: a)), sb = TemplateStore(baseDirectory: right, shared: SharedTemplateAdapter(coordinator: b))
        try await sa.load(); try await sb.load()
        if unconfirmed {
            user = Template.makeUserTemplate(name: "New contested", description: "New description", promptText: "New original")
            try await sa.addUserTemplate(user)
            try deliver(left, right, a.writerID); try await sb.load()
            var first = user
            if conflictingName { first.name = "New name A" } else { first.promptText = "New version A" }
            try await sa.update(first)
        }
        try await sa.delete(id: user.id)
        var edited = user
        if conflictingName { edited.name = "Offline name" } else { edited.promptText = "Offline edit" }
        try await sb.update(edited); try deliver(right, left, b.writerID)
        let views = try await a.snapshots(kinds: [.template])
        let view = try XCTUnwrap(views.first { $0.state.value(for: "templateID") == .text(user.id) })
        XCTAssertEqual(view.state.lifecycle, .conflicted)
        if unconfirmed { XCTAssertNil(view.confirmedState, "New template has no common projection; do not invent a fallback") }
        else { XCTAssertEqual(view.confirmedState?.value(for: "prompt"), .text("Original prompt"), "Fixture has a proven common template, not an arrival-order winner") }
        return (left, a, user, other)
    }
    private func assertMalformedFieldRefusesCatalogAndProjection(conflictingName: Bool) async throws {
        let (root, a, user, _) = try await conflictedLifecycleFixture(unconfirmed: true, conflictingName: conflictingName)
        let views = try await a.snapshots(kinds: [.template])
        let conflicted = try XCTUnwrap(views.first { $0.state.value(for: "templateID") == .text(user.id) })
        let malformedField = conflictingName ? "prompt" : "name"
        let restored = try await a.resolve(.init(base: conflicted, changes: [
            .restore, .assign(field: malformedField, value: .flag(true))]))
        XCTAssertTrue(restored.state.fields[conflictingName ? "name" : "prompt"]?.isConflicted == true)
        XCTAssertNil(restored.confirmedState)
        let canonical = root.appendingPathComponent(".templates.json")
        let before = try Data(contentsOf: canonical)
        let store = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: a))
        do { try await store.load(); XCTFail("An unrelated conflict must not suppress malformed content") }
        catch SharedSidecarError.invalidContent { }
        do { _ = try await a.projectOutputs(); XCTFail("Malformed template must not be silently removed from published JSON") }
        catch SharedSidecarError.invalidContent { }
        XCTAssertEqual(try Data(contentsOf: canonical), before)
    }
    func testMalformedNameIsNotHiddenByUnconfirmedPromptConflict() async throws {
        try await assertMalformedFieldRefusesCatalogAndProjection(conflictingName: false)
    }
    func testUnavailableNameConflictDoesNotHideMalformedLaterPrompt() async throws {
        try await assertMalformedFieldRefusesCatalogAndProjection(conflictingName: true)
    }

    func testUnconfirmedTemplateConflictNeverInventsWinnerOrBlocksOtherTemplates() async throws {
        let (root, a, user, other) = try await conflictedLifecycleFixture(unconfirmed: true)
        let views = try await a.snapshots(kinds: [.template])
        let conflicted = try XCTUnwrap(views.first { $0.state.value(for: "templateID") == .text(user.id) })
        let restored = try await a.resolve(.init(base: conflicted, changes: [.restore]))
        XCTAssertTrue(restored.state.fields["prompt"]?.isConflicted == true)
        XCTAssertNil(restored.confirmedState)
        let store = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: a))
        try await store.load()
        let contested = await store.template(forID: user.id), unrelated = await store.template(forID: other.id)
        XCTAssertNil(contested, "Conflicting instructions without a confirmed common template cannot be offered as a resolved value")
        XCTAssertEqual(unrelated, other)
        _ = try await a.projectOutputs()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".templates.json"))) as! [String: Any]
        let users = object["userTemplates"] as! [[String: Any]]
        XCTAssertFalse(users.contains { $0["id"] as? String == user.id })
        XCTAssertTrue(users.contains { $0["id"] as? String == other.id })
    }

    func testTemplateLifecycleConflictKeepsConfirmedCatalogAndUnrelatedEditingUsable() async throws {
        let (root, a, user, other) = try await conflictedLifecycleFixture()
        let store = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: a))
        try await store.load()
        let contested = await store.template(forID: user.id), unrelated = await store.template(forID: other.id)
        XCTAssertEqual(contested, user); XCTAssertEqual(unrelated, other)
        var changed = user; changed.promptText = "Must refuse"
        do { try await store.update(changed); XCTFail("Ordinary editing cannot resolve a contested lifecycle") }
        catch SharedSidecarError.conflictedContent { }
        var independent = other; independent.promptText = "Independent new prompt"
        try await store.update(independent); try await store.load()
        let saved = await store.template(forID: other.id), stillConfirmed = await store.template(forID: user.id)
        XCTAssertEqual(saved, independent); XCTAssertEqual(stillConfirmed, user)
    }
    func testTemplateLifecycleConflictPublishesConfirmedJSONRatherThanDroppingTemplate() async throws {
        let (root, a, user, other) = try await conflictedLifecycleFixture()
        _ = try await a.projectOutputs()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".templates.json"))) as! [String: Any]
        let users = object["userTemplates"] as! [[String: Any]]
        let original = try XCTUnwrap(users.first { $0["id"] as? String == user.id })
        XCTAssertEqual(original["name"] as? String, "Contested")
        XCTAssertEqual(original["promptText"] as? String, "Original prompt")
        XCTAssertTrue(users.contains { $0["id"] as? String == other.id })
    }

    func testActualTemplateStoresCombineIndependentFieldsAndReloadExternalState() async throws {
        let (root, coordinator, user) = try await fixture()
        let a = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        let b = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await a.load(); try await b.load()
        var first = user; first.name = "Renamed"
        var second = user; second.promptText = "New prompt"
        try await a.update(first); try await b.update(second)
        try await a.load()
        let result = await a.template(forID: user.id)
        XCTAssertEqual(result?.name, "Renamed"); XCTAssertEqual(result?.promptText, "New prompt")
    }
    func testActualTemplateStoresRejectStaleSameFieldAndDeletedEdits() async throws {
        let (root, coordinator, user) = try await fixture()
        let a = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        let b = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await a.load(); try await b.load()
        var first = user; first.promptText = "First"
        var second = user; second.promptText = "Second"
        try await a.update(first)
        do { try await b.update(second); XCTFail("Do not consume an unseen prompt") }
        catch SharedLibraryCoordinatorError.staleReview {}
        try await b.load()
        try await a.delete(id: user.id)
        do { try await b.update(second); XCTFail("Editing cannot restore a deleted template") } catch {}
        try await b.load()
        let result = await b.template(forID: user.id)
        XCTAssertNil(result)
    }
    func testBuiltInResetAndSubsequentOverrideUseExplicitSemanticValues() async throws {
        let (root, coordinator, _) = try await fixture()
        let store = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await store.load()
        var original = TemplateStore.builtInDefaults[0]
        original.promptText = "Custom prompt"
        try await store.update(original)
        let custom = await store.template(forID: original.id)
        XCTAssertEqual(custom?.promptText, "Custom prompt")
        try await store.resetToDefault(id: original.id)
        try await store.load()
        let reset = await store.template(forID: original.id)
        XCTAssertEqual(reset, TemplateStore.builtInDefaults[0])
        original.promptText = "Another override"
        try await store.update(original)
        let another = await store.template(forID: original.id)
        XCTAssertEqual(another?.promptText, "Another override")
    }
    func testNewTemplatesRemainSeparateAndDuplicateIDCannotReplaceExistingValue() async throws {
        let (root, coordinator, _) = try await fixture()
        let a = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        let b = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await a.load(); try await b.load()
        let one = Template.makeUserTemplate(name: "One", description: "", promptText: "One")
        let two = Template.makeUserTemplate(name: "Two", description: "", promptText: "Two")
        try await a.addUserTemplate(one); try await b.addUserTemplate(two)
        try await a.load()
        let users = await a.userCreatedTemplates()
        XCTAssertTrue(users.contains(one)); XCTAssertTrue(users.contains(two))
        var impostor = one; impostor.name = "Wrong"
        do { try await b.addUserTemplate(impostor); XCTFail("A new-item action cannot replace an existing ID") } catch {}
        try await b.load()
        let saved = await b.template(forID: one.id)
        XCTAssertEqual(saved, one)
    }
    func testAcceptedTemplateEditDoesNotReloadAnUnrelatedUnreadableTemplate() async throws {
        let (root, coordinator, user) = try await fixture()
        let store = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await store.load()
        let other = Template.makeUserTemplate(name: "Other", description: "", promptText: "Other")
        try await store.addUserTemplate(other)
        let id = try SharedLibraryIdentity.legacy(relativePath: "template-" + other.id)
        let file = root.appendingPathComponent(".docktape/templates/\(id.uuidString.lowercased())/\(coordinator.writerID.uuidString.lowercased()).json")
        let original = try Data(contentsOf: file)
        defer { try? original.write(to: file, options: .atomic) }
        try Data("unreadable fixture".utf8).write(to: file, options: .atomic)
        var changed = user; changed.promptText = "Accepted prompt"
        do { try await store.update(changed) }
        catch { XCTFail("An accepted edit must not be reported failed by an unrelated reload: \(error)") }
        let cached = await store.template(forID: user.id)
        XCTAssertEqual(cached?.promptText, "Accepted prompt")
    }

    func testOpenDraftPreservesIndependentRemoteFieldAfterBackgroundReload() async throws {
        let (root, coordinator, user) = try await fixture()
        let editor = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        let other = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await editor.load(); try await other.load()
        let context = try await editor.beginEditing(id: user.id)
        var draft = context.template; draft.name = "Draft name"
        var remote = user; remote.promptText = "Unseen remote prompt"
        try await other.update(remote)
        try await editor.load() // AppState refresh while Settings still has its draft.
        _ = try await editor.update(draft, basedOn: context)
        try await other.load()
        let saved = await other.template(forID: user.id)
        XCTAssertEqual(saved?.name, "Draft name")
        XCTAssertEqual(saved?.promptText, "Unseen remote prompt", "Only fields edited in the captured draft may change")
    }
    func testOpenDraftCannotConsumeSameFieldChangeDuringBackgroundReload() async throws {
        let (root, coordinator, user) = try await fixture()
        let editor = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        let other = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await editor.load(); try await other.load()
        let context = try await editor.beginEditing(id: user.id)
        var draft = context.template; draft.promptText = "Unsaved local draft"
        var remote = user; remote.promptText = "Unseen remote prompt"
        try await other.update(remote)
        try await editor.load()
        do { _ = try await editor.update(draft, basedOn: context); XCTFail("Background refresh is not consent to overwrite a new prompt") }
        catch SharedLibraryCoordinatorError.staleReview {}
        try await other.load()
        let saved = await other.template(forID: user.id)
        XCTAssertEqual(saved?.promptText, "Unseen remote prompt")
        XCTAssertEqual(draft.promptText, "Unsaved local draft", "The caller must retain its draft after rejection")
    }

    func testEditorContextCannotBeUsedByAnotherStore() async throws {
        let (root, coordinator, user) = try await fixture()
        let one = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        let two = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await one.load(); try await two.load()
        let context = try await one.beginEditing(id: user.id)
        var draft = context.template; draft.name = "Wrong binding"
        do { _ = try await two.update(draft, basedOn: context); XCTFail("An editor context belongs to its store") }
        catch SharedLibraryCoordinatorError.differentBinding {}
        try await two.load()
        let saved = await two.template(forID: user.id)
        XCTAssertEqual(saved, user)
    }
    func testPristineBuiltInDraftCannotOverwriteAnUnseenFirstOverride() async throws {
        let (root, coordinator, _) = try await fixture()
        let one = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        let two = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await one.load(); try await two.load()
        let context = try await one.beginEditing(id: "meeting")
        var mine = context.template; mine.promptText = "My first override"
        var remote = context.template; remote.promptText = "Their first override"
        try await two.update(remote); try await one.load()
        do { _ = try await one.update(mine, basedOn: context); XCTFail("An uninitialized baseline cannot consume an unseen first override") }
        catch SharedLibraryCoordinatorError.staleReview {}
    }
    func testReviewedTemplateDeleteRejectsAChangedTemplateAfterReload() async throws {
        let (root, coordinator, user) = try await fixture()
        let one = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        let two = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await one.load(); try await two.load()
        let context = try await one.beginEditing(id: user.id)
        var remote = user; remote.promptText = "Changed before delete"
        try await two.update(remote); try await one.load()
        do { try await one.delete(id: user.id, basedOn: context); XCTFail("A fresh cache cannot expand deletion consent") }
        catch SharedLibraryCoordinatorError.staleReview {}
        let latest = try await one.beginEditing(id: user.id, refreshing: true)
        try await one.delete(id: user.id, basedOn: latest)
        try await two.load()
        let deleted = await two.template(forID: user.id)
        XCTAssertNil(deleted)
    }
    func testLegacyDraftChangesOnlyItsEditedFieldAfterReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let user = Template.makeUserTemplate(name: "Original", description: "", promptText: "Prompt")
        let one = TemplateStore(baseDirectory: root), two = TemplateStore(baseDirectory: root)
        try await one.addUserTemplate(user); try await two.load()
        let context = try await one.beginEditing(id: user.id)
        var draft = user; draft.name = "Local draft"
        var remote = user; remote.promptText = "Remote prompt"
        try await two.update(remote); try await one.load()
        _ = try await one.update(draft, basedOn: context)
        try await two.load()
        let saved = await two.template(forID: user.id)
        XCTAssertEqual(saved?.name, "Local draft"); XCTAssertEqual(saved?.promptText, "Remote prompt")
    }

    func testFreshEditorContextDoesNotReadAnUnrelatedCorruptTemplate() async throws {
        let (root, coordinator, user) = try await fixture()
        let store = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await store.load()
        let other = Template.makeUserTemplate(name: "Unavailable", description: "", promptText: "Unavailable")
        try await store.addUserTemplate(other)
        let id = try SharedLibraryIdentity.legacy(relativePath: "template-" + other.id)
        let file = root.appendingPathComponent(".docktape/templates/\(id.uuidString.lowercased())/\(coordinator.writerID.uuidString.lowercased()).json")
        try Data("unreadable unrelated template".utf8).write(to: file, options: .atomic)
        let context = try await store.beginEditing(id: user.id, refreshing: true)
        XCTAssertEqual(context.template, user)
    }

    func testReviewedBuiltInResetUsesUnsetAndRefusesUnseenOverride() async throws {
        let (root, coordinator, _) = try await fixture()
        let one = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        let two = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await one.load(); try await two.load()
        let pristine = try await one.beginEditing(id: "meeting")
        var remote = pristine.template; remote.promptText = "New override"
        try await two.update(remote)
        do { _ = try await one.resetToDefault(id: "meeting", basedOn: pristine); XCTFail("A reset cannot consume an unseen override") }
        catch SharedLibraryCoordinatorError.staleReview {}
        let reviewed = try await one.beginEditing(id: "meeting", refreshing: true)
        let reset = try await one.resetToDefault(id: "meeting", basedOn: reviewed)
        XCTAssertEqual(reset.template, TemplateStore.builtInDefaults[0])
        let id = try SharedLibraryIdentity.legacy(relativePath: "template-meeting")
        let state = try await coordinator.read(.init(id: id, kind: .template)).state
        XCTAssertEqual(state.fields["prompt"]?.resolvedValue, .unset, "Reset removes the override rather than pinning today's default text")
    }

}
