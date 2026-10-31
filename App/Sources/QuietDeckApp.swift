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
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom, spacing: 0) { QueueFooter() }
            .toolbar {
                if model.decks.count > 1 {
                    ToolbarItem {
                        Picker("Deck", selection: $model.selectedDeckID) {
                            ForEach(model.decks) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
            }
        } detail: {
            detail(model.section ?? .overview)
                .safeAreaInset(edge: .top, spacing: 0) { DeckStatusBar() }
                .navigationTitle((model.section ?? .overview).title)
        }
        .sheet(isPresented: $model.showOnboarding) { OnboardingView() }
    }

    @ViewBuilder private func detail(_ section: AppSection) -> some View {
        if let deck = model.current {
            switch section {
            case .overview: OverviewView(deck: deck)
            case .emulators: EmulatorsView(deck: deck)
            case .library: LibraryView(deck: deck)
            case .decky: DeckyView(deck: deck)
            case .compatTools: CompatToolsView(deck: deck)
            case .saves: SavesView(deck: deck)
            }
        } else {
            ContentUnavailableView {
                Label("No Deck yet", systemImage: "gamecontroller")
            } actions: {
                Button("Add Deck…") { model.showOnboarding = true }
            }
        }
    }
}
