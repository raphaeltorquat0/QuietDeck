// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuietDeck",
    // Em texto: `.v26` exigiria tools 6.2, e o Linux do CI compila só os pacotes com 6.1.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DeckKit", targets: ["DeckKit"]),
        .library(name: "DeckRemote", targets: ["DeckRemote"]),
    ],
    targets: [
        // Sem dependência de AppKit: compila no Linux para os testes de integração do CI (DECISIONS.md #6).
        .target(name: "DeckKit", path: "Packages/DeckKit/Sources/DeckKit", resources: [.copy("Resources")]),
        .testTarget(name: "DeckKitTests", dependencies: ["DeckKit"], path: "Packages/DeckKit/Tests/DeckKitTests"),

        .target(name: "DeckRemote", dependencies: ["DeckKit"], path: "Packages/DeckRemote/Sources/DeckRemote"),
        .testTarget(name: "DeckRemoteTests", dependencies: ["DeckRemote"], path: "Packages/DeckRemote/Tests/DeckRemoteTests",
                    resources: [.copy("Fixtures")]),
    ]
)
