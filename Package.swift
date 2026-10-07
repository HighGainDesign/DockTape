// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DockTape",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "hidock", targets: ["HiDockCLI"]),
        .library(name: "HiDockKit", targets: ["HiDockKit"]),
        .library(name: "HiDockKitUSB", targets: ["HiDockKitUSB"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        // Vendored libusb-1.0 (static library, macOS only).
        // ⚠️ Cannot build for iOS — iOS targets must depend only on HiDockKit.
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
        // Core library — protocol, device management, storage, transcription, summarization
        // Cross-platform (macOS + iOS)
        .target(
            name: "HiDockKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/HiDockKit"
        ),
        // macOS-only USB transport — USBConnection, USBDeviceMonitor, DeviceProbe.
        // ⚠️ Cannot build for iOS — iOS targets must depend only on HiDockKit.
        .target(
            name: "HiDockKitUSB",
            dependencies: [
                "HiDockKit",
                "CLibUSB",
            ],
            path: "Sources/HiDockKitUSB",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        // CLI tool — macOS only, uses USB transport
        .executableTarget(
            name: "HiDockCLI",
            dependencies: ["HiDockKit", "HiDockKitUSB"],
            path: "Sources/HiDockCLI"
        ),
        // Tests
        .testTarget(
            name: "HiDockKitTests",
            dependencies: ["HiDockKit"],
            path: "Tests/HiDockKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
