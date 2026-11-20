import SwiftUI
import AppKit

#if !HARNESS
@main
#endif
struct SwarmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.Key.menuBar) private var showInMenuBar = true
    private let model = AppModel.shared

    var body: some Scene {
        Window("Swarm", id: "main") {
            MainView()
                .environment(model)
                .environment(model.store)
                .frame(minHeight: 440)   // never a minWidth here: see MainView
                .preferredColorScheme(AppearanceModel.shared.scheme)
        }
        .defaultSize(width: 1080, height: 660)
        .windowToolbarStyle(.unified)
        .commands { SwarmCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.store)
                .preferredColorScheme(AppearanceModel.shared.scheme)
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarPanel()
                .environment(model)
                .environment(model.store)
                .preferredColorScheme(AppearanceModel.shared.scheme)
        } label: {
            MenuBarLabel(store: model.store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.launch()
            NSApp.servicesProvider = ServiceProvider.shared   // "Share with Swarm" in Finder's Services
            NSUpdateDynamicServices()
        }
    }

    /// Magnet links (browser) and .torrent files (Finder, double-click).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            model.launch()
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { model.receive(files: files) }
            for url in urls where url.scheme?.lowercased() == "magnet" { model.add(magnet: url.absoluteString) }
        }
    }

    /// Torrents keep downloading with the window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared.showWindow() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.store.shutDown() }
    }
}

// MARK: - Menus

struct SwarmCommands: Commands {
    let model: AppModel
    @FocusedValue(\.selectedTorrents) private var selected

    private var ids: [String] { selected?.map(\.id) ?? [] }
    private var hasFiles: Bool { selected?.contains(where: \.contentExists) ?? false }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Magnet Link…") { model.newTorrent() }
                .keyboardShortcut("n")
            Button("Open Torrent File…") { model.openTorrentFilePanel() }
                .keyboardShortcut("o")
            Button("Share a File or Folder\u{2026}") { model.share() }
            Button("Send to Nearby Mac\u{2026}") { model.sendToNearbyMac() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Open Downloads Folder") { NSWorkspace.shared.open(Prefs.folder) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Show or Hide Details") { model.togglePanel() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Torrent") {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(selected?.compactMap { $0.contentExists ? $0.contentURL : nil } ?? [])
            }
            .keyboardShortcut("r")
            .disabled(!hasFiles)
            Button("Quick Look") { QuickLook.shared.toggle(selected?.compactMap(\.contentURL) ?? []) }
                .keyboardShortcut("y")
                .disabled(!hasFiles)
            Divider()
            Button("Pause") { model.store.pause(ids) }
                .keyboardShortcut("p")
                .disabled(!(selected?.contains(where: \.canPause) ?? false))
            Button("Resume") { model.store.resume(ids) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!(selected?.contains(where: \.canResume) ?? false))
            Divider()
            Button("Pause All") { model.store.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.store.canPauseAll)
            Button("Resume All") { model.store.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!model.store.canResumeAll)
            Divider()
            Button("Copy Magnet Link") {
                let links = ids.compactMap { model.store.magnet($0) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(ids.isEmpty)
            Button("Check Files Again") { ids.forEach(model.store.recheck) }
                .disabled(ids.isEmpty)
            Divider()
            Button("Remove from List") { model.store.remove(ids, deleteFiles: false) }
                .keyboardShortcut(.delete)
                .disabled(ids.isEmpty)
        }
    }
}

struct SelectedTorrentsKey: FocusedValueKey { typealias Value = [Torrent] }

extension FocusedValues {
    var selectedTorrents: [Torrent]? {
        get { self[SelectedTorrentsKey.self] }
        set { self[SelectedTorrentsKey.self] = newValue }
    }
}


/// Finder's right-click > Services > "Share with Swarm" (and the Services menu in any app).
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    @objc func shareFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let first = urls.first else {
            error.pointee = "Choose a file or folder first." as NSString
            return
        }
        MainActor.assumeIsolated { AppModel.shared.share(first) }
    }
}
