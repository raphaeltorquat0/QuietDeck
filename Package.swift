// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuietDeck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeckKit", targets: ["DeckKit"]),
        .library(name: "DeckRemote", targets: ["DeckRemote"]),
    ],
    targets: [
        // Sem dependência de AppKit: compila no Linux para os testes de integração do CI (DECISIONS.md #6).
        .target(name: "DeckKit", path: "Packages/DeckKit/Sources/DeckKit", resources: [.copy("Resources")]),

        .target(name: "DeckRemote", dependencies: ["DeckKit"], path: "Packages/DeckRemote/Sources/DeckRemote"),
        .testTarget(name: "DeckRemoteTests", dependencies: ["DeckRemote"], path: "Packages/DeckRemote/Tests/DeckRemoteTests",
                    resources: [.copy("Fixtures")]),
    ]
)
