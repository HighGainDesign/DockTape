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

}
