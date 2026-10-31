import DeckKit
import DeckRemote
import SwiftUI
import UniformTypeIdentifiers

/// Biblioteca: o que vai para o Deck (soltar, escolher, pasta sincronizada) e o que já está lá.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var candidates: [Candidate] = []
    @State private var targetSD = false
    @State private var addToSteam = false
    @State private var dropping = false
    @State private var choosing = false
    @State private var confirmSend = false
    @State private var artGame: Library.Game?
    @State private var selected = Set<String>()
    @State private var confirmAdd = false

    struct Candidate: Identifiable {
        var id: String { path }
        var path: String
        var size: Int64
        var systemID: String?
        var options: [String]
        var name: String { (path as NSString).lastPathComponent }
    }

    var body: some View {
        Page {
            dropZone
            if !candidates.isEmpty { pending }
            onDeck
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data, .folder], allowsMultipleSelection: true) { result in
            let urls = (try? result.get()) ?? []
            urls.forEach { _ = $0.startAccessingSecurityScopedResource() }
            scan(urls)
        }
        .confirmationDialog("Add to Steam after sending?", isPresented: $confirmSend) {
            Button("Send and Add to Steam", role: .destructive) { send() }
        } message: { Text("Steam restarts to save the shortcuts, so any running game will close.") }
        .confirmationDialog("Add \(selected.count) games to Steam?", isPresented: $confirmAdd) {
            Button("Add to Steam", role: .destructive) { addSelected() }
        } message: { Text("Steam restarts to save the shortcuts, so any running game will close. A backup of shortcuts.vdf is kept.") }
        .sheet(item: $artGame) { game in ArtPicker(deck: deck, game: game) }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Drop ROMs or BIOS files here")
            HStack {
                Button("Choose Files…") { choosing = true }.keyboardShortcut("o")
                if !model.settings.syncFolders.isEmpty {
                    Button("Scan Sync Folders") { scan(model.settings.syncFolders.map { URL(fileURLWithPath: $0) }) }
                }
            }
            InlineNote(text: "Files must already be yours. QuietDeck never downloads ROMs.")
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(dropping ? Color.accentColor : .secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        .dropDestination(for: URL.self) { urls, _ in
            scan(urls)
            return true
        } isTargeted: { dropping = $0 }
    }

    private var pending: some View {
        Card(title: "Ready to Send", symbol: "shippingbox") {
            ForEach($candidates) { $item in
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Text(item.size.bytes).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("System", selection: $item.systemID) {
                        Text("Choose…").tag(String?.none)
                        ForEach(item.options, id: \.self) { Text(model.catalog.system($0)?.name ?? $0).tag(String?.some($0)) }
                    }
                    .labelsHidden().frame(width: 220)
                    Button { candidates.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(item.name)")
                }
            }
            if deck.sdMount != nil {
                Picker("Send to", selection: $targetSD) {
                    Text("Internal").tag(false)
                    Text("microSD").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 240).disabled(deck.paths?.isEmuDeck == true)
            }
            Toggle("Add to Steam when done", isOn: $addToSteam).disabled(deck.steamUsers.isEmpty)
            InlineNote(text: "Archives are extracted when the emulator can't read them, CD and DVD images become CHD on supported systems, and multi-disc games get an .m3u. Your original files aren't changed.")
            HStack {
                Button("Send \(candidates.filter { $0.systemID != nil }.count) Games") {
                    if addToSteam { confirmSend = true } else { send() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!candidates.contains { $0.systemID != nil })
                Button("Clear") { candidates = [] }
            }
        }
    }

    private var onDeck: some View {
        Card(title: "On the Deck", symbol: "gamecontroller") {
            if deck.games.isEmpty { Text("No games yet").foregroundStyle(.secondary) }
            let groups = Dictionary(grouping: deck.games, by: \.systemID)
            ForEach(groups.keys.sorted(), id: \.self) { id in
                DisclosureGroup("\(model.catalog.system(id)?.name ?? id) (\(groups[id]?.count ?? 0))") {
                    ForEach(groups[id] ?? []) { game in
                        HStack {
                            Toggle(game.name, isOn: Binding(
                                get: { selected.contains(game.id) },
                                set: { if $0 { selected.insert(game.id) } else { selected.remove(game.id) } }))
                            Spacer()
                            Text(game.size.bytes).font(.caption).foregroundStyle(.secondary)
                            Button("Artwork…") { artGame = game }
                        }
                    }
                }
            }
            if !selected.isEmpty {
                Button("Add \(selected.count) to Steam…") { confirmAdd = true }.disabled(deck.steamUsers.isEmpty)
            }
        }
    }

    private func scan(_ urls: [URL]) {
        let catalog = model.catalog
        Task.detached {
            let bios = await ROMScanner.biosFiles(urls, table: catalog.bios.entries)
            let found = ROMScanner.scan(urls, catalog: catalog).filter { !bios.contains($0.path) }
            await MainActor.run {
                model.importBIOS(bios)
                let known = Set(candidates.map(\.path))
                candidates += found.filter { !known.contains($0.path) }.map { c in
                    switch c.detection {
                    case let .system(id): Candidate(path: c.path, size: c.size, systemID: id, options: catalog.systems.map(\.id))
                    case let .ambiguous(ids): Candidate(path: c.path, size: c.size, systemID: nil, options: ids)
                    case .unknown: Candidate(path: c.path, size: c.size, systemID: nil, options: catalog.systems.map(\.id))
                    }
                }
            }
        }
    }

    private func send() {
        let sd = targetSD ? deck.sdMount : nil
        var refs: [GameRef] = []
        for item in candidates {
            guard let id = item.systemID else { continue }
            model.enqueue("Send \(item.name)", .importROM(localPath: item.path, systemID: id, sdMount: sd))
            refs.append(GameRef(systemID: id, title: ROMPlan.displayName(item.name)))
        }
        if addToSteam, let user = deck.steamUsers.first { model.enqueue("Add to Steam", .addToSteam(user: user, games: Array(Set(refs)), sdMount: sd)) }
        candidates.removeAll { $0.systemID != nil }
    }

    private func addSelected() {
        guard let user = deck.steamUsers.first else { return }
        let refs = deck.games.filter { selected.contains($0.id) }.map { GameRef(systemID: $0.systemID, title: ROMPlan.displayName($0.name)) }
        model.enqueue("Add to Steam", .addToSteam(user: user, games: Array(Set(refs)), sdMount: nil))
        selected = []
    }
}

/// Prévia das artes do SteamGridDB antes de aplicar. A chave do usuário fica no Keychain.
struct ArtPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var deck: LiveDeck
    var game: Library.Game
    @State private var results: [SteamGridDB.Game] = []
    @State private var chosen: SteamGridDB.Game?
    @State private var images: [ArtKind: [SteamGridDB.Image]] = [:]
    @State private var kind = ArtKind.portrait
    @State private var picked: [ArtKind: SteamGridDB.Image] = [:]
    @State private var message: String?

    private var title: String { ROMPlan.displayName(game.name) }
    private var key: String? { Keychain.password(for: AppModel.steamGridKeyAccount) }
    private var appID: UInt32? {
        guard let system = model.catalog.system(game.systemID) else { return nil }
        return Library.shortcut(name: title, romPath: game.path, system: system, catalog: model.catalog, corePath: nil)?.appID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Artwork for \(title)").font(.title3.bold())
            if key == nil {
                InlineNote(text: "Add your SteamGridDB API key in Settings to search for artwork.", symbol: "key")
            } else {
                Picker("Game", selection: $chosen) {
                    Text("Choose…").tag(SteamGridDB.Game?.none)
                    ForEach(results) { Text($0.name).tag(SteamGridDB.Game?.some($0)) }
                }
                Picker("Type", selection: $kind) {
                    ForEach(ArtKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))]) {
                        ForEach(images[kind] ?? []) { image in
                            Button { picked[kind] = image } label: {
                                AsyncImage(url: URL(string: image.thumb)) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                                    .frame(height: 160)
                                    .overlay { if picked[kind] == image { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3) } }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if let message { InlineNote(text: message, symbol: "exclamationmark.triangle", tint: .orange) }
            InlineNote(text: "Applying artwork doesn't close anything. Steam shows it the next time the library reloads.")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply \(picked.count)") { apply() }.keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .task { await search() }
        .onChange(of: chosen) { Task { await load() } }
        .onChange(of: kind) { Task { await load() } }
    }

    private func search() async {
        guard let key else { return }
        do {
            results = try await SteamGridDB(key: key).search(title)
            chosen = results.first
        } catch { message = String(describing: error) }
    }

    private func load() async {
        guard let key, let chosen, images[kind] == nil else { return }
        do { images[kind] = try await SteamGridDB(key: key).images(kind, gameID: chosen.id) }
        catch { message = String(describing: error) }
    }

    private func apply() {
        guard let user = deck.steamUsers.first, let appID else { return }
        for (kind, image) in picked {
            model.enqueue("Artwork: \(title)", .applyArt(user: user, appID: appID, kind: kind, url: image.url))
        }
        dismiss()
    }
}
