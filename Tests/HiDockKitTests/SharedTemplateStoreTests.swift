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
