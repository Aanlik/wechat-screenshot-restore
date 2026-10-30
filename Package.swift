// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeChatScreenshotRestore",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WeChatScreenshotRestoreApp", targets: ["WeChatScreenshotRestoreApp"]),
        .library(name: "WindowSharingRuntime", type: .dynamic, targets: ["WindowSharingRuntime"]),
    ],
    targets: [
        .target(name: "WeChatScreenshotRestoreCore"),
        .target(name: "WeChatScreenshotRestoreInstaller", dependencies: ["WeChatScreenshotRestoreCore"]),
        .executableTarget(
            name: "WeChatScreenshotRestoreApp",
            dependencies: ["WeChatScreenshotRestoreCore", "WeChatScreenshotRestoreInstaller"]
        ),
        .target(
            name: "WindowSharingRuntime",
            path: "Sources/WindowSharingRuntime",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
