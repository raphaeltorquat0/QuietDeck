import DeckRemote
import Foundation
import Observation
import SwiftUI

/// Pareamento devkit: cada volta pergunta ao Deck em que pé está e o wizard acompanha sozinho.
@MainActor @Observable
final class PairingFlow {
    enum Step: Equatable {
        case searching, developerMode, pairNewHost, approve, finishing, done
        case failed(String)

        var index: Int {
            switch self {
            case .searching, .developerMode: 0
            case .pairNewHost: 1
            case .approve: 2
            case .finishing, .done: 3
            case .failed: 2
            }
        }
    }

    var step = Step.searching
    var host = "steamdeck.local"
    private var run: Task<Void, Never>?

    func start(discovery: Discovery, onPaired: @escaping (DeckProfile) -> Void) {
        run?.cancel()
        step = .searching
        run = Task { await loop(discovery, onPaired) }
    }

    func stop() { run?.cancel() }

    private func loop(_ discovery: Discovery, _ onPaired: (DeckProfile) -> Void) async {
        var misses = 0, timeouts = 0
        do { try await DevkitPairing.ensureKey(at: Paths.devkitKey) }
        catch { step = .failed(String(describing: error)); return }
        while !Task.isCancelled {
            if let found = discovery.devkit.first { host = found.host }
            guard await DevkitPairing.isAvailable(host: host) else {
                misses += 1
                if misses > 3 { step = .developerMode }
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            misses = 0
            // `/register` só responde depois da decisão: sem resposta rápida, o pedido está na tela do Deck.
            let waiting = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { self?.step = .approve }
            }
            let outcome = (try? await DevkitPairing.register(host: host, keyPath: Paths.devkitKey, comment: Host.current().localizedName ?? "QuietDeck")) ?? .unreachable
            waiting.cancel()
            switch outcome {
            case .approved:
                step = .finishing
                await finish(onPaired)
                return
            case .unreachable: break
            case let .refused(message) where DevkitPairing.needsPairingMode(message): step = .pairNewHost
            case let .refused(message) where DevkitPairing.steamIsClosed(message): step = .pairNewHost
            case let .refused(message) where message.contains("timeout"):
                timeouts += 1
                if timeouts > 3 { step = .failed(message); return }
            case let .refused(message):
                step = .failed(message)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func finish(_ onPaired: (DeckProfile) -> Void) async {
        let login = await DevkitPairing.loginName(host: host) ?? "deck"
        var deck = DeckProfile(name: host.replacingOccurrences(of: ".local", with: ""), host: host, user: login)
        deck.identityFile = Paths.devkitKey
        guard await DevkitPairing.waitForSSH(config: AppModel.config(deck)) else {
            step = .failed(String(localized: "The Deck approved the pairing, but SSH didn't start."))
            return
        }
        step = .done
        onPaired(deck)
    }
}

/// Wizard do primeiro uso. Nenhum passo pede teclado no Deck.
struct PairingWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow = PairingFlow()
    @State private var discovery = Discovery()
    @State private var manual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if manual {
                ManualPairing(host: flow.host, back: { manual = false }, done: { dismiss() })
            } else {
                progress
                DeckIllustration(highlightSteam: flow.step == .pairNewHost || flow.step == .developerMode) {
                    SteamScreen(step: flow.step)
                }
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                instructions.animation(Motion.animation, value: flow.step)
                Spacer(minLength: 0)
                InlineNote(text: "Developer Mode exposes Steam's debug port on your local network. Turn it off in Settings if you don't trust this network.",
                           symbol: "exclamationmark.shield")
                footer
            }
        }
        .padding(24)
        .frame(width: 580, height: 560)
        .onAppear { start() }
        .onDisappear {
            flow.stop()
            discovery.stop()
        }
        .interactiveDismissDisabled(model.decks.isEmpty)
    }

    private func start() {
        discovery.start()
        flow.start(discovery: discovery) { deck in
            model.add(deck)
            Task {
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(i <= flow.step.index ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(flow.step.index + 1) of 4"))
    }

    @ViewBuilder private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch flow.step {
            case .searching:
                Text("Looking for your Deck").font(.title2.bold())
                Text("Turn it on and connect it to the same network as this Mac.").foregroundStyle(.secondary)
            case .developerMode:
                Text("Turn on Developer Mode").font(.title2.bold())
                Text("On the Deck, press the STEAM button and go to Settings › System, then turn on **Enable Developer Mode**.").foregroundStyle(.secondary)
            case .pairNewHost:
                Text("Open pairing on the Deck").font(.title2.bold())
                Text("Go to Settings › Developer › **Pair new host**. This screen moves on by itself.").foregroundStyle(.secondary)
            case .approve:
                Text("Approve on the Deck").font(.title2.bold())
                Text("A pairing request from this Mac is on the Deck's screen. Choose **Approve**.").foregroundStyle(.secondary)
            case .finishing:
                Text("Connecting").font(.title2.bold())
                Text("The Deck approved this Mac and is turning on SSH.").foregroundStyle(.secondary)
            case .done:
                Label("Paired", systemImage: "checkmark.circle.fill").font(.title2.bold()).foregroundStyle(.green)
            case let .failed(message):
                Text("Pairing didn't finish").font(.title2.bold())
                Text(verbatim: message).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if !model.decks.isEmpty { Button("Cancel") { dismiss() } }
            Button("Pair Manually…") { manual = true }.buttonStyle(.link)
            Spacer()
            TextField("Host", text: Bindable(flow).host).textFieldStyle(.roundedBorder).frame(width: 160)
                .accessibilityLabel("Deck host name or IP address")
            if case .failed = flow.step {
                Button("Try Again") { start() }.keyboardShortcut(.defaultAction)
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Waiting for the Deck")
            }
        }
    }
}

/// Telas do Steam dentro da ilustração, com a linha do passo atual em destaque.
struct SteamScreen: View {
    var step: PairingFlow.Step
    @State private var glow = false

    private var rows: [(LocalizedStringKey, Bool)] {
        switch step {
        case .developerMode: [("System", false), ("Enable Developer Mode", true), ("Display", false)]
        case .pairNewHost: [("Developer", false), ("Pair new host", true), ("Audio", false)]
        default: []
        }
    }

    var body: some View {
        ZStack {
            Color(white: 0.09)
            switch step {
            case .approve:
                VStack(spacing: 8) {
                    Text("Pair this host?").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    Text("Approve")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .background(Color.accentColor, in: Capsule())
                        .scaleEffect(glow ? 1.08 : 1)
                }
            case .finishing, .done:
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            case .searching:
                Image(systemName: "wifi").font(.largeTitle).foregroundStyle(.white.opacity(0.7)).opacity(glow ? 1 : 0.4)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            default:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Text(row.0)
                            .font(.caption2).foregroundStyle(.white.opacity(row.1 ? 1 : 0.5))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(row.1 ? Color.accentColor.opacity(glow ? 0.9 : 0.55) : .clear, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(10)
            }
        }
        .onAppear {
            guard !Motion.reduced else { glow = true; return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { glow = true }
        }
    }
}

/// Plano B, só quando o pareamento não funcionar: Desktop Mode, senha e sshd.
struct ManualPairing: View {
    @Environment(AppModel.self) private var model
    var host: String
    var back: () -> Void
    var done: () -> Void
    @State private var password = ""
    @State private var testing = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair manually").font(.title2.bold())
            Text("Hold the Power button, choose **Switch to Desktop** and open **Konsole**. Then run:").foregroundStyle(.secondary)
            CopyableCommand(command: "passwd")
            CopyableCommand(command: "sudo systemctl enable --now sshd")
            Text("Then enter the same password here. It stays in your Keychain.").foregroundStyle(.secondary)
            SecureField("Password of the deck user", text: $password).textFieldStyle(.roundedBorder)
            if let failure { Text(verbatim: failure).font(.callout).foregroundStyle(.orange).lineLimit(3) }
            Spacer(minLength: 0)
            HStack {
                Button("Back", action: back)
                Spacer()
                Button(testing ? "Testing…" : "Connect") { Task { await pair() } }
                    .keyboardShortcut(.defaultAction).disabled(testing)
            }
        }
    }

    private func pair() async {
        testing = true
        failure = nil
        defer { testing = false }
        var deck = DeckProfile(name: host.replacingOccurrences(of: ".local", with: ""), host: host)
        if let existing = model.decks.first(where: { $0.host == host }) { deck = existing }
        do {
            try await Pairing.ensureKey(at: Paths.key)
            // Se a chave já estiver no Deck, a senha só serve para o sudo e pode ficar para depois.
            let config = AppModel.config(deck)
            if (try? await SSHRunner(config: config).run("true").ok) != true {
                try await Pairing.installKey(config: config, password: password)
            }
            if !password.isEmpty { Keychain.set(password, for: deck.id.uuidString) }
            model.add(deck)
            done()
        } catch {
            failure = model.describe(error)
        }
    }
}

/// Pedida só quando uma operação precisa de sudo. Sem senha no Deck, oferece definir daqui.
struct PasswordPanel: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var status: SudoPassword.Status?
    @State private var password = ""
    @State private var repeated = ""
    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status == SudoPassword.Status.none {
                InlineNote(text: "The deck user has no password yet, and installing needs one. Set it from here.", symbol: "key")
                SecureField("New password", text: $password).textFieldStyle(.roundedBorder)
                SecureField("Repeat the password", text: $repeated).textFieldStyle(.roundedBorder)
                Button(busy ? "Setting…" : "Set Password") { Task { await define() } }
                    .disabled(busy || password.isEmpty || password != repeated)
            } else {
                InlineNote(text: "Enter the password of the deck user. It stays in your Keychain.", symbol: "key")
                SecureField("Password of the deck user", text: $password).textFieldStyle(.roundedBorder)
                Button("Save") { save() }.disabled(password.isEmpty)
            }
            if let failure { Text(verbatim: failure).font(.callout).foregroundStyle(.orange) }
        }
        .task { status = try? await SudoPassword.status(deck.runner) }
    }

    private func save() {
        Keychain.set(password, for: deck.id.uuidString)
        deck.hasPassword = true
    }

    private func define() async {
        busy = true
        defer { busy = false }
        do {
            try await SudoPassword.set(password, config: deck.config)
            save()
        } catch {
            failure = model.describe(error)
        }
    }
}
