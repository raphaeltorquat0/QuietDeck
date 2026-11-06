import DeckKit
import DeckRemote
import SwiftUI

/// ⌘K: todas as ações, mais jogos, emuladores e plugins.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var index = 0
    @State private var confirming: QuickAction?
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var run: () -> Void
    }

    private var items: [Item] {
        var all: [Item] = AppSection.allCases.map { s in
            Item(id: "go-" + s.rawValue, title: String(localized: s.title), symbol: s.symbol) { model.section = s }
        }
        all += QuickAction.allCases.map { a in
            Item(id: "qa-" + a.rawValue, title: String(localized: a.localized), symbol: "bolt") { confirming = a }
        }
        all.append(Item(id: "add", title: String(localized: "Add Deck…"), symbol: "plus") { model.showOnboarding = true })
        if let deck = model.current {
            all.append(Item(id: "refresh", title: String(localized: "Refresh"), symbol: "arrow.clockwise") { Task { await deck.refresh() } })
            all += model.catalog.emulators.filter(\.isAvailable).map { e in
                let installed = e.flatpak.map { id in deck.flatpaks.contains { $0.appID == id } } ?? (deck.appImages[e.id]?.isInstalled == true)
                return Item(id: "emu-" + e.id, title: installed ? String(localized: "Open \(e.name) in Emulators") : String(localized: "Install \(e.name)"), symbol: "gamecontroller") {
                    // AppImage: a versão é escolhida na tela de emuladores, que lê as releases.
                    if let flatpak = e.flatpak, !installed {
                        model.enqueue(String(localized: "Install \(e.name)"), .installEmulator(appID: flatpak))
                    } else { model.section = .emulators }
                }
            }
            all += deck.games.map { g in
                Item(id: "game-" + g.id, title: ROMPlan.displayName(g.name), symbol: "opticaldisc") {
                    model.section = .library
                    model.openGame = g
                }
            }
            all += deck.plugins.map { p in
                Item(id: "plugin-" + p.name, title: p.name, symbol: "puzzlepiece.extension") { model.section = .decky }
            }
        }
        return all
    }

    private var filtered: [Item] {
        let list = query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return Array(list.prefix(9))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search actions, games, emulators and plugins", text: $query)
                        .textFieldStyle(.plain).font(.title3).focused($focused)
                        .onSubmit { activate() }
                }
                .padding(14)
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { i, item in
                        Button { index = i; activate() } label: {
                            Label { Text(verbatim: item.title) } icon: { Image(systemName: item.symbol) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(i == index ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if filtered.isEmpty { Text("No results").foregroundStyle(.secondary).padding(12) }
                }
                .padding(6)
            }
            .frame(width: 520)
            .glassPanel(cornerRadius: 16)
            .padding(.top, 70)
        }
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(filtered.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .confirmationDialog(Text(confirming?.localized ?? ""), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { action in
            Button(action.localized, role: .destructive) {
                model.enqueue(String(localized: action.localized), .quickAction(action))
                close()
            }
        } message: { _ in Text("Any game running on the Deck will close and unsaved progress will be lost.") }
    }

    private func activate() {
        guard filtered.indices.contains(index) else { return }
        let item = filtered[index]
        item.run()
        if !item.id.hasPrefix("qa-") { close() }
    }

    private func close() { Motion.run { model.showPalette = false } }
}
