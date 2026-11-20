import AppKit
import AVFoundation
import SwiftUI

// A local seeder (throttled) and the real app model streaming a file whose index
// sits at the END, like many audiobooks. No internet needed.
// usage: stream <dir with test.torrent and seed/> <download-dir> <seed-state-dir> [upload KB/s]
let base = CommandLine.arguments[1], dl = CommandLine.arguments[2], seedState = CommandLine.arguments[3]
let upKB = Int32(CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "150") ?? 150
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failures += 1 }; fflush(stdout) }

MainActor.assumeIsolated {
    Prefs.register()
    Prefs.folder = URL(fileURLWithPath: dl)
    let seeder = TBSession(stateFolder: seedState)
    seeder.setListenPort(6999)
    seeder.setDownloadLimit(0, uploadLimit: upKB * 1024)
    var err: NSString?
    defer {}
    guard let seedHash = seeder.addTorrentFile(base + "/test.torrent", savePath: base + "/seed", startPaused: false, error: &err) else { print("seed failed", err ?? ""); exit(1) }
    seeder.setUploadLimit(upKB * 1024, forTorrent: seedHash)
    let store = AppModel.shared.store
    store.start()
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))   // seeder checks its file
        guard let hash = store.add(file: URL(fileURLWithPath: base + "/test.torrent"), chooseFiles: false) else { print("add failed"); exit(1) }
        precondition(hash == seedHash)
        store.session.connectPeer("127.0.0.1", port: 6999, forTorrent: hash)
        for _ in 0..<40 where store.files(of: hash).isEmpty { try? await Task.sleep(for: .milliseconds(250)); store.refresh() }
        guard let file = store.files(of: hash).first else { print("no file list"); exit(1) }
        // The seeder may still be checking its file: keep asking until connected.
        Task { @MainActor in
            for i in 0..<60 {
                store.session.connectPeer("127.0.0.1", port: 6999, forTorrent: hash)
                if i % 3 == 0, let t = store.torrent(hash), let sd = seeder.torrents().first {
                    print("[diag] leecher peers=\(t.peers) known=\(t.knownPeers) rate=\(t.downRate) map=\(store.session.availabilityMap(ofFile: 0, inTorrent: hash, buckets: 22).map { Int($0.doubleValue * 100) }) | seeder state=\(sd.state.rawValue) peers=\(sd.peers) up=\(sd.uploadRate)")
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        let t0 = Date()
        guard let model = PlayerModel(store: store, torrent: store.torrent(hash)!, file: file) else { print("no stream"); exit(1) }
        model.player.isMuted = true
        var started: Double?
        for _ in 0..<480 {
            try? await Task.sleep(for: .milliseconds(250)); store.refresh()
            if model.player.currentTime().seconds > 2 { started = Date().timeIntervalSince(t0); break }
            if model.failure != nil { break }
        }
        print(String(format: "[test %.1f]", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)), "loop ended, started=\(started != nil)")
        if let e = model.player.currentItem?.error { print("item error:", e) }
        check(started != nil, "playback started (\(started.map { String(format: "%.1f s", $0) } ?? "never"), \(Int(model.percentDone * 100))% downloaded, \(upKB) KB/s seeder)")
        var moved = 0, last = model.player.currentTime().seconds
        for _ in 0..<4 { try? await Task.sleep(for: .seconds(3)); let n = model.player.currentTime().seconds; if n > last + 1.5 { moved += 1 }; last = n }
        check(moved >= 3, "keeps playing (\(moved) of 4)")
        for _ in 0..<80 where model.chapters.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        print("metadata: title=\(model.bookTitle ?? "-") author=\(model.author ?? "-") cover=\(model.artwork != nil) chapters=\(model.chapters.map(\.title))")
        check(model.bookTitle == "The Test Book" && model.author == "A. Author", "title and author read")
        check(model.artwork != nil, "cover read")
        check(model.chapters.count == 3, "3 chapters read")
        await model.player.seek(to: CMTime(seconds: 1300, preferredTimescale: 600))
        var resumed = false
        for _ in 0..<160 { try? await Task.sleep(for: .milliseconds(250)); if model.player.currentTime().seconds > 1303 { resumed = true; break } }
        check(resumed, "seek into the third chapter resumed")
        check(model.currentChapter?.title == "Chapter Three", "chapter follows position (\(model.currentChapter?.title ?? "-"))")
        model.stop()
        store.remove([hash], deleteFiles: true)
        print(failures == 0 ? "OK" : "FAILED"); exit(failures == 0 ? 0 : 1)
    }
}
app.run()
