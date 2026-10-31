import DeckKit
import DeckRemote
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var pending: QuickAction?

    var body: some View {
        Page {
            if case let .failed(message) = deck.connection {
                InlineNote(text: message, symbol: "exclamationmark.triangle", tint: .orange)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 16) {
                Card(title: deck.status.model ?? "Steam Deck", symbol: "gamecontroller") {
                    row("SteamOS", deck.status.osVersion ?? "–")
                    row("Build", deck.status.buildID ?? "–")
                    row("Host", deck.profile.host)
                }
                Card(title: "Battery", symbol: batterySymbol(deck.status.batteryPercent ?? 0, deck.status.batteryState)) {
                    row("Charge", deck.status.batteryPercent.map { "\($0)%" } ?? "–")
                    row("State", deck.status.batteryState ?? "–")
                    if let p = deck.status.batteryPercent { ProgressView(value: Double(p), total: 100) }
                }
                Card(title: "Storage", symbol: "internaldrive") {
                    if let v = deck.status.internalStorage { volume(v) }
                    if let v = deck.status.sdCard { volume(v) } else { row("microSD", "Not inserted") }
                }
                Card(title: "Temperature", symbol: "thermometer.medium") {
                    if deck.status.temperatures.isEmpty { row("Sensors", "–") }
                    ForEach(deck.status.temperatures.keys.sorted(), id: \.self) { key in
                        row(key, String(format: "%.0f °C", deck.status.temperatures[key] ?? 0))
                    }
                }
            }
            Card(title: "Quick Actions", symbol: "bolt") {
                HStack {
                    ForEach(QuickAction.allCases, id: \.self) { action in
                        Button(action.title) { pending = action }
                    }
                }
                InlineNote(text: "These actions close the running game, so each one asks first.")
            }
        }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
            Button(action.title, role: .destructive) { model.enqueue(action.title, .quickAction(action)) }
        } message: { _ in
            Text("Any game running on the Deck will close and unsaved progress will be lost.")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value).font(.callout)
    }

    private func volume(_ v: Volume) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            row(v.name, "\(v.free.bytes) free of \(v.total.bytes)")
            ProgressView(value: Double(v.total - v.free), total: Double(max(v.total, 1)))
        }
    }
}
