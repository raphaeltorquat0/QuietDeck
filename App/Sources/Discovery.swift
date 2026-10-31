import Foundation
import Network
import Observation

/// Procura Decks por Bonjour: serviços `_ssh._tcp` e o nome padrão `steamdeck.local`.
@MainActor @Observable
final class Discovery {
    struct Found: Identifiable, Hashable {
        var name: String
        var host: String
        var id: String { host }
        /// Qualquer Mac ou NAS também anuncia `_ssh._tcp`: os que parecem Deck vêm primeiro.
        var looksLikeDeck: Bool { name.lowercased().contains("deck") }
    }

    private(set) var found: [Found] = []
    /// Só Decks: o serviço devkit não existe em outras máquinas.
    private(set) var devkit: [Found] = []
    private var browsers: [NWBrowser] = []

    func start() {
        guard browsers.isEmpty else { return }
        add(Found(name: "steamdeck", host: "steamdeck.local"), onlyIfResolves: true)
        browse("_ssh._tcp") { [weak self] in self?.add($0, onlyIfResolves: false) }
        browse("_steamos-devkit._tcp") { [weak self] item in
            guard let self, !devkit.contains(item) else { return }
            devkit.append(item)
            add(item, onlyIfResolves: false)
        }
    }

    private func browse(_ type: String, found: @escaping @MainActor (Found) -> Void) {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: type, domain: "local."), using: params)
        b.browseResultsChangedHandler = { results, _ in
            let names: [String] = results.compactMap {
                if case let .service(name, _, _, _) = $0.endpoint { name } else { nil }
            }
            Task { @MainActor in
                for name in names { found(Found(name: name, host: Self.hostName(for: name))) }
            }
        }
        b.start(queue: .main)
        browsers.append(b)
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
    }

    /// O nome do serviço pode vir como "steamdeck [aa:bb:cc]"; o host mDNS é só a primeira palavra.
    nonisolated static func hostName(for serviceName: String) -> String {
        (serviceName.split(separator: " ").first.map(String.init) ?? serviceName) + ".local"
    }

    private func add(_ item: Found, onlyIfResolves: Bool) {
        if onlyIfResolves {
            Task.detached {
                let resolved = Host(name: item.host).address != nil
                await MainActor.run { [weak self] in if resolved { self?.insert(item) } }
            }
        } else {
            insert(item)
        }
    }

    private func insert(_ item: Found) {
        guard !found.contains(where: { $0.host == item.host }) else { return }
        found.append(item)
        found.sort { ($0.looksLikeDeck ? 0 : 1, $0.name) < ($1.looksLikeDeck ? 0 : 1, $1.name) }
    }
}
