import DeckKit
import DeckRemote
import SwiftUI

struct DeckyView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var store: [StorePlugin] = []
    @State private var query = ""
    @State private var failure: String?
    @State private var confirmInstall = false
    @State private var removing: InstalledPlugin?

    private var filtered: [StorePlugin] {
        query.isEmpty ? store : store.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Page {
            Card(title: "Decky Loader", symbol: "puzzlepiece.extension") {
                if let d = deck.decky, d.installed {
                    LabeledContent("Version", value: d.version ?? "–")
                    LabeledContent("Service", value: d.serviceActive ? "Running" : "Stopped")
                    Button("Update Decky…") { confirmInstall = true }
                } else {
                    Text("Decky isn't installed.").foregroundStyle(.secondary)
                    Button("Install Decky…") { confirmInstall = true }
                }
            }
            Card(title: "Installed Plugins", symbol: "checkmark.circle") {
                if deck.plugins.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(deck.plugins) { plugin in
                    HStack {
                        Text(plugin.name)
                        Text(plugin.version ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let latest = store.first(where: { $0.name == plugin.name })?.versions.first, latest.name != plugin.version {
                            Button("Update to \(latest.name)") { model.enqueue("Update \(plugin.name)", .installPlugin(name: plugin.name, version: latest)) }
                        }
                        Button("Remove") { removing = plugin }
                    }
                }
            }
            Card(title: "Plugin Store", symbol: "bag") {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                if let failure { InlineNote(text: failure, symbol: "exclamationmark.triangle", tint: .orange) }
                ForEach(filtered) { plugin in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name)
                            Text("\(plugin.author) · \(plugin.description)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if !deck.plugins.contains(where: { $0.name == plugin.name }), let version = plugin.versions.first {
                            Button("Install") { model.enqueue("Install \(plugin.name)", .installPlugin(name: plugin.name, version: version)) }
                                .disabled(deck.decky?.installed != true)
                        }
                    }
                }
            }
        }
        .task {
            guard store.isEmpty else { return }
            do { store = try await Decky.store() } catch { failure = String(describing: error) }
        }
        .confirmationDialog("Run the official Decky installer?", isPresented: $confirmInstall) {
            Button("Run Installer") { model.enqueue("Install Decky", .installDecky) }
        } message: {
            Text("It runs with sudo. Besides ~/homebrew, it adds a service in /etc/systemd/system, the one place QuietDeck writes outside /home/deck.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { p in
            Button("Remove", role: .destructive) { model.enqueue("Remove \(p.name)", .removePlugin(name: p.name)) }
        } message: { _ in Text("Installing or removing a plugin restarts Decky.") }
    }
}

struct CompatToolsView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var releases: [String: [GitHubRelease]] = [:]
    @State private var failure: String?
    @State private var removing: String?

    var body: some View {
        Page {
            Card(title: "Installed", symbol: "wineglass") {
                if deck.compatTools.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(deck.compatTools, id: \.self) { tool in
                    HStack {
                        Text(tool)
                        Spacer()
                        Button("Remove") { removing = tool }
                    }
                }
                InlineNote(text: "New tools appear in Steam after it restarts.")
            }
            if let failure { InlineNote(text: failure, symbol: "exclamationmark.triangle", tint: .orange) }
            ForEach(model.catalog.compatTools) { source in
                Card(title: source.name, symbol: "arrow.down.circle") {
                    let list = (releases[source.id] ?? []).filter { !$0.prerelease }.prefix(5)
                    if list.isEmpty { ProgressView().controlSize(.small) }
                    ForEach(Array(list)) { release in
                        HStack {
                            Text(release.tag_name)
                            Spacer()
                            if let assets = CompatTools.assets(in: release, source: source) {
                                let folder = folderName(assets.archive, source)
                                if deck.compatTools.contains(folder) { Text("Installed").foregroundStyle(.secondary) }
                                else {
                                    Button("Install") {
                                        model.enqueue("Install \(release.tag_name)", .installCompatTool(archive: assets.archive, checksum: assets.checksum, folderName: folder))
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
                catch { failure = String(describing: error) }
            }
        }
        .confirmationDialog("Remove \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { tool in
            Button("Remove", role: .destructive) { model.enqueue("Remove \(tool)", .removeCompatTool(name: tool)) }
        } message: { _ in Text("Games set to this tool need another one before they'll run.") }
    }

    /// O tar de cada release traz uma pasta com o nome do arquivo sem a arquitetura.
    private func folderName(_ asset: GitHubAsset, _ source: CompatToolSource) -> String {
        asset.name.replacingOccurrences(of: source.assetSuffix, with: "")
    }
}

struct SavesView: View {
    @Environment(AppModel.self) private var model
    var deck: LiveDeck
    @State private var restoring: URL?
    @State private var choosing = false

    private var folder: URL? { model.settings.savesFolder.map { URL(fileURLWithPath: $0) } }
    private var backups: [URL] {
        guard let folder, let items = try? FileManager.default.contentsOfDirectory(at: folder.appending(path: deck.profile.name), includingPropertiesForKeys: nil) else { return [] }
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var body: some View {
        Page {
            Card(title: "Backup Folder", symbol: "folder") {
                Text(model.settings.savesFolder ?? "Not chosen").font(.callout.monospaced()).foregroundStyle(.secondary)
                HStack {
                    Button("Choose…") { choosing = true }
                    Button("Back Up Now") { backup() }.disabled(folder == nil)
                }
                InlineNote(text: "Copies Emulation/saves and each emulator's save folders to this Mac. Nothing on the Deck is deleted.")
            }
            Card(title: "Backups", symbol: "clock.arrow.circlepath") {
                if backups.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(backups, id: \.self) { backup in
                    HStack {
                        Text(backup.lastPathComponent)
                        Spacer()
                        Button("Restore…") { restoring = backup }
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() {
                _ = url.startAccessingSecurityScopedResource()
                model.settings.savesFolder = url.path
            }
        }
        .confirmationDialog("Restore \(restoring?.lastPathComponent ?? "")?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), presenting: restoring) { url in
            Button("Restore", role: .destructive) { model.enqueue("Restore saves", .restoreSaves(localPath: url.path)) }
        } message: { _ in Text("Saves with the same name on the Deck are replaced by this backup. Close the game first.") }
    }

    private func backup() {
        guard let folder else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let target = folder.appending(path: deck.profile.name).appending(path: f.string(from: Date()))
        model.enqueue("Back up saves", .backupSaves(localPath: target.path))
    }
}
