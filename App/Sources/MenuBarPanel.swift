import DeckRemote
import SwiftUI

/// Painel da barra de menus: só leitura. Nada aqui altera o Deck.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let deck = model.current {
                HStack {
                    Image(systemName: "gamecontroller").font(.title2).accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(deck.profile.name).font(.headline)
                        Text(state(deck)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let battery = deck.status.batteryPercent {
                    HStack {
                        Label("\(battery)%", systemImage: batterySymbol(battery, deck.status.batteryState))
                        ProgressView(value: Double(battery), total: 100)
                    }
                }
                Label(deck.updateCount == 1 ? "1 update available" : "\(deck.updateCount) updates available", systemImage: "arrow.down.circle")
            } else {
                Text("No Deck yet").foregroundStyle(.secondary)
            }
            Divider()
            Button("Open QuietDeck") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .keyboardShortcut("o")
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func state(_ deck: LiveDeck) -> String {
        switch deck.connection {
        case .connecting: "Connecting…"
        case .failed: "Offline"
        case .online: deck.status.mode == .desktop ? "Desktop Mode" : deck.status.mode == .game ? "Game Mode" : "Connected"
        }
    }
}
