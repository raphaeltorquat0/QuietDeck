import DeckRemote
import SwiftUI

/// Três passos, só no primeiro uso (ou em Arquivo › Add Deck).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 1
    @State private var discovery = Discovery()
    @State private var host = "steamdeck.local"
    @State private var password = ""
    @State private var testing = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step) of 3").font(.caption).foregroundStyle(.secondary)
            switch step {
            case 1: find
            case 2: prepare
            default: connect
            }
            Spacer(minLength: 0)
            HStack {
                if model.settings.onboarded || !model.decks.isEmpty { Button("Cancel") { dismiss() } }
                Spacer()
                if step > 1 { Button("Back") { step -= 1 } }
                if step < 3 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction).disabled(host.isEmpty)
                } else {
                    Button(testing ? "Testing…" : "Connect") { Task { await pair() } }
                        .keyboardShortcut(.defaultAction).disabled(testing)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .interactiveDismissDisabled(model.decks.isEmpty)
    }

    private var find: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find your Deck").font(.title2.bold())
            Text("Turn the Deck on and connect it to the same network as this Mac, over Wi-Fi or a dock cable.")
                .foregroundStyle(.secondary)
            if discovery.found.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Looking on the network…").foregroundStyle(.secondary) }
            } else {
                List(discovery.found, selection: Binding(get: { host }, set: { host = $0 ?? host })) { item in
                    Label(item.name, systemImage: item.looksLikeDeck ? "gamecontroller" : "desktopcomputer").tag(item.host)
                }
                .frame(height: 130)
            }
            TextField("Host name or IP address", text: $host).textFieldStyle(.roundedBorder)
            InlineNote(text: "If the Deck isn't listed, type its IP address. You'll find it in Settings › Internet on the Deck.")
        }
    }

    private var prepare: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Do this once on the Deck").font(.title2.bold())
            Text("Hold the Power button, choose **Switch to Desktop**, and open **Konsole** from the app menu. Then run:")
                .foregroundStyle(.secondary)
            Text("Set a password for the deck user, if you don't have one:").font(.callout)
            CopyableCommand(command: "passwd")
            Text("Turn on SSH:").font(.callout)
            CopyableCommand(command: "sudo systemctl enable --now sshd")
            InlineNote(text: "You won't need Desktop Mode again. Go back to Game Mode whenever you like.")
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test the connection").font(.title2.bold())
            Text("QuietDeck logs in once with this password, installs its own key (~/.ssh/quietdeck_ed25519) and uses only the key from then on. The password stays in your Keychain for actions that need sudo.")
                .foregroundStyle(.secondary)
            LabeledContent("Deck", value: host)
            SecureField("Password of the deck user", text: $password).textFieldStyle(.roundedBorder)
            if let failure { InlineNote(text: failure, symbol: "exclamationmark.triangle", tint: .orange) }
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
            dismiss()
        } catch {
            failure = String(describing: error)
        }
    }
}
