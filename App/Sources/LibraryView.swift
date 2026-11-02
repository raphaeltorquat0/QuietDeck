import DeckKit
import DeckRemote
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Biblioteca: grade de capas, detalhe com hero e entrada de ROMs por soltar, escolher ou sincronizar.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @Namespace private var cover
    @State private var filter: String?
    @State private var candidates: [Candidate] = []
    @State private var unrecognized: [String] = []
    @State private var targetSD = false
    @State private var addToSteam = true
    @State private var dropping = false
    @State private var choosing = false
    @State private var selected: Library.Game?
    @State private var preview: URL?
    @FocusState private var gridFocused: Bool

    struct Candidate: Identifiable {
        var id: String { path }
        var path: String
        var size: Int64
        var systemID: String?
        var options: [String]
        var patch: String?
        var frame = CGRect.zero
        var name: String { (path as NSString).lastPathComponent }
        /// O nome com que o jogo chega ao Deck: traduzido ganha o nome do patch.
        var title: String { ROMPlan.displayName(patch.map { ROMPatch.patchedName(rom: path, patch: $0) } ?? name) }
    }

    /// Discos do mesmo jogo aparecem como uma capa só.
    private var titles: [Library.Game] {
        var seen = Set<String>()
        return deck.games.filter { filter == nil || $0.systemID == filter }.sorted { $0.name < $1.name }.filter {
            seen.insert($0.systemID + ROMPlan.displayName($0.name)).inserted
        }
    }

    var body: some View {
        ZStack {
            if let game = selected {
                GameDetail(deck: deck, game: game, namespace: cover) { Motion.run { selected = nil } }
                    .zIndex(1)
            } else {
                grid
            }
        }
        // `initial`: pela paleta, a Biblioteca nasce com o jogo já pedido.
        .onChange(of: model.openGame, initial: true) {
            if let game = model.openGame {
                Motion.run { selected = game }
                model.openGame = nil
            }
        }
        .quickLookPreview($preview)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data, .folder], allowsMultipleSelection: true) { result in
            scan((try? result.get()) ?? [])
        }
    }

    private var grid: some View {
        Page {
            dropZone
            if !candidates.isEmpty { pending }
            inProgress
            if deck.games.isEmpty {
                EmptyState(title: "No games yet", message: "Drop your own ROMs here to send them to the Deck.", action: "Choose Files…") { choosing = true }
            } else {
                filters
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                    ForEach(titles) { game in tile(game) }
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    guard let first = titles.first else { return .ignored }
                    preview = model.covers.file(for: ROMPlan.displayName(first.name))
                    return .handled
                }
            }
        }
    }

    private func tile(_ game: Library.Game) -> some View {
        let title = ROMPlan.displayName(game.name)
        return Button {
            Motion.run { selected = game }
        } label: {
            CoverView(title: title, symbol: model.catalog.system(game.systemID)?.symbol ?? "gamecontroller")
                .matchedGeometryEffect(id: game.id, in: cover)
                .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(verbatim: model.catalog.system(game.systemID)?.name ?? ""))
    }

    private var filters: some View {
        SystemChips(ids: Array(Set(deck.games.map(\.systemID))).sorted(), selection: $filter)
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
            if !unrecognized.isEmpty {
                let names = unrecognized.formatted()
                InlineNote(text: "Not added, format not recognized: \(names)", symbol: "exclamationmark.triangle", tint: .orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(dropping ? Color.accentColor : .secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        .dropDestination(for: URL.self) { urls, _ in
            scan(urls)
            return true
        } isTargeted: { value in Motion.run { dropping = value } }
    }

    private var pending: some View {
        Card(title: "Ready to Send", symbol: "shippingbox") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach($candidates) { $item in
                        VStack(spacing: 6) {
                            CoverView(title: item.title, symbol: item.systemID.flatMap { model.catalog.system($0)?.symbol } ?? "questionmark")
                                .frame(width: 104)
                                .background(GeometryReader { geo in
                                    Color.clear
                                        .onAppear { item.frame = geo.frame(in: .named("root")) }
                                        .onChange(of: geo.frame(in: .named("root"))) { _, f in item.frame = f }
                                })
                            Picker("System", selection: $item.systemID) {
                                Text("Choose…").tag(String?.none)
                                ForEach(item.options, id: \.self) { Text(verbatim: model.catalog.system($0)?.name ?? $0).tag(String?.some($0)) }
                            }
                            .labelsHidden().frame(width: 104)
                            if let patch = item.patch {
                                Label((patch as NSString).lastPathComponent, systemImage: "bandage")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 104)
                                    .help(Text("This patch is applied before sending. Your original files aren't changed."))
                            }
                            Button { Motion.run { candidates.removeAll { $0.id == item.id } } } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).accessibilityLabel(Text("Remove \(item.name)"))
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if deck.sdMount != nil {
                Picker("Send to", selection: $targetSD) {
                    Text("Internal").tag(false)
                    Text("microSD").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 260).disabled(deck.paths?.isEmuDeck == true)
            }
            Toggle("Add to Steam when done", isOn: $addToSteam).disabled(deck.steamUsers.isEmpty)
            InlineNote(text: "Archives are extracted when the emulator can't read them, CD and DVD images become CHD on supported systems, and multi-disc games get an .m3u. Your original files aren't changed.")
            Button("Send \(candidates.filter { $0.systemID != nil }.count) Games") { send() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.glassProminent)
            .disabled(!candidates.contains { $0.systemID != nil })
        }
    }

    /// Progresso desenhado sobre a própria capa.
    @ViewBuilder private var inProgress: some View {
        let jobs = model.queue.jobs.filter { job in
            if case .importROM = job.action { !job.isFinished } else { false }
        }
        if !jobs.isEmpty {
            Card(title: "Sending", symbol: "arrow.up.circle") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(jobs) { job in
                            let title = if case let .importROM(path, _, _, patch) = job.action { ROMPlan.displayName(patch.map { ROMPatch.patchedName(rom: path, patch: $0) } ?? (path as NSString).lastPathComponent) } else { job.title }
                            CoverView(title: title)
                                .frame(width: 92)
                                .overlay {
                                    ZStack {
                                        Color.black.opacity(0.45)
                                        Circle().stroke(.white.opacity(0.3), lineWidth: 4).frame(width: 44)
                                        Circle().trim(from: 0, to: Double(job.percent ?? 0) / 100)
                                            .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                            .rotationEffect(.degrees(-90)).frame(width: 44)
                                        Text(verbatim: "\(job.percent ?? 0)%").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .animation(Motion.animation, value: job.percent)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(verbatim: title))
                                .accessibilityValue(Text(verbatim: "\(job.percent ?? 0)%"))
                        }
                    }
                }
            }
        }
    }

    private func scan(_ urls: [URL]) {
        urls.forEach { _ = $0.startAccessingSecurityScopedResource() }
        let catalog = model.catalog
        Task.detached {
            let bios = await ROMScanner.biosFiles(urls, table: catalog.bios.entries)
            let found = ROMScanner.scan(urls, catalog: catalog).filter { !bios.contains($0.path) }
            await MainActor.run {
                model.importBIOS(bios)
                let known = Set(candidates.map(\.path))
                let unknown = found.filter { $0.detection == .unknown }.map(\.path)
                let keys = unknown.filter { ($0 as NSString).lastPathComponent.lowercased() == "prod.keys" }
                model.importSwitchKeys(keys)
                var added: [Candidate] = found.filter { !known.contains($0.path) }.compactMap { c in
                    switch c.detection {
                    case let .system(id): Candidate(path: c.path, size: c.size, systemID: id, options: catalog.systems.map(\.id))
                    case let .ambiguous(ids): Candidate(path: c.path, size: c.size, systemID: nil, options: ids)
                    case .unknown: nil
                    }
                }
                // Patch solto vai com a ROM que ainda não tem um, do arrasto ou de antes; sem par, avisa.
                let patches = unknown.filter(ROMPatch.isPatch)
                let pairs = ROMPatch.pair(roms: (candidates + added).filter { $0.patch == nil }.map(\.path), patches: patches)
                for i in added.indices where added[i].patch == nil { added[i].patch = pairs[added[i].path] }
                let paired = Set(pairs.values)
                unrecognized = unknown.filter { !keys.contains($0) && !paired.contains($0) }.map { ($0 as NSString).lastPathComponent }
                Motion.run {
                    for i in candidates.indices where candidates[i].patch == nil { candidates[i].patch = pairs[candidates[i].path] }
                    candidates += added
                }
            }
        }
    }

    private func send() {
        let sd = targetSD ? deck.sdMount : nil
        var refs: [GameRef] = []
        for item in candidates {
            guard let id = item.systemID else { continue }
            model.launch(title: item.title, from: item.frame)
            let name = item.name
            model.enqueue(String(localized: "Send \(name)"), .importROM(localPath: item.path, systemID: id, sdMount: sd, patch: item.patch))
            refs.append(GameRef(systemID: id, title: item.title))
        }
        if addToSteam, let user = deck.steamUsers.first {
            model.enqueue(String(localized: "Add to Steam"), .addToSteam(user: user, games: Array(Set(refs)), sdMount: sd))
        }
        Motion.run { candidates.removeAll { $0.systemID != nil } }
    }
}

/// Detalhe do jogo: hero no topo, a capa vem da grade por `matchedGeometryEffect`.
struct GameDetail: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    var game: Library.Game
    var namespace: Namespace.ID
    var close: () -> Void
    @State private var results: [SteamGridDB.Game] = []
    @State private var images: [ArtKind: [SteamGridDB.Image]] = [:]
    @State private var kind = ArtKind.portrait
    @State private var picked: [ArtKind: SteamGridDB.Image] = [:]
    @State private var failure: String?

    private var title: String { ROMPlan.displayName(game.name) }
    private var system: GameSystem? { model.catalog.system(game.systemID) }
    private var key: String? { Keychain.password(for: AppModel.steamGridKeyAccount) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                Button { close() } label: { Label("Library", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                Card(title: "Details", symbol: "info.circle") {
                    LabeledContent("System", value: system?.name ?? game.systemID)
                    LabeledContent("Size", value: game.size.bytes)
                    MonoText(text: game.path)
                    Button("Add to Steam") { add() }.disabled(deck.steamUsers.isEmpty)
                }
                artwork
            }
            .padding(20)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .task {
            model.covers.load(title, kind: .hero)
            guard let key else { return }
            results = (try? await SteamGridDB(key: key).search(title)) ?? []
            await load()
        }
        .onChange(of: kind) { Task { await load() } }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = model.covers.image(title, kind: .hero) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.15)], startPoint: .leading, endPoint: .trailing)
                }
            }
            .frame(height: 230)
            .frame(maxWidth: .infinity)
            .clipped()
            HStack(alignment: .bottom, spacing: 14) {
                CoverView(title: title, symbol: system?.symbol ?? "gamecontroller")
                    .matchedGeometryEffect(id: game.id, in: namespace)
                    .frame(width: 130)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                Text(verbatim: title).font(.largeTitle.bold()).foregroundStyle(.white).shadow(radius: 4).padding(.bottom, 10)
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var artwork: some View {
        Card(title: "Artwork", symbol: "photo.on.rectangle") {
            if key == nil {
                InlineNote(text: "Add your SteamGridDB API key in Settings to choose artwork.", symbol: "key")
            } else {
                Picker("Type", selection: $kind) {
                    ForEach(ArtKind.allCases, id: \.self) { Text(verbatim: $0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104))]) {
                    ForEach(images[kind] ?? []) { image in
                        Button { Motion.run { picked[kind] = image } } label: {
                            AsyncImage(url: URL(string: image.thumb)) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                                .frame(height: 150)
                                .overlay { if picked[kind] == image { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3) } }
                        }
                        .buttonStyle(.plain)
                    }
                }
                InlineNote(text: "Applying artwork doesn't close anything. Steam shows it the next time the library reloads.")
                Button("Apply \(picked.count)") { apply() }.disabled(picked.isEmpty)
            }
            if let failure { Text(verbatim: failure).font(.callout).foregroundStyle(.orange) }
        }
    }

    private func load() async {
        guard let key, let first = results.first, images[kind] == nil else { return }
        do { images[kind] = try await SteamGridDB(key: key).images(kind, gameID: first.id) }
        catch { failure = model.describe(error) }
    }

    private func add() {
        guard let user = deck.steamUsers.first else { return }
        model.enqueue(String(localized: "Add to Steam"), .addToSteam(user: user, games: [GameRef(systemID: game.systemID, title: title)], sdMount: deck.sdMount.flatMap { game.path.hasPrefix($0 + "/") ? $0 : nil }))
    }

    private func apply() {
        guard let user = deck.steamUsers.first, let system,
              let appID = Library.shortcut(name: title, romPath: game.path, system: system, catalog: model.catalog, corePath: nil)?.appID else { return }
        for (kind, image) in picked {
            model.enqueue(String(localized: "Artwork: \(title)"), .applyArt(user: user, appID: appID, kind: kind, url: image.url))
        }
        picked = [:]
    }
}
