import AppKit
import CryptoKit

// Swarm Verify: an existing copy with three damaged pieces is checked, the good parts are
// reused, only the damaged ones download, and the end result is byte-identical.
// usage: verify <dir with test.torrent and seed/> <scratch dir> <seed-state-dir>   (needs Tests/stream/make_fixtures.sh)
let base = CommandLine.arguments[1], scratch = CommandLine.arguments[2], seedState = CommandLine.arguments[3]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failures += 1 }; fflush(stdout) }
func sha(_ url: URL) -> String { SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined() }

MainActor.assumeIsolated {
    Prefs.register()
    let fm = FileManager.default
    let original = URL(fileURLWithPath: base + "/seed/test.m4b")
    let dl = URL(fileURLWithPath: scratch + "/downloads"), existing = URL(fileURLWithPath: scratch + "/existing"), junk = URL(fileURLWithPath: scratch + "/junk")
    for d in [dl, existing, junk] { try? fm.removeItem(at: d); try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    Prefs.folder = dl
    // The "copy you already have": same file, three pieces (256 KB each) damaged.
    var bytes = (try? Data(contentsOf: original)) ?? Data()
    let total = bytes.count
    for piece in [10, 40, 70] { for i in 0..<64 { bytes[piece * 262_144 + 1000 + i] ^= 0xFF } }
    try? bytes.write(to: existing.appendingPathComponent("test.m4b"))
    try? Data(count: total).write(to: junk.appendingPathComponent("test.m4b"))   // same name, all zeros

    let seeder = TBSession(stateFolder: seedState)
    seeder.setListenPort(6997)
    var err: NSString?
    guard let seedHash = seeder.addTorrentFile(base + "/test.torrent", savePath: base + "/seed", startPaused: false, error: &err) else { print("seed failed"); exit(1) }
    let store = AppModel.shared.store
    store.start()
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        // Chosen files, paused: nothing downloads yet.
        guard let hash = store.add(file: URL(fileURLWithPath: base + "/test.torrent"), chooseFiles: true) else { print("add failed"); exit(1) }
        precondition(hash == seedHash)
        let addFlow = ProcessInfo.processInfo.environment["ADD_FLOW"] == "1"   // point at the folder BEFORE pressing Download
        if !addFlow { store.start(hash, files: [0]); store.pause([hash]) }

        // Dropping the file, or the folder that holds it, finds the torrent.
        let byFile = store.torrentsMatching(existing.appendingPathComponent("test.m4b"))
        let byFolder = store.torrentsMatching(existing)
        check(byFile.count == 1 && byFile[0].folder.path == existing.path, "dropped file matches its torrent, folder = its parent")
        check(byFolder.count == 1 && byFolder[0].folder.path == existing.path, "dropped folder that holds the file matches too")
        check(store.torrentsMatching(URL(fileURLWithPath: "/tmp/not-a-torrent-name")).isEmpty, "unrelated name matches nothing")

        // 1. Nothing in the folder matches: say so.
        store.useExistingFiles(hash, at: junk)
        for _ in 0..<80 where store.problem == nil { try? await Task.sleep(for: .milliseconds(250)); store.refresh() }
        if !addFlow { check(store.problem?.message.contains("Nothing in") == true, "all-zero file: \(store.problem?.message ?? "no message")") }
        store.problem = nil

        // 2. The real copy with three damaged pieces.
        store.useExistingFiles(hash, at: existing)
        for _ in 0..<80 where store.problem == nil && !(addFlow && (store.torrent(hash)?.status == .choosingFiles)) { try? await Task.sleep(for: .milliseconds(250)); store.refresh() }
        if addFlow {
            try? await Task.sleep(for: .seconds(4))   // let the check run while nothing is chosen yet
            store.start(hash, files: [0]); store.pause([hash])
            for _ in 0..<60 { try? await Task.sleep(for: .milliseconds(250)); store.refresh() }
        }
        let t = store.torrent(hash)!
        print("message:", store.problem?.message ?? "none")
        let missing = t.chosenSize - min(t.wantedDone, t.chosenSize)
        check(t.savePath == existing.path, "torrent now points at the folder you chose")
        check(missing >= 3 * 262_144 - 100 && missing <= 5 * 262_144, "about three pieces missing after the check (\(missing / 1024) KB)")
        if !addFlow { check(store.problem?.message.contains("Reused") == true, "message says what was reused") }
        store.problem = nil

        // 3. Download only what is missing.
        store.resume([hash])
        try? await Task.sleep(for: .seconds(1))
        Task { @MainActor in for _ in 0..<60 where (store.torrent(hash)?.peers ?? 0) == 0 { store.session.connectPeer("127.0.0.1", port: 6997, forTorrent: hash); try? await Task.sleep(for: .seconds(2)) } }
        for i in 0..<240 where !(store.torrent(hash)?.status.isFinished ?? false) {
            try? await Task.sleep(for: .milliseconds(250)); store.refresh()
            if i % 20 == 0, let x = store.torrent(hash) { print("[diag] status=\(x.status) peers=\(x.peers) known=\(x.knownPeers) done=\(x.wantedDone)/\(x.chosenSize) rate=\(x.downRate) seeder=\(seeder.torrents().first.map { "\($0.state.rawValue) peers=\($0.peers)" } ?? "-")") }
        }
        let done = store.torrent(hash)!
        check(done.status.isFinished, "download finished (\(done.status))")
        check(done.downloaded < 2_000_000, "fetched only the damaged parts: \(done.downloaded / 1024) KB of \(total / 1024) KB")
        check(sha(existing.appendingPathComponent("test.m4b")) == sha(original), "the repaired file is byte-identical to the original")
        // Only when pointed BEFORE starting (the Add window): a torrent that already ran leaves its
        // partial data behind in the old folder, and Swarm never deletes real data.
        if addFlow { check(!fm.fileExists(atPath: dl.appendingPathComponent("test.m4b").path), "nothing was written to the default folder") }
        store.remove([hash], deleteFiles: false)
        print(failures == 0 ? "OK" : "FAILED"); exit(failures == 0 ? 0 : 1)
    }
}
app.run()
