#if DEBUG
import AppKit
import DeckRemote
import SwiftUI

/// `QuietDeck --press-kit <pasta> --fixture <json>`, só em Debug: as telas do README com os dados da
/// fixture de record/replay, cada uma numa janela própria renderizada em bitmap.
@MainActor enum PressKit {
    /// Fila de exemplo no rodapé da sidebar; `running` volta como `interrupted`, como no app real.
    static func seedQueue(deckID: UUID, to url: URL) {
        var done = Job(deckID: deckID, title: "Install PCSX2", action: .installEmulator(appID: "net.pcsx2.PCSX2"))
        done.state = .succeeded
        var failed = Job(deckID: deckID, title: "Send Okami.iso", action: .upload(localPath: "/o", remoteDirectory: "/r"))
        failed.state = .failed("Not enough space on the Deck")
        let waiting = Job(deckID: deckID, title: "Send Golden Sun.gba", action: .upload(localPath: "/g", remoteDirectory: "/r"))
        try? JSONEncoder().encode([done, failed, waiting]).write(to: url)
    }

    static func run(_ model: AppModel, to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await model.current?.refresh()
        for appearance in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            for section in AppSection.allCases {
                model.section = section
                await shot(RootView().environment(model), title: section.title, size: NSSize(width: 1040, height: 700), appearance: appearance.1,
                           to: dir.appending(path: "\(section.rawValue)-\(appearance.0).png"))
            }
            model.showOnboarding = false
            await shot(OnboardingView().environment(model), title: "Add Deck", size: NSSize(width: 520, height: 420), appearance: appearance.1,
                       to: dir.appending(path: "onboarding-\(appearance.0).png"))
            await shot(MenuBarPanel().environment(model), title: nil, size: NSSize(width: 260, height: 150), appearance: appearance.1,
                       to: dir.appending(path: "menubar-\(appearance.0).png"))
        }
        exit(0)
    }

    /// Janela real e `screencapture -l`: `cacheDisplay` não desenha a sidebar nem os materiais.
    private static func shot(_ view: some View, title: String?, size: NSSize, appearance: NSAppearance.Name, to url: URL) async {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: appearance)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.styleMask = title == nil ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.title = title ?? ""
        w.setContentSize(size)
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1.5))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(w.windowNumber)", url.path]
        try? p.run()
        p.waitUntilExit()
        print(url.path)
        w.orderOut(nil)
    }
}
#endif
