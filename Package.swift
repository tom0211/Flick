// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Flick",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Flick",
            path: "Sources/Flick",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
