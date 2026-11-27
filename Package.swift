// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Studio",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Markdown rendering for chat messages (MarkdownUI's successor: native text selection,
        // tables, syntax-highlighted code blocks).
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Studio",
            dependencies: [.product(name: "Textual", package: "textual")],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
