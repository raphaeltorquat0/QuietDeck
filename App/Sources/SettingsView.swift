import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = Keychain.password(for: AppModel.steamGridKeyAccount) ?? ""
    @State private var password = ""
    @State private var choosing = false

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
        .frame(width: 520, height: 560)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get(), !settings.syncFolders.contains(url.path) { settings.syncFolders.append(url.path) }
        }
    }
}
