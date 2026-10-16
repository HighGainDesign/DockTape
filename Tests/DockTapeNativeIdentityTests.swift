// © 2026 High Gain Design. All rights reserved.
import AppKit
import HiDockKit

/// Signed host using actual AppState and its default native identity factory.
/// No window, hardware transport, models or provider calls are started.
@main struct DockTapeNativeIdentityTests {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.setVolatileDomain(["storageMode": "local"], forName: UserDefaults.argumentDomain)
        guard CommandLine.arguments.count == 3, let expected = UUID(uuidString: CommandLine.arguments[2]) else { throw Failure(message: "Fixture arguments missing") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = AppState(baseDirectory: root)
        try await app.setup()
        guard app.sharedLibrary.phase == .ready, let coordinator = app.sharedLibrary.coordinator,
              coordinator.writerID == expected else { throw Failure(message: "Signed AppState/CLI identity mismatch") }
        try await app.library.store.setMeta(mode: "Mee", deviceFilename: "native-fixture.hda", for: "A.mp3")
        let view = try await coordinator.recording(at: "A.mp3")
        guard view.state.value(for: "metadata.mode") == .text("\"Mee\"") else { throw Failure(message: "Actual shared app edit not committed") }
        await app.sharedLibrary.close()
        app.playback.stop()
        print("Signed AppState matches CLI native identity and commits through shared authority.")
    }
}
