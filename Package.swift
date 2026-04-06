// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DockTape",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hidock", targets: ["HiDockCLI"]),
        .library(name: "HiDockKit", targets: ["HiDockKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        // Vendored libusb-1.0 (static library, no Homebrew needed at runtime)
        .target(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "Vendor/libusb/lib",
                    "-lusb-1.0",
                ]),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedLibrary("objc"),
            ]
        ),
        // Core library — protocol, USB, device management, storage
        .target(
            name: "HiDockKit",
            dependencies: [
                "CLibUSB",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/HiDockKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        // macOS SwiftUI app (built via Xcode project for .app bundle)
        // Sources live in Sources/DockTape/ but the app target is in the .xcodeproj
        // CLI tool — same capabilities as the SwiftUI app, headless
        .executableTarget(
            name: "HiDockCLI",
            dependencies: ["HiDockKit"],
            path: "Sources/HiDockCLI"
        ),
        // Tests
        .testTarget(
            name: "HiDockKitTests",
            dependencies: ["HiDockKit"],
            path: "Tests/HiDockKitTests"
        ),
    ]
)
