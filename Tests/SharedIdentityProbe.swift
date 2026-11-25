// © 2026 High Gain Design. All rights reserved.
import Foundation
import HiDockKit
@main struct IdentityProbe {
    static func main() async {
        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let factory = SharedWriterIdentityFactory(directory: directory)
            let first = try await factory.load()
            let second = try await factory.load()
            guard first == second else { throw ProbeError.unstable }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(first)
            FileHandle.standardOutput.write(bytes)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("Native identity probe failed: \(error)\n", stderr)
            exit(1)
        }
    }
    enum ProbeError: Error { case unstable }
}
