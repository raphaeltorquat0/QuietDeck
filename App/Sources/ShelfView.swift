import DeckKit
import DeckRemote
import Observation
import SwiftUI

/// Índice do acervo no Mac. Guardado por fonte: a próxima varredura só refaz hash do que mudou.
@MainActor @Observable
final class ShelfStore {
    struct Snapshot: Codable {
        var source: ShelfSource
        var records: [ScanRecord]
    }

    private(set) var snapshots: [Snapshot] = []
    private(set) var items: [ShelfItem] = []
    private(set) var undecided = 0
    private(set) var scanning = false
    private(set) var failure: String?
    private(set) var meta: [String: ShelfMeta] = [:]
    private(set) var lookingUp = false
    @ObservationIgnored private let file = Paths.support.appending(path: "shelf-index.json")
    @ObservationIgnored private let metaFile = Paths.support.appending(path: "shelf-meta.json")
    static var dats: URL { Paths.support.appending(path: "dats") }

    init() {
        snapshots = (try? JSONDecoder().decode([Snapshot].self, from: Data(contentsOf: file))) ?? []
        meta = (try? JSONDecoder().decode([String: ShelfMeta].self, from: Data(contentsOf: metaFile))) ?? [:]
    }

    /// Consulta só o que falta. Jogo sem resultado fica registrado: repetir gastaria a cota diária.
    func lookUp(_ wanted: [ShelfItem], covers: CoverStore, describe: (Error) -> String, retry: Bool = false) async {
        guard !lookingUp else { return }
        let screenScraper = Keychain.decoded(ScreenScraper.Credentials.self, for: AppModel.screenScraperAccount).map(ScreenScraper.init)
        let igdb = Keychain.decoded(IGDB.Credentials.self, for: AppModel.igdbAccount).map(IGDB.init)
        guard screenScraper != nil || igdb != nil else { return }
        lookingUp = true
        defer { lookingUp = false }
        for item in wanted where meta[item.id] == nil || (retry && meta[item.id]?.title == nil) {
            do {
                var found = try await screenScraper?.lookup(item)
                if found == nil { found = try await igdb?.lookup(title: item.deckTitle, systemID: item.systemID) }
                meta[item.id] = found?.meta ?? ShelfMeta()
                if let cover = found?.cover { await covers.store(cover, title: item.deckTitle, kind: .portrait) }
                if let hero = found?.hero { await covers.store(hero, title: item.deckTitle, kind: .hero) }
                try? JSONEncoder().encode(meta).write(to: metaFile)
            } catch {
                // Cota esgotada ou senha errada não melhora no próximo jogo.
                failure = describe(error)
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Montagem refeita fora da tela: ler os DATs de novo não pode travar a grade.
    func rebuild(catalog: Catalog) async {
        let records = snapshots.flatMap(\.records), systems = catalog.systems, folder = Self.dats
        let result = await Task.detached { ShelfIndex.build(records, systems: systems, dats: ShelfScanner.loadDats(folder)) }.value
        items = result.items
        undecided = result.undecided.count
    }

    func scan(_ sources: [ShelfSource], catalog: Catalog, describe: (Error) -> String) async {
        guard !scanning else { return }
        scanning = true
        failure = nil
        defer { scanning = false }
        var fresh: [Snapshot] = []
        for source in sources {
            let cache = ShelfScanner.cache(snapshots.first { $0.source == source }?.records ?? [])
            do {
                fresh.append(Snapshot(source: source, records: try await Self.records(source, catalog: catalog, cache: cache)))
            } catch {
                // Servidor fora do ar não apaga o que já se conhece dele.
                failure = describe(error)
                if let old = snapshots.first(where: { $0.source == source }) { fresh.append(old) }
            }
        }
        snapshots = fresh
        try? JSONEncoder().encode(fresh).write(to: file)
        await rebuild(catalog: catalog)
    }

    private nonisolated static func records(_ source: ShelfSource, catalog: Catalog, cache: ShelfScanner.Cache) async throws -> [ScanRecord] {
        switch source {
        case let .folder(path):
            return try await ShelfScanner.scanFolder(URL(fileURLWithPath: path), systems: catalog.systems, cache: cache)
        case let .ssh(host, user, port, path):
            let config = SSHConfig(host: host, port: port, user: user, identityFile: Paths.key, knownHostsFile: Paths.knownHosts)
            return try await ShelfScanner.scanRemote(SSHRunner(config: config), root: path, systems: catalog.systems, cache: cache)
        case let .service(url):
            return try await ShelfScanner.scanService(url, token: Keychain.password(for: AppModel.shelfTokenAccount) ?? "")
        }
    }

    /// Capturas do press kit: só homebrew do catálogo, nunca jogo comercial.
    func showDemo(_ catalog: Catalog) {
        items = catalog.free.map(\.item)
        for game in catalog.free {
            var demo = ShelfMeta()
            demo.year = game.year
            demo.developer = game.author
            meta[game.item.id] = demo
        }
    }

    func source(of item: ShelfItem) -> ShelfSource? {
        snapshots.first { $0.records.contains { $0.path == item.entry } }?.source
    }
}

/// Estante: a loja sobre o acervo do próprio usuário.
struct ShelfView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    var deck: LiveDeck
    @State private var tab = Tab.shelf
    @State private var search = ""
    @State private var system: String?
    @State private var status = Status.all
    @State private var sort = Sort.title
    @State private var selected: ShelfItem?
    @State private var genre: String?
    @State private var year: Int?
    @Namespace private var cover

    enum Tab: Hashable { case shelf, free, guide }
    enum Status: Hashable { case all, installed, available }
    enum Sort: Hashable { case title, size, year }

    private func meta(_ item: ShelfItem) -> ShelfMeta? { model.shelf.meta[item.id] }

    private var shown: [ShelfItem] {
        let found = model.shelf.items.filter { item in
            (system == nil || item.systemID == system)
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
                && (status == .all || (status == .installed) == (deck.shelfInstalled[item.id] != nil))
                && (genre == nil || meta(item)?.genres.contains(genre ?? "") == true)
                && (year == nil || meta(item)?.year == year)
        }
        switch sort {
        case .title: return found
        case .size: return found.sorted { $0.size > $1.size }
        case .year: return found.sorted { (meta($0)?.year ?? .max) < (meta($1)?.year ?? .max) }
        }
    }

    private func detail(_ item: ShelfItem) -> FreeGame? {
        model.catalog.free.first { $0.item.id == item.id }
    }

    var body: some View {
        ZStack {
            if let item = selected {
                ShelfDetail(deck: deck, item: item, free: detail(item), namespace: cover) { Motion.run { selected = nil } }.zIndex(1)
            } else {
                Page {
                    Picker("Section", selection: $tab) {
                        Text("Your Collection").tag(Tab.shelf)
                        Text("Free and Legal").tag(Tab.free)
                        Text("Stocking Guide").tag(Tab.guide)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    switch tab {
                    case .shelf: collection
                    case .free: free
                    case .guide: ShelfGuide()
                    }
                }
            }
        }
        .task {
            if model.shelf.items.isEmpty { await model.shelf.rebuild(catalog: model.catalog) }
        }
    }

    private var free: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Homebrew and freeware whose licenses allow redistribution. Each one downloads from its official source and is checked against the catalog hash.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                ForEach(model.catalog.free) { tile($0.item) }
            }
        }
    }

    @ViewBuilder private var collection: some View {
        if model.settings.shelfSources.isEmpty && model.shelf.items.isEmpty {
            EmptyState(title: "Your shelf is empty", message: "Point QuietDeck at your own collection, on this Mac or on a server on your network.", action: "Add a Source…") { openSettings() }
        } else {
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Picker("Status", selection: $status) {
                    Text("All").tag(Status.all)
                    Text("On the Deck").tag(Status.installed)
                    Text("Not installed").tag(Status.available)
                }
                .fixedSize()
                Picker("Sort", selection: $sort) {
                    Text("Name").tag(Sort.title)
                    Text("Size").tag(Sort.size)
                    Text("Year").tag(Sort.year)
                }
                .fixedSize()
                if !genres.isEmpty {
                    Picker("Genre", selection: $genre) {
                        Text("All").tag(String?.none)
                        ForEach(genres, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                    }
                    .fixedSize()
                }
                if !years.isEmpty {
                    Picker("Year", selection: $year) {
                        Text("All").tag(Int?.none)
                        ForEach(years, id: \.self) { Text(verbatim: String($0)).tag(Int?.some($0)) }
                    }
                    .fixedSize()
                }
                Spacer()
                if model.shelf.scanning || model.shelf.lookingUp { ProgressView().controlSize(.small) }
                Menu("Scan") {
                    Button("Scan Sources") { scan() }
                    Button("Look Up Missing Metadata") { lookUp(retry: true) }
                } primaryAction: { scan() }
                .fixedSize().disabled(model.shelf.scanning)
            }
            if let failure = model.shelf.failure {
                Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle") }.font(.callout).foregroundStyle(.orange)
            }
            if model.shelf.undecided > 0 {
                InlineNote(text: "\(model.shelf.undecided) files fit more than one system. Move them into a system folder.", symbol: "questionmark.folder")
            }
            chips
            if shown.isEmpty {
                EmptyState(title: "Nothing here", message: "Scan your sources, or change the filters.", action: "Scan") { scan() }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                    ForEach(shown) { tile($0) }
                }
            }
        }
    }

    private var genres: [String] { Array(Set(model.shelf.meta.values.flatMap(\.genres))).sorted() }
    private var years: [Int] { Array(Set(model.shelf.meta.values.compactMap(\.year))).sorted() }

    private func scan() {
        let sources = model.settings.shelfSources, catalog = model.catalog, shelf = model.shelf, m = model
        Task {
            await shelf.scan(sources, catalog: catalog) { m.describe($0) }
            lookUp(retry: false)
        }
    }

    private func lookUp(retry: Bool) {
        let shelf = model.shelf, m = model
        Task { await shelf.lookUp(shelf.items, covers: m.covers, describe: { m.describe($0) }, retry: retry) }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(Text("All"), nil)
                ForEach(Array(Set(model.shelf.items.map(\.systemID))).sorted(), id: \.self) {
                    chip(Text(verbatim: model.catalog.system($0)?.name ?? $0), $0)
                }
            }
        }
    }

    private func chip(_ label: Text, _ id: String?) -> some View {
        Button { Motion.run { system = id } } label: {
            label.font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(system == id ? Color.white : .primary)
                .background(system == id ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tile(_ item: ShelfItem) -> some View {
        Button { Motion.run { selected = item } } label: {
            CoverView(title: item.deckTitle, symbol: model.catalog.system(item.systemID)?.symbol ?? "gamecontroller", label: meta(item)?.title ?? item.title)
                .matchedGeometryEffect(id: item.id, in: cover)
                .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
                .overlay(alignment: .topTrailing) {
                    if deck.shelfInstalled[item.id] != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(6)
                            .accessibilityLabel(Text("On the Deck"))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityHint(Text(verbatim: model.catalog.system(item.systemID)?.name ?? ""))
    }
}

/// Detalhe isolado para as capturas do press kit.
struct ShelfDetailPreview: View {
    var deck: LiveDeck
    var game: FreeGame
    @Namespace private var space

    var body: some View { ShelfDetail(deck: deck, item: game.item, free: game, namespace: space) {} }
}

struct ShelfDetail: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    var item: ShelfItem
    /// Preenchido quando vem do catálogo "Grátis e legal".
    var free: FreeGame?
    var namespace: Namespace.ID
    var close: () -> Void
    @State private var useSD = false
    @State private var addToSteam = true
    @State private var confirmInstall = false
    @State private var confirmRemove = false

    private var entry: ShelfManifestEntry? { deck.shelfInstalled[item.id] }
    private var meta: ShelfMeta? { model.shelf.meta[item.id] }
    private var volume: Volume? { useSD ? deck.status.sdCard : deck.status.internalStorage }
    private var place: String { useSD ? "microSD" : String(localized: "internal storage") }
    private var fits: Bool { volume.map { SpaceAdvisor.fits(size: item.size, free: $0.free) } ?? true }

    /// Só o que a Estante instalou: é o que ela sabe remover.
    private var suggestion: [SpaceAdvisor.Installed] {
        guard let volume else { return [] }
        let installed = deck.shelfInstalled.values.map {
            SpaceAdvisor.Installed(title: $0.title, size: $0.size, lastPlayed: deck.shortcutsPlayed[$0.title] ?? 0)
        }
        return SpaceAdvisor.suggest(size: item.size, free: volume.free, installed: installed)
    }

    var body: some View {
        Page {
            Button(action: close) { Label("Shelf", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary)
            if let hero = model.covers.image(item.deckTitle, kind: .hero) {
                Image(nsImage: hero).resizable().scaledToFill().frame(height: 220).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 20) {
                CoverView(title: item.deckTitle, symbol: model.catalog.system(item.systemID)?.symbol ?? "gamecontroller", label: meta?.title ?? item.title)
                    .matchedGeometryEffect(id: item.id, in: namespace)
                    .frame(width: 190)
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: meta?.title ?? item.title).font(.title2.weight(.semibold))
                    if let summary = meta?.summary { Text(verbatim: summary).font(.callout).lineLimit(8) }
                    facts
                    actions
                }
            }
        }
        .task { model.covers.load(item.deckTitle, kind: .hero) }
        .confirmationDialog("Restart Steam?", isPresented: $confirmInstall) {
            Button("Install and Add to Steam", role: .destructive) { install() }
        } message: { Text("Steam restarts to save the shortcuts, so any running game will close.") }
        .confirmationDialog("Restart Steam?", isPresented: $confirmRemove) {
            Button("Remove from Deck", role: .destructive) { remove() }
        } message: { Text("Steam restarts to remove the shortcut, so any running game will close.") }
    }

    private var facts: some View {
        Grid(alignment: .leading, verticalSpacing: 4) {
            GridRow { Text("System").foregroundStyle(.secondary); Text(verbatim: model.catalog.system(item.systemID)?.name ?? item.systemID) }
            if let year = meta?.year ?? free?.year { GridRow { Text("Year").foregroundStyle(.secondary); Text(verbatim: String(year)) } }
            if let developer = meta?.developer ?? free?.author { GridRow { Text("Developer").foregroundStyle(.secondary); Text(verbatim: developer) } }
            if let players = meta?.players { GridRow { Text("Players").foregroundStyle(.secondary); Text(verbatim: players) } }
            if let genres = meta?.genres, !genres.isEmpty { GridRow { Text("Genre").foregroundStyle(.secondary); Text(verbatim: genres.formatted()) } }
            GridRow { Text("Size").foregroundStyle(.secondary); Text(item.size, format: .byteCount(style: .file)) }
            GridRow { Text("On the Deck").foregroundStyle(.secondary); Text(entry == nil ? "Not installed" : "Installed") }
            if let free {
                GridRow {
                    Text("License").foregroundStyle(.secondary)
                    if let url = URL(string: free.licenseURL) { Link(free.license, destination: url) }
                }
                GridRow {
                    Text("Official page").foregroundStyle(.secondary)
                    if let url = URL(string: free.homepage) { Link(url.host ?? free.homepage, destination: url) }
                }
            } else if item.verified { GridRow { Text("Hash").foregroundStyle(.secondary); Text("Matches your DAT") } }
            if !item.duplicates.isEmpty { GridRow { Text("Copies").foregroundStyle(.secondary); Text(verbatim: "\(item.duplicates.count + 1)") } }
        }
        .font(.callout)
    }

    @ViewBuilder private var actions: some View {
        if entry != nil {
            Button("Remove from Deck", role: .destructive) { confirmRemove = true }
        } else {
            if deck.sdMount != nil { Toggle("Install on microSD", isOn: $useSD) }
            Toggle("Add to Steam", isOn: $addToSteam).disabled(deck.steamUsers.isEmpty)
            if let volume {
                Text("\(volume.free, format: .byteCount(style: .file)) free on \(place)").font(.callout)
                    .foregroundStyle(fits ? Color.secondary : Color.orange)
            }
            if !fits {
                if suggestion.isEmpty {
                    InlineNote(text: "Not enough space, and nothing from the shelf can free it.", symbol: "externaldrive.badge.exclamationmark", tint: .orange)
                } else {
                    InlineNote(text: "Not enough space. Least played: \(suggestion.map(\.title).formatted())", symbol: "externaldrive.badge.exclamationmark", tint: .orange)
                }
            }
            Button("Install on Deck") { addToSteam ? (confirmInstall = true) : install() }
                .buttonStyle(.borderedProminent).disabled(!fits)
        }
    }

    private func install() {
        let sd = useSD ? deck.sdMount : nil
        if let free {
            model.enqueue(String(localized: "Install \(item.title)"), .freeInstall(game: free, sdMount: sd))
        } else if let source = model.shelf.source(of: item) {
            model.enqueue(String(localized: "Install \(item.title)"), .shelfInstall(item: item, source: source, sdMount: sd))
        } else { return }
        guard addToSteam, let user = deck.steamUsers.first, let system = model.catalog.system(item.systemID) else { return }
        let title = item.deckTitle
        model.enqueue(String(localized: "Add to Steam"), .addToSteam(user: user, games: [GameRef(systemID: item.systemID, title: title)], sdMount: sd))
        // O id do atalho não depende da ROM, só do emulador e do nome.
        guard let appID = Library.shortcut(name: title, romPath: "", system: system, catalog: model.catalog, corePath: nil)?.appID else { return }
        for kind in [ArtKind.portrait, .hero] where FileManager.default.fileExists(atPath: model.covers.file(for: title, kind: kind).path) {
            model.enqueue(String(localized: "Artwork: \(title)"), .applyArtFile(user: user, appID: appID, kind: kind, localPath: model.covers.file(for: title, kind: kind).path))
        }
    }

    private func remove() {
        model.enqueue(String(localized: "Remove \(item.title)"), .shelfRemove(item: item, user: deck.steamUsers.first))
    }
}

/// Como abastecer o acervo com as próprias mídias.
struct ShelfGuide: View {
    private struct Tool: Identifiable {
        var name: String
        var url: String
        var note: LocalizedStringKey
        var id: String { name }
    }

    private let cartridges = [
        Tool(name: "Open Source Cartridge Reader", url: "https://github.com/sanni/cartreader", note: "Open-source reader you build around an Arduino Mega; covers many cartridge systems."),
        Tool(name: "GB Operator", url: "https://www.epilogue.co/support/getting-started/what-is-gb-operator", note: "USB reader for Game Boy, Game Boy Color and Game Boy Advance."),
        Tool(name: "INLretro", url: "https://gitlab.com/InfiniteNesLives/INL-retro-progdump", note: "Programmer and dumper software and firmware."),
        Tool(name: "Retrode", url: "https://www.retrode.com/", note: "USB adapter. Its site says the Retrode3 can't be ordered yet."),
    ]
    private let discs = [
        Tool(name: "redumper", url: "https://github.com/superg/redumper", note: "Low-level disc dumper."),
        Tool(name: "DiscImageCreator", url: "https://github.com/saramibreak/DiscImageCreator", note: "Disc imaging tool."),
        Tool(name: "ImgBurn", url: "https://www.imgburn.com/", note: "Free Windows tool for reading discs to an image."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stock your shelf with games you own. Copy your own cartridges and discs, then keep the files on this Mac or on your server. Laws vary, so check yours.")
                .foregroundStyle(.secondary)
            Card(title: "Cartridges", symbol: "memorychip") { list(cartridges) }
            Card(title: "Discs", symbol: "opticaldisc") {
                Text("Read discs on a computer with an optical drive. Keep every track together with its .cue file.").font(.callout)
                list(discs)
            }
            Card(title: "Organize", symbol: "folder") {
                Text("Use one folder per system, like snes/ or psx/. QuietDeck also reads file headers and extensions.").font(.callout)
                MonoText(text: ["gba/Game.gba", "psx/Game.cue", "psx/Game (Track 1).bin"].joined(separator: "\n"))
                Text("To check your files, put No-Intro or Redump DAT files you supply in this folder, then scan again:").font(.callout)
                MonoText(text: ShelfStore.dats.path)
            }
        }
    }

    private func list(_ tools: [Tool]) -> some View {
        ForEach(tools) { tool in
            VStack(alignment: .leading, spacing: 1) {
                if let url = URL(string: tool.url) { Link(tool.name, destination: url) }
                Text(tool.note).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
