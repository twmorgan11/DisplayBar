// swift-tools-version:6.0
// Lets editors (SourceKit-LSP / Xcode) index the sources together. The app bundle itself is built by ./build.sh.
import PackageDescription

let package = Package(
    name: "DisplayBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DisplayBar", path: "Sources"),
    ]
)
