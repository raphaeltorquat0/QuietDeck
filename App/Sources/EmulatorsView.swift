import DeckKit
import DeckRemote
import SwiftUI
import UniformTypeIdentifiers

struct EmulatorsView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var pendingRemove: Emulator?
    @State private var pendingOverwrite: Emulator?
    @State private var choosingBIOS = false

    var body: some View {
        Page {
            HStack {
                Button("Create Emulation Folders") { model.enqueue("Create Emulation folders", .prepareEmulation(sdMount: nil)) }
                if let p = deck.paths {
                    Text(p.root).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
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
                    LabeledContent(model.catalog.system(id)?.name ?? id) {
                        Label(status.label, systemImage: status.symbol).foregroundStyle(status.tint)
                    }
                }
                Button("Import BIOS File…") { choosingBIOS = true }
                InlineNote(text: "QuietDeck never downloads BIOS files. A file you import is checked against a table of known hashes before it's copied.")
            }
        }
        .fileImporter(isPresented: $choosingBIOS, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] {
                _ = url.startAccessingSecurityScopedResource()
                model.enqueue("Import \(url.lastPathComponent)", .importBIOS(localPath: url.path, sdMount: nil))
            }
        }
        .confirmationDialog("Remove \(pendingRemove?.name ?? "")?", isPresented: flag($pendingRemove), presenting: pendingRemove) { e in
            Button("Remove", role: .destructive) { model.enqueue("Remove \(e.name)", .removeEmulator(appID: e.flatpak)) }
        } message: { _ in Text("Games and files in Emulation stay on the Deck.") }
        .confirmationDialog("Replace paths in \(pendingOverwrite?.name ?? "")?", isPresented: flag($pendingOverwrite), presenting: pendingOverwrite) { e in
            Button("Update Paths") { model.enqueue("Set paths in \(e.name)", .configureEmulator(id: e.id, overwrite: true, sdMount: nil)) }
        } message: { _ in Text("A config file already exists. Only the ROM, BIOS and save paths change, and a backup is kept next to it.") }
    }

    private func flag<T>(_ b: Binding<T?>) -> Binding<Bool> {
        Binding(get: { b.wrappedValue != nil }, set: { if !$0 { b.wrappedValue = nil } })
    }

    private func row(_ e: Emulator) -> some View {
        let installed = deck.flatpaks.first { $0.appID == e.flatpak }
        let update = deck.updates[e.flatpak]
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name)
                if let note = e.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                else if let installed { Text("\(installed.version.isEmpty ? "Installed" : installed.version) · \(installed.installation)").font(.caption).foregroundStyle(.secondary) }
                else { Text(e.flatpak).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if !e.isAvailable {
                Text("Unavailable").foregroundStyle(.secondary)
            } else if installed == nil {
                Button("Install") { model.enqueue("Install \(e.name)", .installEmulator(appID: e.flatpak)) }
            } else {
                if update != nil { Button("Update") { model.enqueue("Update \(e.name)", .updateEmulator(appID: e.flatpak)) } }
                if e.config != nil { Button("Set Paths") { setPaths(e) } }
                Button("Remove") { pendingRemove = e }
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
                pendingOverwrite = e
            } else {
                model.enqueue("Set paths in \(e.name)", .configureEmulator(id: e.id, overwrite: false, sdMount: nil))
            }
        }
    }
}
