import DeckKit
import DeckRemote
import SwiftUI

@main
struct QuietDeckApp: App {
    @State private var model: AppModel

    init() {
        // Os JSON vão dentro do app; faltar um deles é build quebrado, não situação de uso.
        let catalog = try! Catalog.load(overrideDirectory: Paths.support)
        #if DEBUG
        if let dir = Launch.value(after: "--press-kit"), let fixture = Launch.value(after: "--fixture") {
            let runner = try? ReplayRunner(json: URL(fileURLWithPath: fixture))
            let store = URL(fileURLWithPath: dir).appending(path: "queue.json")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let demo = AppModel(demo: runner ?? ReplayRunner([:]), catalog: catalog, queueStore: store)
            PressKit.seedQueue(deckID: demo.selectedDeckID!, to: store)
            _model = State(initialValue: demo)
            Task { @MainActor in await PressKit.run(demo, to: URL(fileURLWithPath: dir)) }
            return
        }
        #endif
        let app = AppModel(catalog: catalog)
        _model = State(initialValue: app)
        app.start()
    }

    var body: some Scene {
        Window("QuietDeck", id: "main") {
            RootView().environment(model)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Command Palette") { Motion.run { model.showPalette.toggle() } }.keyboardShortcut("k")
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Add Deck…") { model.showOnboarding = true }.keyboardShortcut("n")
                Button("Refresh") { Task { await model.current?.refresh() } }.keyboardShortcut("r")
            }
        }

        MenuBarExtra("QuietDeck", systemImage: "gamecontroller", isInserted: Binding(
            get: { model.settings.showMenuBarExtra }, set: { model.settings.showMenuBarExtra = $0 })) {
            MenuBarPanel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.section) { section in
                Label { Text(section.title) } icon: { Image(systemName: section.symbol) }.tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom, spacing: 0) { QueueFooter() }
            .toolbar {
                if model.decks.count > 1 {
                    ToolbarItem {
                        Picker("Deck", selection: $model.selectedDeckID) {
                            ForEach(model.decks) { Text(verbatim: $0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
            }
        } detail: {
            detail(model.section ?? .overview)
                .safeAreaInset(edge: .top, spacing: 0) { DeckStatusBar() }
                .navigationTitle(Text((model.section ?? .overview).title))
        }
        .coordinateSpace(name: "root")
        .overlayPreferenceValue(QueueAnchor.self) { anchor in
            GeometryReader { geo in
                let target = anchor.map { geo[$0] } ?? CGRect(x: 40, y: geo.size.height - 40, width: 40, height: 40)
                ForEach(model.flights) { FlyingCover(flight: $0, target: target) }
            }
        }
        .overlay(alignment: .bottomTrailing) { ToastView() }
        .overlay {
            if model.showPalette {
                CommandPalette().transition(.opacity)
            }
        }
        .animation(Motion.animation, value: model.showPalette)
        .sheet(isPresented: $model.showOnboarding) { PairingWizard() }
    }

    @ViewBuilder private func detail(_ section: AppSection) -> some View {
        if let deck = model.current {
            switch section {
            case .overview: OverviewView(deck: deck)
            case .emulators: EmulatorsView(deck: deck)
            case .library: LibraryView(deck: deck)
            case .shelf: ShelfView(deck: deck)
            case .decky: DeckyView(deck: deck)
            case .compatTools: CompatToolsView(deck: deck)
            case .saves: SavesView(deck: deck)
            }
        } else {
            EmptyState(title: "No Deck yet", message: "Pair your Steam Deck with this Mac to get started.", action: "Add Deck…") {
                model.showOnboarding = true
            }
        }
    }
}
