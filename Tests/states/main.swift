import AppKit
import SwiftUI

// Draws the real row and right panel in every state of a real torrent, off-screen.
// Run with SWARM_STATE_DIR set to a scratch folder (never the real one).
// usage: states <out-dir> <download-dir>
let out = CommandLine.arguments[1], dl = CommandLine.arguments[2]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let magnet = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Fexplodie.org%3A6969&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=wss%3A%2F%2Ftracker.openwebtorrent.com&ws=https%3A%2F%2Fwebtorrent.io%2Ftorrents%2F"

@MainActor func snap(_ name: String, _ t: Torrent, store: TorrentStore, model: AppModel) {
    for (label, view, size) in [
        ("row", AnyView(TorrentRow(torrent: t).padding(.horizontal, 12)), NSSize(width: 620, height: 64)),
        ("panel", AnyView(Inspector(selected: [t], removing: .constant([]))), NSSize(width: 300, height: 760)),
    ] {
        let host = NSHostingView(rootView: view.environment(model).environment(store)
            .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = host
        w.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // let first-appearance animations finish
        host.display()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name)-\(label).png"))
        }
        w.orderOut(nil)
    }
    print(String(format: "%-14@ status=%@ canPause=%d stop=%d again=%d starting=%d | %@", name as NSString, "\(t.status)" as NSString, t.canPause ? 1 : 0, t.canStopSharing ? 1 : 0, t.canShareAgain ? 1 : 0, t.isStarting ? 1 : 0, t.isStarting ? t.startupLine : t.finishedLine))
    fflush(stdout)
}

MainActor.assumeIsolated {
    Prefs.register()
    Prefs.folder = URL(fileURLWithPath: dl)
    let model = AppModel.shared
    let store = model.store
    store.start()
    Task { @MainActor in
        guard let hash = store.add(magnet: magnet, chooseFiles: true) else { print("add failed"); exit(1) }
        try? await Task.sleep(for: .milliseconds(300)); store.refresh()
        if let t = store.torrent(hash) { snap("1-filelist", t, store: store, model: model) }
        for _ in 0..<120 where store.torrent(hash)?.status != .choosingFiles {
            try? await Task.sleep(for: .milliseconds(250)); store.refresh()
        }
        if let t = store.torrent(hash) { snap("2-choosing", t, store: store, model: model) }
        let poster = store.files(of: hash).filter { $0.path.hasSuffix(".jpg") }.map(\.index)
        store.start(hash, files: poster)
        try? await Task.sleep(for: .milliseconds(200)); store.refresh()
        if let t = store.torrent(hash) { snap("3-starting", t, store: store, model: model) }
        for _ in 0..<240 where !(store.torrent(hash)?.status.isFinished ?? false) {
            try? await Task.sleep(for: .milliseconds(250)); store.refresh()
        }
        if let t = store.torrent(hash) { snap("4-done", t, store: store, model: model) }
        store.shareAgain([hash]); try? await Task.sleep(for: .seconds(2)); store.refresh()
        if let t = store.torrent(hash) { snap("5-share-again", t, store: store, model: model) }
        store.stopSharing([hash]); try? await Task.sleep(for: .seconds(1)); store.refresh()
        if let t = store.torrent(hash) { snap("6-stopped", t, store: store, model: model) }
        // A second torrent paused mid-way, to see the paused state.
        store.remove([hash], deleteFiles: false)
        if let h2 = store.add(magnet: magnet, chooseFiles: false) {
            for _ in 0..<120 where (store.torrent(h2)?.wantedDone ?? 0) < 2_000_000 {
                try? await Task.sleep(for: .milliseconds(250)); store.refresh()
            }
            if let t = store.torrent(h2) { snap("7-downloading", t, store: store, model: model) }
            store.pause([h2]); try? await Task.sleep(for: .seconds(1)); store.refresh()
            if let t = store.torrent(h2) { snap("8-paused", t, store: store, model: model) }
            try? await Task.sleep(for: .seconds(1.5)); store.refresh()
            if let t = store.torrent(h2) { snap("8b-paused-later", t, store: store, model: model) }
            store.remove([h2], deleteFiles: true)
        }
        store.shutDown()
        print("OK"); exit(0)
    }
}
app.run()
