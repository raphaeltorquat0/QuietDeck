import DeckKit
import DeckRemote
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = Keychain.password(for: AppModel.steamGridKeyAccount) ?? ""
    @State private var password = ""
    @State private var choosing = false
    @State private var addingSource = false
    @State private var scraper = Keychain.decoded(ScreenScraper.Credentials.self, for: AppModel.screenScraperAccount)
        ?? ScreenScraper.Credentials(devID: "", devPassword: "", user: "", password: "")
    @State private var igdb = Keychain.decoded(IGDB.Credentials.self, for: AppModel.igdbAccount) ?? IGDB.Credentials(clientID: "", secret: "")
    @State private var raAccount = Keychain.decoded(RetroAchievementsAccount.self, for: AppModel.retroAchievementsAccount)
    @State private var raUser = ""
    @State private var raPassword = ""
    @State private var raBusy = false
    @State private var raError: String?

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
            Section("RetroAchievements") {
                if let raAccount {
                    LabeledContent("Signed in as", value: raAccount.username)
                    Button("Sign Out") {
                        model.signOutRetroAchievements()
                        self.raAccount = nil
                    }
                } else {
                    TextField("User", text: $raUser)
                    SecureField("Password", text: $raPassword)
                    Button(raBusy ? "Signing In…" : "Sign In") { signIn() }
                        .disabled(raUser.isEmpty || raPassword.isEmpty || raBusy)
                    Link("Create a free account", destination: URL(string: "https://retroachievements.org/createaccount.php")!)
                }
                if let raError { Text(verbatim: raError).font(.callout).foregroundStyle(.orange) }
                Text("Achievements for games on RetroArch and Dolphin, turned on in every game you send. Your password goes only to RetroAchievements; QuietDeck keeps just the sign-in token.")
                    .font(.caption).foregroundStyle(.secondary)
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
                ForEach(sorted) { source in
                    HStack {
                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(model.shelf.states[source.id]?.color ?? .secondary)
                        VStack(alignment: .leading) {
                            Text(verbatim: source.name)
                            Text(verbatim: source.kind.label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { move(source, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).accessibilityLabel("Move up").disabled(sorted.first == source)
                        Button { move(source, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).accessibilityLabel("Move down").disabled(sorted.last == source)
                        Button("Remove") {
                            ShelfStore.forget(source.id)
                            settings.shelfSources.removeAll { $0.id == source.id }
                        }
                    }
                }
                Button("Add Source…") { addingSource = true }
                Text("When a game is in several sources, QuietDeck installs from the highest one that's online.").font(.caption).foregroundStyle(.secondary)
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
        .sheet(isPresented: $addingSource) { SourceWizard() }
    }

    private func signIn() {
        raBusy = true
        raError = nil
        Task {
            defer { raBusy = false }
            do {
                try await model.signInRetroAchievements(username: raUser, password: raPassword)
                raAccount = Keychain.decoded(RetroAchievementsAccount.self, for: AppModel.retroAchievementsAccount)
                raPassword = ""
            } catch {
                raError = model.describe(error)
            }
        }
    }

    private func save(_ credentials: some Encodable, _ account: String) {
        if let data = try? JSONEncoder().encode(credentials) { Keychain.set(String(decoding: data, as: UTF8.self), for: account) }
    }

    private var sorted: [LibrarySource] { model.settings.shelfSources.sorted { $0.priority < $1.priority } }

    private func move(_ source: LibrarySource, by offset: Int) {
        var list = sorted
        guard let i = list.firstIndex(of: source), list.indices.contains(i + offset) else { return }
        list.swapAt(i, i + offset)
        model.settings.shelfSources = list.enumerated().map { index, item in
            var item = item
            item.priority = index
            return item
        }
    }
}
