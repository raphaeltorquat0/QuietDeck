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
        let file = folder.appending(path: name(title, kind, "generated"))
        return (try? png.write(to: file)) != nil ? file : nil
    }
}

extension ArtMaker {
    /// Nome de capa: sem região/idioma/revisão do nome de ROM e com o artigo de volta à frente
    /// ("Legend of Zelda, The - The Wind Waker (USA)" → "The Legend of Zelda - The Wind Waker").
    nonisolated static func coverTitle(_ title: String) -> String {
        let tags = #"\s*\((USA|Europe|Japan|World|Brazil|Korea|Asia|En|Fr|De|Es|It|Pt|Rev [0-9A-Z]+|v[0-9.]+|[A-Z][a-z](,[A-Z][a-z])+)[^)]*\)"#
        var t = title.replacingOccurrences(of: tags, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let m = t.range(of: #"^(.+?), (The|A|An)(\b.*)$"#, options: .regularExpression) {
            let parts = t[m].split(separator: ",", maxSplits: 1)
            let rest = parts[1].trimmingCharacters(in: .whitespaces)
            let article = rest.split(separator: " ", maxSplits: 1)
            t = "\(article[0]) \(parts[0])" + (article.count > 1 ? " " + article[1] : "")
        }
        return t
    }
}

/// Capa desenhada: cor da família do console, símbolo grande ao fundo e o título em destaque.
/// O hero não leva texto, porque o Steam escreve o nome por cima.
struct GeneratedArt: View {
    var title: String
    var system: GameSystem
    var kind: ArtKind

    private var palette: (Color, Color) {
        let id = system.id
        if ["nes", "snes", "n64", "gb", "gbc", "gba", "nds", "n3ds", "gc", "wii", "wiiu", "switch"].contains(id) {
            return (Color(red: 0.86, green: 0.16, blue: 0.22), Color(red: 0.32, green: 0.05, blue: 0.16))
        }
        if id.hasPrefix("ps") { return (Color(red: 0.10, green: 0.36, blue: 0.85), Color(red: 0.04, green: 0.10, blue: 0.32)) }
        if ["genesis", "mastersystem", "gamegear", "sega32x", "segacd", "saturn", "dreamcast"].contains(id) {
            return (Color(red: 0.05, green: 0.55, blue: 0.75), Color(red: 0.02, green: 0.16, blue: 0.30))
        }
        if id == "xbox" { return (Color(red: 0.25, green: 0.65, blue: 0.20), Color(red: 0.05, green: 0.20, blue: 0.08)) }
        return (Color(red: 0.95, green: 0.55, blue: 0.15), Color(red: 0.35, green: 0.12, blue: 0.05))
    }

    var body: some View {
        let (light, dark) = palette
        let tall = kind == .portrait
        ZStack(alignment: tall ? .topLeading : .leading) {
            LinearGradient(colors: [light, dark], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: tall ? 700 : 900)
            Image(systemName: system.symbol)
                .resizable().scaledToFit()
                .foregroundStyle(.white.opacity(0.12))
                .frame(width: tall ? 460 : 520)
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: tall ? 90 : 60, y: tall ? 80 : 120)
            if kind != .hero {
                VStack(alignment: .leading, spacing: tall ? 18 : 10) {
                    Text(verbatim: system.name.uppercased())
                        .font(.system(size: tall ? 26 : 22, weight: .semibold)).tracking(3)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(verbatim: ArtMaker.coverTitle(title))
                        .font(.system(size: tall ? 64 : 52, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white).lineLimit(tall ? 5 : 2).minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                }
                .padding(tall ? 48 : 44)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
