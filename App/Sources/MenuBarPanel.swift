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
                        Text(verbatim: deck.profile.name).font(.headline)
                        state(deck).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let battery = deck.status.batteryPercent {
                    HStack {
                        Label { Text(verbatim: "\(battery)%").monospacedDigit() } icon: { Image(systemName: batterySymbol(battery, deck.status.batteryState)) }
                        ProgressView(value: Double(battery), total: 100)
                    }
                }
                Label("\(deck.updateCount) updates", systemImage: "arrow.down.circle")
            } else {
                Text("No Deck").foregroundStyle(.secondary)
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

    private func state(_ deck: LiveDeck) -> Text {
        switch deck.connection {
        case .connecting: Text("Connecting…")
        case .failed: Text("Offline")
        case .online: Text(deck.status.mode.label)
        }
    }
}
