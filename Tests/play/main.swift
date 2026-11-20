import AppKit
import AVFoundation
import SwiftUI

// Plays Big Buck Bunny through TorrentStream while it downloads, then seeks.
// Run with SWARM_STATE_DIR set to a scratch folder.  usage: play <download-dir>
let dl = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let magnet = ProcessInfo.processInfo.environment["MAGNET"] ?? "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Fexplodie.org%3A6969&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce"
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failures += 1 }; fflush(stdout) }

MainActor.assumeIsolated {
    Prefs.register()
    Prefs.folder = URL(fileURLWithPath: dl)
    let store = AppModel.shared.store
    store.start()
    Task { @MainActor in
        let restored = ProcessInfo.processInfo.environment["RESTORED"] == "1"   // a copy of a real torrent's saved state
        var hash = ""
        if restored {
            hash = store.torrents.first?.id ?? ""
        } else {
            guard let h = store.add(magnet: magnet, chooseFiles: true) else { print("add failed"); exit(1) }
            hash = h
            for _ in 0..<120 where store.torrent(hash)?.status != .choosingFiles {
                try? await Task.sleep(for: .milliseconds(250)); store.refresh()
            }
        }
        let files = store.files(of: hash)
        guard let mp4 = files.first(where: { ["mp4","m4b","m4a"].contains($0.ext) }) else { print("no mp4"); exit(1) }
        store.start(hash, files: [mp4.index])
        if let l = ProcessInfo.processInfo.environment["LIMIT_KB"].flatMap({ Int32($0) }) { store.session.setDownloadLimit(l * 1024, uploadLimit: 0); print("download limited to \(l) KB/s") }
        let t0 = Date()
        guard let model = PlayerModel(store: store, torrent: store.torrent(hash)!, file: mp4) else { print("no stream"); exit(1) }
        model.player.isMuted = true
        for i in 0..<8 {
            try? await Task.sleep(for: .seconds(2)); store.refresh()
            let t = store.torrent(hash)!
            let m = store.session.availabilityMap(ofFile: Int32(mp4.index), inTorrent: hash, buckets: 20).map { Int($0.doubleValue * 100) }
            print("t=\(i*2)s down=\(t.wantedDone) peers=\(t.peers) rate=\(t.downRate) contiguous0=\(store.session.contiguousBytes(inFile: Int32(mp4.index), inTorrent: hash, from: 0)) map=\(m)")
        }
        // 1. Starts playing before the download is anywhere near done.
        var started: Double?
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(250)); store.refresh()
            if model.player.currentTime().seconds > 2 { started = Date().timeIntervalSince(t0); break }
        }
        for _ in 0..<160 where model.chapters.isEmpty || model.artwork == nil { try? await Task.sleep(for: .milliseconds(250)) }
        print("metadata: title=\(model.bookTitle ?? "-") author=\(model.author ?? "-") cover=\(model.artwork.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none") chapters=\(model.chapters.count) first=\(model.chapters.first?.title ?? "-")")
        check(model.bookTitle != nil, "book title read from the file")
        if started != nil {
            let app = AppModel.shared
            let view = NowPlayingBar(model: model).environment(app)
                .frame(width: 560, height: 250).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: 560, height: 250)
            let w = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 560, height: 250), styleMask: .borderless, backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .aqua); w.contentView = host; w.orderFront(nil)
            try? await Task.sleep(for: .milliseconds(900)); host.display()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dl + "/../bar.png"))
            }
        }
        let doneAtStart = model.percentDone
        if let e = model.player.currentItem?.error { print("item error:", e) }
        print("item status", model.player.currentItem?.status.rawValue as Any, "rate", model.player.rate, "tc", model.player.timeControlStatus.rawValue, model.player.reasonForWaitingToPlay?.rawValue as Any)
        check(started != nil, "playback started (\(started.map { String(format: "%.1f s", $0) } ?? "never"), \(Int(doneAtStart * 100))% downloaded)")
        check(doneAtStart < 0.5, "started well before the download finished")
        let dur = model.player.currentItem?.duration.seconds ?? 0
        check(dur > 60, String(format: "duration known: %.0f s", dur))
        // Does it keep going? Log the position for 40 s.
        var last = model.player.currentTime().seconds
        var advancing = 0
        for i in 0..<8 {
            try? await Task.sleep(for: .seconds(5)); store.refresh()
            let now = model.player.currentTime().seconds
            print(String(format: "  +%ds position %.1f s (%@) buffering=%@ rate=%.1f", (i + 1) * 5, now, now > last + 2 ? "moving" : "STUCK", model.buffering ? "yes" : "no", model.player.rate)); print("     status:", model.status.text, "| playing=\(model.isPlaying) tc=\(model.player.timeControlStatus.rawValue) wait=\(model.player.reasonForWaitingToPlay?.rawValue ?? "-")")
            if now > last + 2 { advancing += 1 }
            last = now
        }
        check(advancing >= 6, "keeps playing after the start (\(advancing) of 8 intervals moved)")
        // 2. Seek far ahead, into data that has not been downloaded.
        let target = dur * 0.6
        let before = model.percentDone
        await model.player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        let t1 = Date()
        var resumed: Double?
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(250)); store.refresh()
            if model.player.currentTime().seconds > target + 3 { resumed = Date().timeIntervalSince(t1); break }
        }
        check(resumed != nil, "after seek to \(Int(target)) s playback continued (\(resumed.map { String(format: "%.1f s", $0) } ?? "never"); \(Int(before * 100))% -> \(Int(model.percentDone * 100))% downloaded)")
        check(model.failure == nil, "no player failure")
        // 3. Teardown restores normal downloading and leaves no reader behind.
        model.stop()
        try? await Task.sleep(for: .milliseconds(500))
        check(store.torrent(hash)?.status == .downloading, "torrent keeps downloading after the player closes")
        store.remove([hash], deleteFiles: true)
        store.shutDown()
        print(failures == 0 ? "OK" : "FAILED"); exit(failures == 0 ? 0 : 1)
    }
}
app.run()
