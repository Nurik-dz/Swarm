import AppKit
import AVFoundation

// Subtitles in the player: files from the torrent and a track inside the video.
// usage: subs <dir with test.torrent and seed/> <download-dir> <seed-state-dir>
let base = CommandLine.arguments[1], dl = CommandLine.arguments[2], seedState = CommandLine.arguments[3]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failures += 1 }; fflush(stdout) }

MainActor.assumeIsolated {
    Prefs.register()
    UserDefaults.standard.removeObject(forKey: "subtitleLanguage")
    Prefs.folder = URL(fileURLWithPath: dl)
    let seeder = TBSession(stateFolder: seedState)
    seeder.setListenPort(6998)
    var err: NSString?
    guard let seedHash = seeder.addTorrentFile(base + "/test.torrent", savePath: base + "/seed", startPaused: false, error: &err) else { print("seed failed"); exit(1) }
    let store = AppModel.shared.store
    store.start()
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        guard let hash = store.add(file: URL(fileURLWithPath: base + "/test.torrent"), chooseFiles: false) else { print("add failed"); exit(1) }
        precondition(hash == seedHash)
        Task { @MainActor in
            for i in 0..<30 {
                store.session.connectPeer("127.0.0.1", port: 6998, forTorrent: hash)
                if i % 2 == 0, let t = store.torrent(hash), let sd = seeder.torrents().first {
                    print("[diag] leecher peers=\(t.peers) known=\(t.knownPeers) status=\(t.status) down=\(t.wantedDone)/\(t.chosenSize) | seeder state=\(sd.state.rawValue) peers=\(sd.peers) progress=\(sd.progress)")
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        for _ in 0..<80 where store.files(of: hash).count < 3 { try? await Task.sleep(for: .milliseconds(250)); store.refresh() }
        guard let video = store.files(of: hash).first(where: { $0.ext == "mp4" }) else { print("no video"); exit(1) }
        guard let model = PlayerModel(store: store, torrent: store.torrent(hash)!, file: video) else { print("no stream"); exit(1) }
        model.player.isMuted = true
        for _ in 0..<240 where model.player.currentTime().seconds < 0.5 { try? await Task.sleep(for: .milliseconds(250)); store.refresh() }
        if let e = model.player.currentItem?.error { print("item error:", e) }
        print("failure:", model.failure ?? "-", "| percent", model.percentDone, "| status", model.status.text)
        check(model.player.currentTime().seconds > 0.5, "video plays")
        for _ in 0..<80 where model.subtitleOptions.count < 3 { try? await Task.sleep(for: .milliseconds(250)) }
        print("options:", model.subtitleOptions.map { "\($0.title) [\($0.source)]" })
        check(model.subtitleOptions.count == 3, "three subtitle options (1 embedded + 2 files)")
        check(model.subtitleOptions.contains { $0.title == "English" } && model.subtitleOptions.contains { $0.title == "Spanish" }, "files named by language")
        check(model.subtitleText == nil, "subtitles are off until chosen")

        // File subtitles: play past the first cue and read the text.
        guard let en = model.subtitleOptions.first(where: { $0.title == "English" }) else { exit(1) }
        model.selectSubtitle(en.id)
        await model.player.seek(to: .zero)
        var shown: String?
        for _ in 0..<60 { try? await Task.sleep(for: .milliseconds(200)); if model.player.currentTime().seconds > 1.3, let t = model.subtitleText { shown = t; break } }
        check(shown == "Hello from the English file", "English cue shown at ~1.3 s: \(shown ?? "nothing")")
        await model.player.seek(to: CMTime(seconds: 4.5, preferredTimescale: 600))
        try? await Task.sleep(for: .milliseconds(500))
        check(model.subtitleText == nil, "no cue between lines (4.5 s)")
        await model.player.seek(to: CMTime(seconds: 5.5, preferredTimescale: 600))
        try? await Task.sleep(for: .milliseconds(500))
        check(model.subtitleText == "Second English line", "second cue, markup removed: \(model.subtitleText ?? "nothing")")

        // Switching language and back to off.
        if let es = model.subtitleOptions.first(where: { $0.title == "Spanish" }) {
            model.selectSubtitle(es.id)
            await model.player.seek(to: CMTime(seconds: 2, preferredTimescale: 600))
            try? await Task.sleep(for: .milliseconds(900))
            check(model.subtitleText == "Hola desde el archivo español", "Spanish cue: \(model.subtitleText ?? "nothing")")
        }
        model.selectSubtitle(nil)
        try? await Task.sleep(for: .milliseconds(400))
        check(model.subtitleText == nil, "off clears the text")

        // The embedded track is handed to AVPlayer's own subtitle display.
        if let emb = model.subtitleOptions.first(where: { if case .embedded = $0.source { return true } else { return false } }) {
            model.selectSubtitle(emb.id)
            try? await Task.sleep(for: .milliseconds(500))
            let item = model.player.currentItem!
            let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            let sel = group.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
            check(sel != nil, "embedded track selected in the player (\(sel?.displayName ?? "none"))")
        }
        // The language is remembered for the next video.
        model.selectSubtitle(en.id)
        check(UserDefaults.standard.string(forKey: "subtitleLanguage") == "en", "language remembered")
        model.stop()
        store.remove([hash], deleteFiles: true)
        print(failures == 0 ? "OK" : "FAILED"); exit(failures == 0 ? 0 : 1)
    }
}
app.run()
