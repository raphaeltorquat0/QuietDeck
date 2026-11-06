import DeckKit
import DeckRemote
import SwiftUI
import UniformTypeIdentifiers

struct EmulatorsView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var overwrite: Emulator?
    @State private var choosingBIOS = false
    /// Versão mais nova de cada AppImage, lida do GitHub ao abrir a tela.
    @State private var latest: [String: (tag: String, asset: GitHubAsset)] = [:]
    @State private var releaseFailure: String?

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
        .task {
            for e in model.catalog.emulators where latest[e.id] == nil {
                guard let source = e.appImage else { continue }
                do {
                    if let found = AppImages.latest(try await AppImages.releases(source), source: source) { latest[e.id] = found }
                    else { releaseFailure = String(localized: "No verifiable \(e.name) release was found.") }
                } catch { releaseFailure = model.describe(error) }
            }
        }
        .fileImporter(isPresented: $choosingBIOS, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            model.importBIOS(((try? result.get()) ?? []).map(\.path))
        }
    }

    @ViewBuilder private func row(_ e: Emulator) -> some View {
        if e.appImage != nil { appImageRow(e) } else { flatpakRow(e) }
    }

    /// AppImage do GitHub: versão ativa, a anterior para voltar e os dados em pasta própria.
    private func appImageRow(_ e: Emulator) -> some View {
        let status = deck.appImages[e.id] ?? .init()
        let newest = latest[e.id]
        let tagPrefix = e.appImage?.tagPrefix ?? ""
        func number(_ tag: String?) -> Int { tag.flatMap { Int($0.dropFirst(tagPrefix.count)) } ?? 0 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.name)
                    if let current = status.current {
                        let previous = status.previous.map { String(localized: "previous \($0)") }
                        Text(verbatim: previous.map { "\(current) · \($0)" } ?? current)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let note = e.note { Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if !status.isInstalled {
                    if let newest {
                        Button("Install \(newest.tag)") { model.enqueue(String(localized: "Install \(e.name)"), .installAppImage(emulatorID: e.id, tag: newest.tag, asset: newest.asset)) }
                    } else if releaseFailure == nil { ProgressView().controlSize(.small) }
                } else {
                    if let newest, number(newest.tag) > number(status.current) {
                        Button("Update to \(newest.tag)") { model.enqueue(String(localized: "Update \(e.name)"), .installAppImage(emulatorID: e.id, tag: newest.tag, asset: newest.asset)) }
                    }
                    if let previous = status.previous {
                        Button("Use \(previous)") { model.enqueue(String(localized: "Roll back \(e.name)"), .rollbackAppImage(emulatorID: e.id)) }
                    }
                    ConfirmButton(title: "Remove", confirm: "Confirm") {
                        model.enqueue(String(localized: "Remove \(e.name)"), .removeAppImage(emulatorID: e.id, keepData: true))
                    }
                }
            }
            if status.isInstalled {
                HStack {
                    InlineNote(text: "Its settings, saves and keys live in its own folder, apart from Eden. Remove keeps them; Remove with Data deletes them.", symbol: "externaldrive")
                    ConfirmButton(title: "Remove with Data", confirm: "Delete Saves Too") {
                        model.enqueue(String(localized: "Remove \(e.name) and its data"), .removeAppImage(emulatorID: e.id, keepData: false))
                    }
                }
            }
            if let releaseFailure { Text(verbatim: releaseFailure).font(.callout).foregroundStyle(.orange) }
        }
    }

    private func flatpakRow(_ e: Emulator) -> some View {
        let flatpak = e.flatpak ?? ""
        let installed = deck.flatpaks.first { $0.appID == flatpak }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.name)
                    if let note = e.note { Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary) }
                    else if let installed {
                        Text(verbatim: "\(installed.version) · \(installed.installation)").font(.caption).foregroundStyle(.secondary)
                    } else { Text(verbatim: flatpak).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                Spacer()
                if !e.isAvailable {
                    Text("Unavailable").foregroundStyle(.secondary)
                } else if installed == nil {
                    Button("Install") { model.enqueue(String(localized: "Install \(e.name)"), .installEmulator(appID: flatpak)) }
                } else {
                    if deck.updates[flatpak] != nil {
                        Button("Update") { model.enqueue(String(localized: "Update \(e.name)"), .updateEmulator(appID: flatpak)) }
                    }
                    if e.config != nil { Button("Set Paths") { setPaths(e) } }
                    ConfirmButton(title: "Remove", confirm: "Confirm") {
                        model.enqueue(String(localized: "Remove \(e.name)"), .removeEmulator(appID: flatpak))
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
