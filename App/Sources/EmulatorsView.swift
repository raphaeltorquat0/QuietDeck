import DeckKit
import DeckRemote
import SwiftUI
import UniformTypeIdentifiers

struct EmulatorsView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var overwrite: Emulator?
    @State private var choosingBIOS = false

    var body: some View {
        Page {
            HStack {
                Button("Create Emulation Folders") { model.enqueue(String(localized: "Create Emulation folders"), .prepareEmulation(sdMount: nil)) }
                if let p = deck.paths { MonoText(text: p.root) }
            }
            if deck.paths?.isEmuDeck == true {
                InlineNote(text: "EmuDeck is installed. QuietDeck follows its folders and doesn't change emulator settings.", symbol: "checkmark.seal")
            }
            Card(title: "Emulators", symbol: "gamecontroller") {
                ForEach(model.catalog.emulators) { row($0) }
            }
            Card(title: "BIOS", symbol: "cpu") {
                ForEach(deck.bios.keys.sorted(), id: \.self) { id in
                    let status = deck.bios[id] ?? .missing
                    LabeledContent {
                        Label(status.label, systemImage: status.symbol).foregroundStyle(status.tint)
                    } label: { Text(verbatim: model.catalog.system(id)?.name ?? id) }
                }
                Button("Import BIOS File…") { choosingBIOS = true }
                InlineNote(text: "QuietDeck never downloads BIOS files. A file you import is checked against a table of known hashes before it's copied.")
            }
        }
        .fileImporter(isPresented: $choosingBIOS, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            model.importBIOS(((try? result.get()) ?? []).map(\.path))
        }
    }

    private func row(_ e: Emulator) -> some View {
        let installed = deck.flatpaks.first { $0.appID == e.flatpak }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.name)
                    if let note = e.note { Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary) }
                    else if let installed {
                        Text(verbatim: "\(installed.version) · \(installed.installation)").font(.caption).foregroundStyle(.secondary)
                    } else { Text(verbatim: e.flatpak).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                Spacer()
                if !e.isAvailable {
                    Text("Unavailable").foregroundStyle(.secondary)
                } else if installed == nil {
                    Button("Install") { model.enqueue(String(localized: "Install \(e.name)"), .installEmulator(appID: e.flatpak)) }
                } else {
                    if deck.updates[e.flatpak] != nil {
                        Button("Update") { model.enqueue(String(localized: "Update \(e.name)"), .updateEmulator(appID: e.flatpak)) }
                    }
                    if e.config != nil { Button("Set Paths") { setPaths(e) } }
                    ConfirmButton(title: "Remove", confirm: "Confirm") {
                        model.enqueue(String(localized: "Remove \(e.name)"), .removeEmulator(appID: e.flatpak))
                    }
                }
            }
            if overwrite == e {
                HStack {
                    InlineNote(text: "A config file already exists. Only the ROM, BIOS and save paths change, and a backup is kept next to it.")
                    Button("Update Paths") {
                        model.enqueue(String(localized: "Set paths in \(e.name)"), .configureEmulator(id: e.id, overwrite: true, sdMount: nil))
                        overwrite = nil
                    }
                }
            }
        }
    }

    private func setPaths(_ e: Emulator) {
        let runner = deck.runner
        Task {
            guard let config = e.config else { return }
            let files = RemoteFiles(runner: runner)
            let home = (try? await files.home()) ?? "/home/deck"
            if (try? await files.exists(home + "/" + config.path)) == true {
                Motion.run { overwrite = e }
            } else {
                model.enqueue(String(localized: "Set paths in \(e.name)"), .configureEmulator(id: e.id, overwrite: false, sdMount: nil))
            }
        }
    }
}
