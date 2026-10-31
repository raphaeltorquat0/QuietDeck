import DeckKit
import DeckRemote
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = Keychain.password(for: AppModel.steamGridKeyAccount) ?? ""
    @State private var password = ""
    @State private var choosing = false
    @State private var choosingShelf = false
    @State private var sshHost = "192.168.0.50"
    @State private var sshUser = ""
    @State private var sshPath = ""
    @State private var serviceURL = ""
    @State private var serviceToken = Keychain.password(for: AppModel.shelfTokenAccount) ?? ""
    @State private var scraper = Keychain.decoded(ScreenScraper.Credentials.self, for: AppModel.screenScraperAccount)
        ?? ScreenScraper.Credentials(devID: "", devPassword: "", user: "", password: "")
    @State private var igdb = Keychain.decoded(IGDB.Credentials.self, for: AppModel.igdbAccount) ?? IGDB.Credentials(clientID: "", secret: "")

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Toggle("Show in the menu bar", isOn: $settings.showMenuBarExtra)
            Toggle("Play a sound when an operation finishes", isOn: $settings.completionSound)
            Section("SteamGridDB") {
                SecureField("API key", text: $apiKey)
                    .onChange(of: apiKey) { Keychain.set(apiKey, for: AppModel.steamGridKeyAccount) }
                Link("Get a key at steamgriddb.com", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
            }
            Section("Sync Folders") {
                ForEach(settings.syncFolders, id: \.self) { path in
                    HStack {
                        Text(verbatim: path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { settings.syncFolders.removeAll { $0 == path } }
                    }
                }
                Button("Add Folder…") { choosing = true }
                Text("Folders on this Mac or on a mounted SMB or NFS share. Library › Scan Sync Folders looks for new games, and games already on the Deck are skipped by hash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shelf Sources") {
                ForEach(settings.shelfSources, id: \.self) { source in
                    HStack {
                        Text(verbatim: source.label).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { settings.shelfSources.removeAll { $0 == source } }
                    }
                }
                Button("Add Folder…") { choosingShelf = true }
                Text("A folder on this Mac or a mounted SMB or NFS share, laid out as collection/system/files.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("SSH server", text: $sshHost)
                TextField("SSH user", text: $sshUser)
                TextField("Collection path on the server", text: $sshPath)
                Button("Add SSH Server") {
                    add(.ssh(host: sshHost, user: sshUser, port: 22, path: sshPath))
                    sshPath = ""
                }
                .disabled(sshHost.isEmpty || sshUser.isEmpty || !sshPath.hasPrefix("/"))
                TextField("Service address", text: $serviceURL, prompt: Text(verbatim: "http://192.168.0.50:8766"))
                SecureField("Service token", text: $serviceToken)
                    .onChange(of: serviceToken) { Keychain.set(serviceToken, for: AppModel.shelfTokenAccount) }
                Button("Add Service") {
                    add(.service(url: serviceURL))
                    serviceURL = ""
                }
                .disabled(URL(string: serviceURL)?.host == nil)
            }
            Section("Shelf Metadata") {
                TextField("ScreenScraper developer ID", text: $scraper.devID)
                SecureField("ScreenScraper developer password", text: $scraper.devPassword)
                TextField("ScreenScraper user", text: $scraper.user)
                SecureField("ScreenScraper password", text: $scraper.password)
                Link("Get ScreenScraper credentials", destination: URL(string: "https://www.screenscraper.fr/webapi2.php")!)
                TextField("IGDB Client ID", text: $igdb.clientID)
                SecureField("IGDB Client Secret", text: $igdb.secret)
                Link("Get IGDB credentials", destination: URL(string: "https://api-docs.igdb.com/#account-creation")!)
                Text("Used only for descriptions and artwork, which stay cached on this Mac. QuietDeck never downloads game files from these services.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: scraper) { save(scraper, AppModel.screenScraperAccount) }
            .onChange(of: igdb) { save(igdb, AppModel.igdbAccount) }
            Section("Decks") {
                ForEach(model.decks) { deck in
                    HStack {
                        Text(verbatim: "\(deck.name) (\(deck.host))")
                        Spacer()
                        Button("Forget") { model.remove(deck) }
                    }
                }
                if let id = model.selectedDeckID {
                    SecureField("New password for the deck user", text: $password)
                    Button("Save Password") {
                        Keychain.set(password, for: id.uuidString)
                        model.current?.hasPassword = true
                        password = ""
                    }
                    .disabled(password.isEmpty)
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Link("Buy Me a Coffee", destination: URL(string: "https://buymeacoffee.com/raphaeltorquato")!)
                Link("Source code", destination: URL(string: "https://github.com/raphaeltorquat0/QuietDeck")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get(), !settings.syncFolders.contains(url.path) { settings.syncFolders.append(url.path) }
        }
        .fileImporter(isPresented: $choosingShelf, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() { add(.folder(path: url.path)) }
        }
    }

    private func save(_ credentials: some Encodable, _ account: String) {
        if let data = try? JSONEncoder().encode(credentials) { Keychain.set(String(decoding: data, as: UTF8.self), for: account) }
    }

    private func add(_ source: ShelfSource) {
        if !model.settings.shelfSources.contains(source) { model.settings.shelfSources.append(source) }
    }
}
