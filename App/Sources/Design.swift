import AppKit
import DeckKit
import DeckRemote
import SwiftUI

/// Movimento único do app: spring curto e nada de animação com "Reduzir movimento" ligado.
enum Motion {
    static let spring = Animation.spring(response: 0.28, dampingFraction: 0.86)

    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @MainActor static var animation: Animation? { reduced ? nil : spring }
    @MainActor static func run(_ change: () -> Void) { withAnimation(animation, change) }
}

extension View {
    /// Liquid Glass no macOS 26+, material com vibrancy antes disso.
    @ViewBuilder func glassPanel(cornerRadius: CGFloat = 14, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Texto em SF Mono, para caminhos e comandos.
struct MonoText: View {
    var text: String
    var body: some View {
        Text(verbatim: text).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

/// Aviso sem bloqueio, na própria tela.
struct InlineNote: View {
    var text: LocalizedStringKey
    var symbol = "info.circle"
    var tint = Color.secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Card<Content: View>: View {
    var title: LocalizedStringKey
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassPanel()
    }
}

struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(20)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Estado vazio: ilustração própria e uma ação direta.
struct EmptyState: View {
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var action: LocalizedStringKey?
    var perform: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            DeckIllustration { Color.accentColor.opacity(0.25) }.frame(width: 190).opacity(0.75)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            if let action, let perform { Button(action, action: perform).buttonStyle(.borderedProminent) }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}

/// Ação destrutiva que não fecha jogo: confirma no próprio botão, sem modal.
struct ConfirmButton: View {
    var title: LocalizedStringKey
    var confirm: LocalizedStringKey
    var action: () -> Void
    @State private var armed = false

    var body: some View {
        Button(armed ? confirm : title) {
            if armed { action() }
            Motion.run { armed.toggle() }
        }
        .tint(armed ? .red : nil)
        .task(id: armed) {
            guard armed else { return }
            try? await Task.sleep(for: .seconds(3))
            Motion.run { armed = false }
        }
    }
}

struct CopyableCommand: View {
    var command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(verbatim: command).font(.body.monospaced()).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                Motion.run { copied = true }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension BIOSStatus {
    var label: LocalizedStringKey {
        switch self {
        case .ok: "OK"
        case .missing: "Missing"
        case .invalid: "Invalid hash"
        }
    }
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .missing: "circle.dashed"
        case .invalid: "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .ok: .green
        case .missing: .secondary
        case .invalid: .orange
        }
    }
}

func batterySymbol(_ percent: Int, _ state: String?) -> String {
    if state == "Charging" { return "battery.100percent.bolt" }
    return switch percent {
    case ..<13: "battery.0percent"
    case ..<38: "battery.25percent"
    case ..<63: "battery.50percent"
    case ..<88: "battery.75percent"
    default: "battery.100percent"
    }
}

extension SessionMode {
    var label: LocalizedStringKey {
        switch self {
        case .game: "Game Mode"
        case .desktop: "Desktop Mode"
        case .unknown: "Unknown mode"
        }
    }
}

/// Barra fixa no topo da área de conteúdo.
struct DeckStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            if let deck = model.current {
                connection(deck)
                Divider().frame(height: 14)
                Label(deck.status.mode.label, systemImage: "display")
                if let battery = deck.status.batteryPercent {
                    Label { Text(verbatim: "\(battery)%").monospacedDigit().contentTransition(.numericText()) } icon: {
                        Image(systemName: batterySymbol(battery, deck.status.batteryState))
                    }
                    .accessibilityLabel(Text("Battery \(battery) percent"))
                }
                if let storage = deck.status.internalStorage { Label("\(storage.free.bytes) free", systemImage: "internaldrive") }
                if let sd = deck.status.sdCard { Label("\(sd.free.bytes) free", systemImage: "sdcard") }
                Spacer()
                Button { model.showPalette = true } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Command palette (⌘K)").accessibilityLabel("Command palette")
                Button { Task { await deck.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh (⌘R)").accessibilityLabel("Refresh")
            } else {
                Text("No Deck").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(Motion.animation, value: model.current?.status)
    }

    private func connection(_ deck: LiveDeck) -> some View {
        let (text, color): (LocalizedStringKey, Color) = switch deck.connection {
        case .online: ("Connected", .green)
        case .connecting: ("Connecting…", .yellow)
        case .failed: ("Offline", .red)
        }
        return Label {
            Text(text)
        } icon: {
            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(color)
        }
        .help(deck.connection.detail ?? deck.profile.host)
    }
}

extension LiveDeck.Connection {
    var detail: String? { if case let .failed(m) = self { m } else { nil } }
}

/// Fila no rodapé da sidebar: progresso, cancelar e tentar de novo.
struct QueueFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.queue.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.queue.activeCount > 0 ? "Queue (\(model.queue.activeCount))" : "Queue")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.queue.clearFinished() }.buttonStyle(.borderless).font(.caption)
                }
                ForEach(model.queue.jobs.suffix(4)) { JobRow(job: $0) }
            }
            .padding(10)
            .background(.bar)
            .anchorPreference(key: QueueAnchor.self, value: .bounds) { $0 }
        }
    }
}

struct QueueAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

struct JobRow: View {
    @Environment(AppModel.self) private var model
    var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: job.title).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                if job.canRetry {
                    icon("arrow.clockwise", "Try again") { model.queue.retry(job.id) }
                } else if !job.isFinished {
                    icon("xmark.circle.fill", "Cancel") { model.queue.cancel(job.id) }
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption).accessibilityLabel("Done")
                }
            }
            if job.state == .running {
                if let percent = job.percent { ProgressView(value: Double(percent), total: 100).controlSize(.small) }
                else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
            }
            detail.font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .contain)
    }

    private var detail: Text {
        switch job.state {
        case let .failed(m): Text(verbatim: m)
        case .interrupted: Text("Interrupted when the app closed")
        case .cancelled: Text("Cancelled")
        case .queued: Text("Waiting")
        default: job.detail.map { Text(LocalizedStringKey($0)) } ?? Text(verbatim: "")
        }
    }

    private func icon(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless).font(.caption).help(label).accessibilityLabel(label)
    }
}

/// Toast discreto: o que aconteceu e o que fazer. Modal é só para o que fecha o jogo aberto.
struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: toast.title).font(.callout.weight(.semibold))
                    if let detail = toast.detail { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
                Button { Motion.run { model.toast = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption).accessibilityLabel("Dismiss")
            }
            .padding(12)
            .frame(maxWidth: 380, alignment: .leading)
            .glassPanel(cornerRadius: 12)
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(toast.isError ? 7 : 3))
                Motion.run { if model.toast?.id == toast.id { model.toast = nil } }
            }
        }
    }
}
