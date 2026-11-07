import AppKit
import CryptoKit
import DeckKit
import DeckRemote
import SwiftUI

/// Arte dos atalhos de emulador, que o Steam não tem: do SteamGridDB quando há chave, senão desenhada aqui.
/// Tudo fica no Mac e vai ao Deck dentro do Add to Steam, antes de o Steam reiniciar.
@MainActor
enum ArtMaker {
    static let kinds: [ArtKind] = [.portrait, .hero, .wide]

    static func prepare(title: String, system: GameSystem) async -> [ArtKind: String] {
        var art: [ArtKind: String] = [:]
        if let key = Keychain.password(for: AppModel.steamGridKeyAccount), !key.isEmpty {
            art = await fromSteamGridDB(title: title, key: key)
        }
        for kind in kinds where art[kind] == nil {
            if let file = render(title: title, system: system, kind: kind) { art[kind] = file.path }
        }
        return art
    }

    /// Primeira imagem de cada tipo, salva em PNG: o Steam lê o arquivo pela extensão.
    private static func fromSteamGridDB(title: String, key: String) async -> [ArtKind: String] {
        let api = SteamGridDB(key: key)
        guard let game = try? await api.search(title).first else { return [:] }
        var art: [ArtKind: String] = [:]
        for kind in kinds {
            guard let image = try? await api.images(kind, gameID: game.id).first, let url = URL(string: image.url),
                  let (data, _) = try? await URLSession.shared.data(from: url), let png = pngData(NSImage(data: data)) else { continue }
            let file = folder.appending(path: name(title, kind, "sgdb"))
            if (try? png.write(to: file)) != nil { art[kind] = file.path }
        }
        return art
    }

    /// Versão do desenho da capa. Mudou o desenho, mude aqui e guarde a anterior em `drawn`.
    static let generated = "generated-3"
    static let drawn = ["generated", "generated-2", generated]

    /// SHA-256 das capas que o app desenhou para este jogo, em qualquer versão, menos a que vai agora:
    /// só essas são trocadas no Deck, pela capa nova ou pela foto do SteamGridDB.
    static func drawnHashes(titles: [String], kind: ArtKind, except file: String) -> [String] {
        let hash = { (d: Data) in SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        let current = (try? Data(contentsOf: URL(fileURLWithPath: file))).map(hash)
        return titles.flatMap { t in drawn.map { folder.appending(path: name(t, kind, $0)) } }
            .compactMap { try? Data(contentsOf: $0) }.map(hash).filter { $0 != current }
    }

    static var folder: URL {
        let dir = Paths.covers.appending(path: "steam")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func name(_ title: String, _ kind: ArtKind, _ source: String) -> String {
        SHA256.hash(data: Data((title.lowercased() + kind.rawValue + source).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private static func pngData(_ image: NSImage?) -> Data? {
        guard let tiff = image?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    static func size(_ kind: ArtKind) -> CGSize {
        switch kind {
        case .portrait: CGSize(width: 600, height: 900)
        case .hero: CGSize(width: 1920, height: 620)
        default: CGSize(width: 920, height: 430)
        }
    }

    static func render(title: String, system: GameSystem, kind: ArtKind) -> URL? {
        let size = size(kind)
        let renderer = ImageRenderer(content: GeneratedArt(title: title, system: system, kind: kind).frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let png = pngData(renderer.nsImage) else { return nil }
        let file = folder.appending(path: name(title, kind, generated))
        return (try? png.write(to: file)) != nil ? file : nil
    }
}

/// Capa desenhada: faixa com o console, como a caixa do jogo, e o título grande, legível no tile da home.
/// Cada título desloca um pouco a cor da família, para a fileira não virar blocos iguais.
/// O hero não leva texto, porque o Steam escreve o nome por cima.
struct GeneratedArt: View {
    var title: String
    var system: GameSystem
    var kind: ArtKind

    private var hue: Double {
        let id = system.id
        let base: Double = if ["nes", "snes", "n64", "gb", "gbc", "gba", "nds", "n3ds", "gc", "wii", "wiiu", "switch", "switch2"].contains(id) { 0.98 }
            else if id.hasPrefix("ps") { 0.61 }
            else if ["genesis", "mastersystem", "gamegear", "sega32x", "segacd", "saturn", "dreamcast"].contains(id) { 0.54 }
            else if id == "xbox" { 0.33 } else { 0.08 }
        let shift = Double(Array(SHA256.hash(data: Data(title.lowercased().utf8)))[0]) / 255 - 0.5
        return (base + shift * 0.16 + 1).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        let accent = Color(hue: hue, saturation: 0.78, brightness: 0.86)
        let tall = kind == .portrait
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.7, brightness: 0.36), Color(hue: hue, saturation: 0.6, brightness: 0.1)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: system.symbol)
                .resizable().scaledToFit()
                .foregroundStyle(accent.opacity(0.22))
                .frame(width: tall ? 520 : 560)
                .rotationEffect(.degrees(-14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: tall ? 150 : 120, y: tall ? 130 : 200)
            if kind != .hero {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: system.name.uppercased())
                        .font(.system(size: tall ? 34 : 28, weight: .black)).tracking(2)
                        .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal, tall ? 40 : 36).frame(maxWidth: .infinity, minHeight: tall ? 84 : 64, alignment: .leading)
                        .background(accent)
                    Text(verbatim: ROMPlan.shortcutName(title))
                        .font(.system(size: tall ? 104 : 72, weight: .heavy))
                        .foregroundStyle(.white).lineLimit(tall ? 5 : 3).minimumScaleFactor(0.4)
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                        .padding(tall ? 40 : 36)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tall ? .topLeading : .leading)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
