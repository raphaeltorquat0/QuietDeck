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
    @State private var targetSD = false
    @State private var addToSteam = false
    @State private var dropping = false
    @State private var choosing = false
    @State private var confirmSend = false
    @State private var selected: Library.Game?
    @State private var preview: URL?
    @FocusState private var gridFocused: Bool

    struct Candidate: Identifiable {
        var id: String { path }
        var path: String
        var size: Int64
        var systemID: String?
        var options: [String]
        var frame = CGRect.zero
        var name: String { (path as NSString).lastPathComponent }
        var title: String { ROMPlan.displayName(name) }
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
        .onChange(of: model.openGame) {
            if let game = model.openGame {
                Motion.run { selected = game }
                model.openGame = nil
            }
        }
        .quickLookPreview($preview)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data, .folder], allowsMultipleSelection: true) { result in
            scan((try? result.get()) ?? [])
        }
        .confirmationDialog("Add to Steam after sending?", isPresented: $confirmSend) {
            Button("Send and Add to Steam", role: .destructive) { send() }
        } message: { Text("Steam restarts to save the shortcuts, so any running game will close.") }
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
        let ids = Array(Set(deck.games.map(\.systemID))).sorted()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(Text("All"), nil)
                ForEach(ids, id: \.self) { chip(Text(verbatim: model.catalog.system($0)?.name ?? $0), $0) }
            }
        }
    }

    private func chip(_ label: Text, _ id: String?) -> some View {
        Button { Motion.run { filter = id } } label: {
            label.font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(filter == id ? Color.white : .primary)
                .background(filter == id ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == id ? .isSelected : [])
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
            Button("Send \(candidates.filter { $0.systemID != nil }.count) Games") {
                if addToSteam { confirmSend = true } else { send() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
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
                            let title = if case let .importROM(path, _, _) = job.action { ROMPlan.displayName((path as NSString).lastPathComponent) } else { job.title }
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
                let added: [Candidate] = found.filter { !known.contains($0.path) }.map { c in
                    switch c.detection {
                    case let .system(id): Candidate(path: c.path, size: c.size, systemID: id, options: catalog.systems.map(\.id))
                    case let .ambiguous(ids): Candidate(path: c.path, size: c.size, systemID: nil, options: ids)
                    case .unknown: Candidate(path: c.path, size: c.size, systemID: nil, options: catalog.systems.map(\.id))
                    }
                }
                Motion.run { candidates += added }
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
            model.enqueue(String(localized: "Send \(name)"), .importROM(localPath: item.path, systemID: id, sdMount: sd))
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
    @State private var confirmAdd = false
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
                    Button("Add to Steam…") { confirmAdd = true }.disabled(deck.steamUsers.isEmpty)
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
        .confirmationDialog("Add \(title) to Steam?", isPresented: $confirmAdd) {
            Button("Add to Steam", role: .destructive) { add() }
        } message: { Text("Steam restarts to save the shortcuts, so any running game will close. A backup of shortcuts.vdf is kept.") }
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
        model.enqueue(String(localized: "Add to Steam"), .addToSteam(user: user, games: [GameRef(systemID: game.systemID, title: title)], sdMount: nil))
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
