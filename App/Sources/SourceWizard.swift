import DeckKit
import DeckRemote
import Network
import NetFS
import Observation
import SwiftUI

/// Compartilhamentos montados pelo sistema em `mounts/<id>`, só leitura e fora do Finder.
enum Mounts {
    static func folder(_ id: UUID) -> URL { Paths.support.appending(path: "mounts/\(id.uuidString)") }

    static func isMounted(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mounted = withUnsafeBytes(of: &info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return mounted == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// `NetFS` recebe a senha como argumento, sem passar por `argv` como o `mount_smbfs`.
    static func mount(_ url: String, at folder: URL, secret: SourceSecret) -> SourceState {
        guard !isMounted(folder.path) else { return .online }
        guard let target = URL(string: url) else { return .offline }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let open = NSMutableDictionary(dictionary: [kNAUIOptionKey as String: kNAUIOptionNoUI as String])
        let options = NSMutableDictionary(dictionary: [kNetFSMountAtMountDirKey as String: true,
                                                       kNetFSMountFlagsKey as String: MNT_RDONLY | MNT_DONTBROWSE])
        var points: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(target as CFURL, folder as CFURL, secret.user.isEmpty ? nil : secret.user as CFString,
                                       secret.password.isEmpty ? nil : secret.password as CFString, open, options, &points)
        points?.release()
        switch status {
        case 0: return .online
        case EAUTH, EACCES, EPERM: return .badCredentials
        default: return .offline
        }
    }
}

/// Procura compartilhamentos na rede local. Só preenche o formulário: nada é cadastrado sozinho.
@MainActor @Observable
final class SourceDiscovery {
    struct Found: Identifiable, Hashable {
        var name: String
        var kind: SourceWizard.Kind
        var id: String { "\(kind.rawValue)|\(name)" }
        /// Nome Bonjour vira host `.local`; o usuário pode trocar pelo endereço Tailscale.
        var host: String { name.replacingOccurrences(of: " ", with: "-") + ".local" }
    }

    private(set) var found: [Found] = []
    private var browsers: [NWBrowser] = []
    private static let types: [(String, SourceWizard.Kind)] = [("_smb._tcp", .smb), ("_nfs._tcp", .nfs), ("_webdav._tcp", .webdav), ("_webdavs._tcp", .webdav), ("_sftp-ssh._tcp", .ssh)]

    func start() {
        guard browsers.isEmpty else { return }
        for (type, kind) in Self.types {
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let names: [String] = results.compactMap { if case let .service(name, _, _, _) = $0.endpoint { name } else { nil } }
                Task { @MainActor in
                    guard let self else { return }
                    for name in names where !self.found.contains(where: { $0.name == name && $0.kind == kind }) {
                        self.found.append(Found(name: name, kind: kind))
                    }
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
    }
}

/// Cadastro de uma fonte: tipo, endereço, credenciais e teste antes de salvar.
struct SourceWizard: View {
    enum Kind: String, CaseIterable, Identifiable {
        case folder, smb, nfs, ssh, webdav, s3, romm, service
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .folder: "Folder or external disk"
            case .smb: "SMB"
            case .nfs: "NFS"
            case .ssh: "SFTP/SSH"
            case .webdav: "WebDAV"
            case .s3: "S3-compatible bucket"
            case .romm: "RomM server"
            case .service: "QuietDeck service"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var discovery = SourceDiscovery()
    @State private var kind = Kind.folder
    @State private var name = ""
    @State private var address = ""
    @State private var path = ""
    @State private var user = ""
    @State private var password = ""
    @State private var token = ""
    @State private var region = ""
    @State private var bucket = ""
    @State private var state: SourceState?
    @State private var testing = false
    @State private var choosing = false
    private let id = UUID()

    private var source: LibrarySource? {
        let host = address.trimmingCharacters(in: .whitespaces)
        let shelfKind: ShelfSource?
        switch kind {
        case .folder: shelfKind = path.hasPrefix("/") ? .folder(path: path) : nil
        case .smb: shelfKind = host.isEmpty ? nil : .smb(url: "smb://\(host)/\(path)")
        case .nfs: shelfKind = host.isEmpty ? nil : .nfs(url: "nfs://\(host)/\(path)")
        case .ssh: shelfKind = host.isEmpty || user.isEmpty || !path.hasPrefix("/") ? nil : .ssh(host: host, user: user, port: 22, path: path)
        case .webdav: shelfKind = URL(string: host)?.host == nil ? nil : .webdav(url: host)
        case .s3: shelfKind = URL(string: host)?.host == nil || bucket.isEmpty || user.isEmpty ? nil : .s3(endpoint: host, region: region.isEmpty ? "auto" : region, bucket: bucket, prefix: path, accessKey: user)
        case .romm: shelfKind = URL(string: host)?.host == nil ? nil : .romm(url: host)
        case .service: shelfKind = URL(string: host)?.host == nil ? nil : .service(url: host)
        }
        return shelfKind.map {
            LibrarySource(id: id, name: name.isEmpty ? $0.label : name, priority: (model.settings.shelfSources.map(\.priority).max() ?? -1) + 1, kind: $0)
        }
    }

    private var secret: SourceSecret { SourceSecret(user: user, password: password, token: token) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if !discovery.found.isEmpty {
                    Section("Found on Your Network") {
                        ForEach(discovery.found) { item in
                            Button {
                                kind = item.kind
                                name = item.name
                                address = item.kind == .webdav ? "http://\(item.host)" : item.host
                                state = nil
                            } label: {
                                LabeledContent { Text(item.kind.title) } label: { Text(verbatim: item.name) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Source") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) { ForEach(Kind.allCases) { Text($0.title).tag($0) } }
                    fields
                }
                Section {
                    Text("Sources are always your own servers. Tailscale addresses work wherever a host is asked for, so you never need to expose a server to the internet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if testing { ProgressView().controlSize(.small) }
                if let state { Label(state.title, systemImage: "circle.fill").font(.callout).foregroundStyle(state.color) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Test Connection") { Task { await test() } }.disabled(source == nil || testing)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(source == nil || state != .online)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .task { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: kind) { state = nil }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() {
                path = url.path
                if name.isEmpty { name = url.lastPathComponent }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        switch kind {
        case .folder:
            LabeledContent("Folder") {
                Button(path.isEmpty ? String(localized: "Choose…") : path) { choosing = true }
            }
        case .smb, .nfs:
            TextField("Server", text: $address, prompt: Text(verbatim: "192.168.0.50"))
            TextField("Share path", text: $path)
            if kind == .smb {
                TextField("User", text: $user)
                SecureField("Password", text: $password)
            } else {
                Text("The server must allow connections from unprivileged ports, which is the `insecure` export option on Linux.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ssh:
            TextField("Server", text: $address, prompt: Text(verbatim: "192.168.0.50"))
            TextField("User", text: $user)
            TextField("Collection path on the server", text: $path)
            MonoText(text: Paths.key + ".pub")
            Text("Add this public key to the server's authorized_keys.").font(.caption).foregroundStyle(.secondary)
        case .webdav:
            TextField("Address", text: $address, prompt: Text(verbatim: "https://nas.local/roms"))
            TextField("User", text: $user)
            SecureField("Password", text: $password)
        case .s3:
            TextField("Endpoint", text: $address, prompt: Text(verbatim: "https://s3.us-west-004.backblazeb2.com"))
            TextField("Region", text: $region, prompt: Text(verbatim: "auto"))
            TextField("Bucket", text: $bucket)
            TextField("Prefix", text: $path)
            TextField("Access key", text: $user)
            SecureField("Secret key", text: $password)
        case .romm:
            TextField("Address", text: $address, prompt: Text(verbatim: "http://192.168.0.50:8080"))
            SecureField("API token", text: $token)
            Text("Create a read-only token in RomM with the roms.read and platforms.read scopes.").font(.caption).foregroundStyle(.secondary)
        case .service:
            TextField("Address", text: $address, prompt: Text(verbatim: "http://192.168.0.50:8766"))
            SecureField("Token", text: $token)
        }
    }

    private func test() async {
        guard let source else { return }
        testing = true
        defer { testing = false }
        state = await model.shelf.probe(source, secret: secret)
    }

    private func save() {
        guard let source else { return }
        ShelfStore.store(secret, for: source.id)
        model.settings.shelfSources.append(source)
        let shelf = model.shelf, sources = model.settings.shelfSources
        Task { await shelf.refreshStates(sources) }
        dismiss()
    }
}

/// O que não deu para decidir sozinho: cada pasta aponta para um sistema.
struct FolderMapSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picks: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Folders") {
                    ForEach(model.shelf.undecidedFolders, id: \.folder) { entry in
                        Picker(selection: Binding(get: { picks[entry.folder] ?? "" }, set: { picks[entry.folder] = $0 })) {
                            Text("Choose…").tag("")
                            ForEach(model.catalog.systems, id: \.id) { Text(verbatim: $0.name).tag($0.id) }
                        } label: {
                            Text(verbatim: entry.folder).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(picks.values.allSatisfy(\.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
    }

    private func save() {
        for entry in model.shelf.undecidedFolders {
            guard let system = picks[entry.folder], !system.isEmpty,
                  let i = model.settings.shelfSources.firstIndex(where: { $0.id == entry.sourceID }) else { continue }
            model.settings.shelfSources[i].folderMap[entry.folder] = system
        }
        let sources = model.settings.shelfSources, catalog = model.catalog, shelf = model.shelf
        Task { await shelf.rebuild(sources, catalog: catalog) }
        dismiss()
    }
}

/// Status das fontes na sidebar. Sem fundo: já está no vidro dela.
struct SourceStatusList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.settings.shelfSources.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.settings.shelfSources.sorted { $0.priority < $1.priority }) { source in
                    let state = model.shelf.states[source.id]
                    Button { model.section = .shelf } label: {
                        Label {
                            Text(verbatim: source.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        } icon: {
                            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(state?.color ?? .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(state.map { String(localized: $0.title) } ?? "")
                    .accessibilityValue(state.map { Text($0.title) } ?? Text(verbatim: ""))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

extension SourceState {
    var title: LocalizedStringResource {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .badCredentials: "Invalid credentials"
        }
    }

    var color: Color {
        switch self {
        case .online: .green
        case .offline: .red
        case .badCredentials: .orange
        }
    }
}
