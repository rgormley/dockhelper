// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dockhelper",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "dockhelper",
            path: "Sources/dockhelper"
        )
    ],
    swiftLanguageModes: [.v6]
)
