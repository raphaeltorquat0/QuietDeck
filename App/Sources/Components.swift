import AppKit
import DeckKit
import DeckRemote
import SwiftUI

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Aviso sem bloqueio, na própria tela.
struct InlineNote: View {
    var text: String
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
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CopyableCommand: View {
    var command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel("Copy command")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension BIOSStatus {
    var label: String {
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

/// Status fixo no topo da área de conteúdo.
struct DeckStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            if let deck = model.current {
                connection(deck)
                Divider().frame(height: 14)
                Label(mode(deck.status.mode), systemImage: "display")
                if let battery = deck.status.batteryPercent {
                    Label("\(battery)%", systemImage: batterySymbol(battery, deck.status.batteryState))
                }
                if let storage = deck.status.internalStorage { Label("\(storage.free.bytes) free", systemImage: "internaldrive") }
                if let sd = deck.status.sdCard { Label("\(sd.free.bytes) free", systemImage: "sdcard") }
                Spacer()
                Button {
                    Task { await deck.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh (⌘R)")
                    .accessibilityLabel("Refresh")
            } else {
                Text("No Deck").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func connection(_ deck: LiveDeck) -> some View {
        let (text, color): (String, Color) = switch deck.connection {
        case .online: ("Connected", .green)
        case .connecting: ("Connecting…", .yellow)
        case .failed: ("Offline", .red)
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text)
        }
        .help({ if case let .failed(m) = deck.connection { m } else { deck.profile.host } }())
    }

    private func mode(_ m: SessionMode) -> String {
        switch m {
        case .game: "Game Mode"
        case .desktop: "Desktop Mode"
        case .unknown: "Unknown mode"
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

/// Fila no rodapé da sidebar: progresso, cancelar e tentar de novo.
struct QueueFooter: View {
    @Environment(AppModel.self) private var model

    private var visible: [Job] { model.queue.jobs.suffix(4) }

    var body: some View {
        if !model.queue.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.queue.activeCount > 0 ? "Queue (\(model.queue.activeCount))" : "Queue")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.queue.clearFinished() }
                        .buttonStyle(.borderless).font(.caption)
                }
                ForEach(visible) { JobRow(job: $0) }
            }
            .padding(10)
            .background(.bar)
        }
    }
}

struct JobRow: View {
    @Environment(AppModel.self) private var model
    var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(job.title).font(.caption).lineLimit(1).truncationMode(.middle)
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
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .help(detail ?? job.title)
    }

    private var detail: String? {
        switch job.state {
        case let .failed(m): m
        case .interrupted: "Interrupted when the app closed"
        case .cancelled: "Cancelled"
        case .queued: "Waiting"
        default: job.detail
        }
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless).font(.caption).help(label).accessibilityLabel(label)
    }
}
