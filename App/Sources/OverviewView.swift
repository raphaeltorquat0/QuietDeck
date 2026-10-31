import DeckKit
import DeckRemote
import SwiftUI

/// Ilustração do Deck ao centro, com bateria, armazenamento e temperatura em volta, ao vivo.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var pending: QuickAction?

    private var battery: Double { Double(deck.status.batteryPercent ?? 0) / 100 }

    var body: some View {
        Page {
            if let failure = deck.connection.detail {
                InlineNote(text: "\(failure)", symbol: "exclamationmark.triangle", tint: .orange)
            }
            Deck3DView(screenID: "\(deck.status.model ?? "")\(deck.status.osVersion ?? "")\(deck.status.mode.rawValue)") {
                ZStack {
                    LinearGradient(colors: [Color.accentColor.opacity(0.55), .black], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 8) {
                        Text(verbatim: deck.status.model ?? "Steam Deck").font(.system(size: 42, weight: .semibold)).foregroundStyle(.white)
                        Text("SteamOS \(deck.status.osVersion ?? "–")").font(.system(size: 28)).foregroundStyle(.white.opacity(0.85))
                        Text(deck.status.mode.label).font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(height: 248)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 16) {
                Gauge(title: "Battery", symbol: batterySymbol(deck.status.batteryPercent ?? 0, deck.status.batteryState), fraction: battery,
                      value: deck.status.batteryPercent.map { "\($0)%" } ?? "–", detail: deck.status.batteryState.map { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) } ?? "")
                storage(deck.status.internalStorage, title: "Internal", symbol: "internaldrive")
                storage(deck.status.sdCard, title: "microSD", symbol: "sdcard")
                temperature
            }
            .animation(Motion.animation, value: deck.status)

            Card(title: "Quick Actions", symbol: "bolt") {
                HStack {
                    ForEach(QuickAction.allCases, id: \.self) { action in
                        Button(action.localized) { pending = action }
                    }
                }
                InlineNote(text: "These actions close the running game, so each one asks first.")
            }
        }
        .confirmationDialog(Text(pending?.localized ?? ""), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
            Button(action.localized, role: .destructive) { model.enqueue(String(localized: action.localized), .quickAction(action)) }
        } message: { _ in
            Text("Any game running on the Deck will close and unsaved progress will be lost.")
        }
    }

    private func storage(_ v: Volume?, title: LocalizedStringKey, symbol: String) -> some View {
        Gauge(title: title, symbol: symbol, fraction: v.map { Double($0.total - $0.free) / Double(max($0.total, 1)) } ?? 0,
              value: v.map { $0.free.bytes } ?? "–", detail: v.map { "\($0.total.bytes)" } ?? String(localized: "Not inserted"))
    }

    private var temperature: some View {
        let t = deck.status.temperatures
        let cpu = t["CPU"] ?? 0
        return Gauge(title: "Temperature", symbol: "thermometer.medium", fraction: min(cpu / 100, 1),
                     value: t["CPU"].map { String(format: "%.0f °C", $0) } ?? "–",
                     detail: t["GPU"].map { String(format: "GPU %.0f °C", $0) } ?? "")
    }
}

extension QuickAction {
    var localized: LocalizedStringResource {
        switch self {
        case .restartSteam: "Restart Steam"
        case .switchToGameMode: "Switch to Game Mode"
        case .reboot: "Reboot"
        case .powerOff: "Shut Down"
        }
    }
}

/// Indicador circular com animação suave a cada leitura.
struct Gauge: View {
    var title: LocalizedStringKey
    var symbol: String
    var fraction: Double
    var value: String
    var detail: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 7)
                Circle().trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
            }
            .frame(width: 68, height: 68)
            Text(verbatim: value).font(.headline).monospacedDigit().contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.callout)
            Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassPanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: "\(value), \(detail)"))
    }
}
