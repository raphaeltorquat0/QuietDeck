import AppKit
import CryptoKit
import DeckKit
import DeckRemote
import Observation
import SwiftUI

/// Capas por título, em cache no disco. Sem chave do SteamGridDB, cada jogo mostra a capa gerada.
@MainActor @Observable
final class CoverStore {
    private(set) var images: [String: NSImage] = [:]
    private var pending = Set<String>()

    func file(for title: String, kind: ArtKind = .portrait) -> URL {
        let hash = SHA256.hash(data: Data((title.lowercased() + kind.rawValue).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return Paths.covers.appending(path: hash + ".png")
    }

    func key(_ title: String, _ kind: ArtKind) -> String { title.lowercased() + "|" + kind.rawValue }

    func image(_ title: String, kind: ArtKind = .portrait) -> NSImage? { images[key(title, kind)] }

    /// Arte da Estante, sempre em PNG: o Steam vai receber este mesmo arquivo.
    func store(_ remote: URL, title: String, kind: ArtKind) async {
        guard let (data, _) = try? await URLSession.shared.data(from: remote), let image = save(data, title: title, kind: kind) else { return }
        images[key(title, kind)] = image
    }

    /// Qualquer formato vira PNG no disco: o arquivo do cache também vai ao Steam.
    private func save(_ data: Data, title: String, kind: ArtKind) -> NSImage? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: file(for: title, kind: kind))
        return image
    }

    func load(_ title: String, kind: ArtKind = .portrait) {
        let id = key(title, kind)
        guard images[id] == nil, pending.insert(id).inserted else { return }
        let url = file(for: title, kind: kind)
        let apiKey = Keychain.password(for: AppModel.steamGridKeyAccount)
        Task {
            defer { pending.remove(id) }
            if let image = NSImage(contentsOf: url) { images[id] = image; return }
            guard let apiKey, let game = try? await SteamGridDB(key: apiKey).search(title).first,
                  let art = try? await SteamGridDB(key: apiKey).images(kind, gameID: game.id).first,
                  let remote = URL(string: art.url), let (data, _) = try? await URLSession.shared.data(from: remote) else { return }
            images[id] = save(data, title: title, kind: kind)
        }
    }
}

/// Capa de um jogo: a arte real ou, sem ela, uma capa desenhada com o nome e o ícone do sistema.
struct CoverView: View {
    @Environment(AppModel.self) private var model
    var title: String
    var symbol = "gamecontroller"
    /// Nome na capa gerada, quando difere do título que indexa a arte.
    var label: String?

    var body: some View {
        ZStack {
            if let image = model.covers.image(title) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.accentColor.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 8) {
                    Image(systemName: symbol).font(.title).foregroundStyle(.white.opacity(0.85))
                    Text(verbatim: label ?? title).font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 8)
                }
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task { model.covers.load(title) }
    }
}

extension GameSystem {
    /// Símbolo do tipo de mídia: SF Symbols não têm um ícone por console.
    var symbol: String {
        if chd != nil || ["ps3", "gc", "wii", "xbox", "wiiu", "psp"].contains(id) { return "opticaldisc" }
        return ["arcade", "neogeo"].contains(id) ? "arcade.stick" : "gamecontroller"
    }
}

struct CoverFlight: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var from: CGRect
}

/// A capa sobe da Biblioteca e encolhe até a fila no rodapé da sidebar.
struct FlyingCover: View {
    @Environment(AppModel.self) private var model
    var flight: CoverFlight
    var target: CGRect
    @State private var arrived = false

    var body: some View {
        CoverView(title: flight.title)
            .frame(width: arrived ? 20 : flight.from.width)
            .position(arrived ? CGPoint(x: target.midX, y: target.midY) : CGPoint(x: flight.from.midX, y: flight.from.midY))
            .opacity(arrived ? 0.2 : 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(Motion.spring) { arrived = true } completion: { model.flights.removeAll { $0.id == flight.id } }
            }
    }
}
