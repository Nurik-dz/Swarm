import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

/// Shared by every window: the store, and the Add sheet's state.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let store = TorrentStore()
    /// Sending files to, and receiving from, other Macs on the network.
    let lan: LanService
    /// The "share this file or folder" window; nil when closed.
    var shareJob: ShareJob?
    /// What the "send to a nearby Mac" window is about; nil when closed.
    var sendPath: URL?

    private init() { lan = LanService(store: store) }
    /// A dropped folder or file that matches a torrent in the list, waiting for a yes.
    var existingOffer: ExistingOffer?

    struct ExistingOffer: Identifiable {
        let id = UUID()
        let torrent: Torrent
        let folder: URL
        let dropped: String
    }

    /// The Add Torrent sheet; nil when closed.
    var adding: AddRequest?
    var openMainWindow: (() -> Void)?
    /// What is playing from a torrent, shown as a bar in the main window.
    private(set) var player: PlayerModel?
    private var started = false
    private var lastPanelToggle = Date.distantPast

    /// Shows or hides the details panel. A click while the panel is still
    /// sliding is ignored, as in Apple's apps: on macOS 27 stacking inspector
    /// animations (worst right after an appearance change) makes AppKit's
    /// layout loop until it aborts. Proven in Tests/harness.
    func togglePanel() {
        guard Date().timeIntervalSince(lastPanelToggle) > 0.45 else { return }
        lastPanelToggle = Date()
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: Prefs.Key.inspector), forKey: Prefs.Key.inspector)
    }

    struct AddRequest: Identifiable, Equatable {
        let id = UUID()
        /// Prefilled text (a magnet link).
        var text: String = ""
        /// Already added and waiting for the file choice.
        var hash: String?
        /// Added by this sheet: Cancel removes it again.
        var addedHere = false
    }

    func launch() {
        guard !started else { return }
        started = true
        Prefs.register()
        AppearanceModel.shared.start()
        Notifier.shared.setUp()
        store.onFinished = { Notifier.shared.finished($0) }
        store.start()
        if UserDefaults.standard.bool(forKey: Prefs.Key.lanReceive) { lan.startReceiving() }
        followProgress()
    }

    private func followProgress() {
        withObservationTracking {
            DockProgress.shared.update(progress: store.overallProgress, active: store.activeCount)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followProgress() }
        }
    }

    // MARK: Sharing your own files

    /// Opens the share window for a file or folder, or asks which one.
    func share(_ url: URL? = nil) {
        showWindow()
        if let url { shareJob = ShareJob(path: url); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Share"; panel.message = "Choose a file or folder to make a torrent link for."
        if panel.runModal() == .OK, let u = panel.url { shareJob = ShareJob(path: u) }
    }

    // MARK: Nearby Macs

    func sendToNearbyMac(_ url: URL? = nil) {
        showWindow()
        if let url { sendPath = url; return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Send"; panel.message = "Choose a file or folder to send to another Mac on this network."
        if panel.runModal() == .OK, let u = panel.url { sendPath = u }
    }

    func setReceiving(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Prefs.Key.lanReceive)
        if on { lan.startReceiving() } else { lan.stopReceiving() }
    }

    // MARK: Playing

    /// Starts playing a file of a torrent that is still downloading, in the main window.
    func play(_ file: TorrentFile, of torrent: Torrent) {
        stopPlayer()
        guard let p = PlayerModel(store: store, torrent: torrent, file: file) else {
            store.problem = .init(title: "Can't play this yet", message: "Swarm can play MP4, M4V and MOV videos and M4A, M4B and MP3 audio while they download. This file needs to finish first.")
            return
        }
        player = p
    }

    func stopPlayer() {
        player?.stop()
        player = nil
    }

    func stopPlayer(forTorrent id: String) { if player?.torrentID == id { stopPlayer() } }

    // MARK: Windows

    func showWindow() {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    func newTorrent(text: String = "") {
        showWindow()
        adding = AddRequest(text: text)
    }

    /// Opens the file chooser for a torrent already in the list.
    func chooseFiles(for id: String) {
        showWindow()
        adding = AddRequest(hash: id)
    }

    func openTorrentFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more .torrent files"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        receive(files: panel.urls)
    }

    // MARK: Torrents coming in (links, files, drops, Finder, browser)

    func receive(text: String) {
        let magnets = Self.magnets(in: text)
        guard !magnets.isEmpty else {
            store.problem = .init(title: "No magnet link found",
                                  message: "Copy a link that starts with \u{201C}magnet:\u{201D} and paste it again, or drop a .torrent file.")
            return
        }
        if magnets.count == 1 && Prefs.chooseFiles {
            add(magnet: magnets[0])
        } else {
            for m in magnets { store.add(magnet: m, chooseFiles: false) }
            showWindow()
        }
    }

    func receive(files: [URL]) {
        let torrents = files.filter { $0.pathExtension.lowercased() == "torrent" }
        // Anything else dropped is files you may already have for a torrent in the list.
        let others = files.filter { $0.pathExtension.lowercased() != "torrent" }
        if torrents.isEmpty, let first = others.first {
            showWindow()
            if let match = store.torrentsMatching(first).first {
                existingOffer = ExistingOffer(torrent: match.torrent, folder: match.folder, dropped: first.lastPathComponent)
            } else {
                store.problem = .init(title: "No torrent matches \u{201C}\(first.lastPathComponent)\u{201D}",
                                      message: "Add the torrent first (a magnet link or .torrent file), then drop its folder here and Swarm will check it and download only what's missing.")
            }
            return
        }
        guard !torrents.isEmpty else { return }
        if torrents.count == 1 && Prefs.chooseFiles {
            showWindow()
            if let hash = store.add(file: torrents[0], chooseFiles: true) {
                adding = AddRequest(hash: hash, addedHere: true)
            }
        } else {
            for f in torrents { store.add(file: f, chooseFiles: false) }
            showWindow()
        }
    }

    /// Adds a magnet and opens the chooser while the file list arrives.
    func add(magnet: String) {
        showWindow()
        if Prefs.chooseFiles {
            let isNew = !store.torrents.contains { magnet.lowercased().contains($0.id) }
            if let hash = store.add(magnet: magnet, chooseFiles: true) {
                adding = AddRequest(hash: hash, addedHere: isNew)
            }
        } else {
            store.add(magnet: magnet, chooseFiles: false)
        }
    }

    static func magnets(in text: String) -> [String] {
        var out: [String] = []
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "<" || $0 == ">" }) {
            let s = String(word)
            if s.lowercased().hasPrefix("magnet:?"), !out.contains(s) { out.append(s) }
        }
        // A bare 40-character info hash works too.
        if out.isEmpty {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count == 40, t.allSatisfy(\.isHexDigit) { out.append("magnet:?xt=urn:btih:" + t) }
        }
        return out
    }

    /// Reads magnets and .torrent files out of pasted or dropped items.
    func receive(providers: [NSItemProvider]) {
        Task {
            var files: [URL] = []
            var text: [String] = []
            for p in providers {
                if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) {
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { files.append(u) }
                    else if let u = item as? URL { files.append(u) }
                } else if p.canLoadObject(ofClass: URL.self), let url = await p.loadURL() {
                    if url.isFileURL { files.append(url) } else { text.append(url.absoluteString) }
                } else if p.canLoadObject(ofClass: String.self), let s = await p.loadString() {
                    text.append(s)
                }
            }
            if !files.isEmpty { receive(files: files) }
            if !text.isEmpty { receive(text: text.joined(separator: "\n")) }
        }
    }
}

extension NSItemProvider {
    func loadURL() async -> URL? {
        await withCheckedContinuation { c in _ = loadObject(ofClass: URL.self) { u, _ in c.resume(returning: u) } }
    }
    func loadString() async -> String? {
        await withCheckedContinuation { c in _ = loadObject(ofClass: String.self) { s, _ in c.resume(returning: s) } }
    }
}
