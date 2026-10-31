import DeckKit
import DeckRemote
import SwiftUI

struct DeckyView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var store: [StorePlugin] = []
    @State private var query = ""
    @State private var failure: String?
    @State private var confirm: ThemeChange?

    private enum ThemeChange: Identifiable {
        case apply(String), restore(String)
        var id: String { switch self { case let .apply(u): "a" + u; case let .restore(u): "r" + u } }
    }

    private var filtered: [StorePlugin] {
        query.isEmpty ? store : store.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Page {
            Card(title: "Decky Loader", symbol: "puzzlepiece.extension") {
                if let d = deck.decky, d.installed {
                    LabeledContent("Version", value: d.version ?? "–")
                    LabeledContent { Text(d.serviceActive ? "Running" : "Stopped") } label: { Text("Service") }
                }
                if !deck.hasPassword { PasswordPanel(deck: deck) }
                InlineNote(text: "The official installer runs with sudo. Besides ~/homebrew, it adds a service in /etc/systemd/system, the one place QuietDeck writes outside /home/deck.")
                Button(deck.decky?.installed == true ? "Update Decky" : "Install Decky") {
                    model.enqueue(String(localized: "Install Decky"), .installDecky)
                }
                .disabled(!deck.hasPassword)
            }
            Card(title: "Quiet Home", symbol: "house") {
                InlineNote(text: "A quieter Game Mode home with one row of covers. To go back to the native home, remove the plugin below.")
                Button(deck.plugins.contains { $0.name == BundledPlugin.quietHome.name } ? "Update Quiet Home" : "Install Quiet Home") {
                    model.enqueue(String(localized: "Install Quiet Home"), .installQuietHome)
                }
                .disabled(!deck.hasPassword || deck.decky?.installed != true)
                if deck.themeInstalled {
                    Button("Restore Valve Defaults") {
                        if let user = deck.steamUsers.first { confirm = .restore(user) }
                    }
                }
            }
            Card(title: "Installed Plugins", symbol: "checkmark.circle") {
                if deck.plugins.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(deck.plugins) { plugin in
                    HStack {
                        Text(verbatim: plugin.name)
                        Text(verbatim: plugin.version ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let latest = store.first(where: { $0.name == plugin.name })?.versions.first, latest.name != plugin.version {
                            Button("Update to \(latest.name)") {
                                model.enqueue(String(localized: "Update \(plugin.name)"), .installPlugin(name: plugin.name, version: latest))
                            }
                            .disabled(!deck.hasPassword)
                        }
                        ConfirmButton(title: "Remove", confirm: "Confirm") {
                            model.enqueue(String(localized: "Remove \(plugin.name)"), .removePlugin(name: plugin.name))
                        }
                        .disabled(!deck.hasPassword)
                    }
                }
            }
            Card(title: "Quiet Glass", symbol: "circle.lefthalf.filled") {
                Text("Glass on the top and bottom bars, the home tabs, and the Steam and quick access menus. While a game runs, QuietTune switches the menus to opaque.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    // Aplicar de novo é como o Deck recebe a versão que veio neste app.
                    Button("Apply Quiet Glass") { model.enqueue(String(localized: "Apply Quiet Glass"), .applyQuietGlass) }
                        .buttonStyle(.glassProminent).disabled(deck.decky?.installed != true || !deck.hasPassword)
                    if deck.hasQuietGlass {
                        Button("Remove Quiet Glass") { model.enqueue(String(localized: "Remove Quiet Glass"), .removeQuietGlass) }
                            .disabled(!deck.hasPassword)
                    }
                }
            }
            Card(title: "Plugin Store", symbol: "bag") {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                if let failure { Text(verbatim: failure).font(.callout).foregroundStyle(.orange) }
                ForEach(filtered) { plugin in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: plugin.name)
                            Text(verbatim: "\(plugin.author) · \(plugin.description)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if !deck.plugins.contains(where: { $0.name == plugin.name }), let version = plugin.versions.first {
                            Button("Install") { model.enqueue(String(localized: "Install \(plugin.name)"), .installPlugin(name: plugin.name, version: version)) }
                                .disabled(deck.decky?.installed != true || !deck.hasPassword)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Restart Steam to change the theme?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { change in
            Button("Continue", role: .destructive) {
                switch change {
                case .apply: break
                case let .restore(user): model.enqueue(String(localized: "Restore Valve Defaults"), .restoreTheme(user: user))
                }
            }
        } message: { _ in Text("The Loja shortcut changes, so Steam restarts and any running game will close.") }
        .task {
            guard store.isEmpty else { return }
            do { store = try await Decky.store() } catch { failure = model.describe(error) }
        }
    }
}

struct CompatToolsView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var releases: [String: [GitHubRelease]] = [:]
    @State private var failure: String?

    var body: some View {
        Page {
            Card(title: "Installed", symbol: "wineglass") {
                if deck.compatTools.isEmpty {
                    EmptyState(title: "No compat tools yet", message: "Install GE-Proton below for games that need it.")
                }
                ForEach(deck.compatTools, id: \.self) { tool in
                    HStack {
                        Text(verbatim: tool)
                        Spacer()
                        ConfirmButton(title: "Remove", confirm: "Confirm") {
                            model.enqueue(String(localized: "Remove \(tool)"), .removeCompatTool(name: tool))
                        }
                    }
                }
                InlineNote(text: "New tools appear in Steam after it restarts.")
            }
            if let failure { Text(verbatim: failure).font(.callout).foregroundStyle(.orange) }
            ForEach(model.catalog.compatTools) { source in
                Card(title: "\(source.name)", symbol: "arrow.down.circle") {
                    let list = (releases[source.id] ?? []).filter { !$0.prerelease }.prefix(5)
                    if list.isEmpty { ProgressView().controlSize(.small) }
                    ForEach(Array(list)) { release in
                        HStack {
                            Text(verbatim: release.tag_name)
                            Spacer()
                            if let assets = CompatTools.assets(in: release, source: source) {
                                let folder = assets.archive.name.replacingOccurrences(of: source.assetSuffix, with: "")
                                if deck.compatTools.contains(folder) { Text("Installed").foregroundStyle(.secondary) }
                                else {
                                    Button("Install") {
                                        model.enqueue(String(localized: "Install \(release.tag_name)"), .installCompatTool(archive: assets.archive, checksum: assets.checksum, folderName: folder))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            for source in model.catalog.compatTools where releases[source.id] == nil {
                do { releases[source.id] = try await CompatTools.releases(repo: source.repo) }
                catch { failure = model.describe(error) }
            }
        }
    }
}

struct SavesView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var choosing = false

    private var folder: URL? { model.settings.savesFolder.map { URL(fileURLWithPath: $0) } }
    private var backups: [URL] {
        guard let folder, let items = try? FileManager.default.contentsOfDirectory(at: folder.appending(path: deck.profile.name), includingPropertiesForKeys: nil) else { return [] }
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var body: some View {
        Page {
            Card(title: "Backup Folder", symbol: "folder") {
                if let path = model.settings.savesFolder { MonoText(text: path) }
                HStack {
                    Button("Choose…") { choosing = true }
                    Button("Back Up Now") { backup() }.disabled(folder == nil)
                }
                InlineNote(text: "Copies Emulation/saves and each emulator's save folders to this Mac. Nothing on the Deck is deleted.")
            }
            Card(title: "Backups", symbol: "clock.arrow.circlepath") {
                if backups.isEmpty {
                    EmptyState(title: "No backups yet", message: "Choose a folder on this Mac and back up your saves.", action: "Choose…") { choosing = true }
                }
                ForEach(backups, id: \.self) { backup in
                    HStack {
                        Text(verbatim: backup.lastPathComponent)
                        Spacer()
                        ConfirmButton(title: "Restore", confirm: "Replace Saves") {
                            model.enqueue(String(localized: "Restore saves"), .restoreSaves(localPath: backup.path))
                        }
                    }
                }
                InlineNote(text: "Saves with the same name on the Deck are replaced by the backup. Close the game first.")
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() {
                _ = url.startAccessingSecurityScopedResource()
                model.settings.savesFolder = url.path
            }
        }
    }

    private func backup() {
        guard let folder else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let target = folder.appending(path: deck.profile.name).appending(path: f.string(from: Date()))
        model.enqueue(String(localized: "Back up saves"), .backupSaves(localPath: target.path))
    }
}
