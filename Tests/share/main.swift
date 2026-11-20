import AppKit
import CryptoKit

// Swarm Share: make a link for a folder, a second Swarm downloads it from the magnet link alone.
// usage: share <scratch dir>   (set SWARM_STATE_DIR to a scratch folder too)
let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failures += 1 }; fflush(stdout) }
func tree(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
    for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        out[String(u.path.dropFirst(root.path.count))] = SHA256.hash(data: (try? Data(contentsOf: u)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    return out
}
@MainActor func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 10) { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
    return cond()
}

MainActor.assumeIsolated {
    Prefs.register()
    let fm = FileManager.default
    try? fm.removeItem(at: scratch); try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    let content = scratch.appendingPathComponent("mine/Report")
    try? fm.createDirectory(at: content.appendingPathComponent("data"), withIntermediateDirectories: true)
    try? Data("summary\n".utf8).write(to: content.appendingPathComponent("summary.txt"))
    try? Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: content.appendingPathComponent("data/numbers.bin"))
    let inbox = scratch.appendingPathComponent("inbox"); try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
    Prefs.folder = inbox

    let mine = TorrentStore(stateFolder: scratch.appendingPathComponent("stateA"))
    let theirs = TorrentStore(stateFolder: scratch.appendingPathComponent("stateB"))
    mine.start(); theirs.start()
    mine.session.setListenPort(7201); theirs.session.setListenPort(7202)

    Task { @MainActor in
        // 1. Make the link.
        let job = ShareJob(path: content)
        check(ShareSheet.measure(content) == (2, 2_000_008), "the sheet counts the real files and size")
        job.start(store: mine)
        check(await wait(30, { if case .ready = job.state { return true } else if case .failed = job.state { return true } else { return false } }), "hashing finishes")
        guard case .ready(let hash) = job.state else { print("not ready: \(job.state)"); exit(1) }
        check(mine.torrent(hash) != nil, "it is in the list")
        _ = await wait(10, { mine.torrent(hash)?.status == .sharing })
        check(mine.torrent(hash)?.status == .sharing, "and sharing (\(String(describing: mine.torrent(hash)?.status)))")
        let magnet = mine.magnet(hash) ?? ""
        check(magnet.hasPrefix("magnet:?xt=urn:btih:") && magnet.contains("dn=Report"), "magnet link has the hash and the name")
        let info = job.torrentData.flatMap { TBMaker.describeTorrentData($0) }
        check(info?["files"] as? Int == 2 && info?["private"] as? Bool == false, "the .torrent describes 2 files and is public")

        // 2. Someone else downloads it with only the link.
        guard let got = theirs.add(magnet: magnet, chooseFiles: false) else { print("add failed"); exit(1) }
        Task { @MainActor in for _ in 0..<40 where (theirs.torrent(got)?.peers ?? 0) == 0 { theirs.session.connectPeer("127.0.0.1", port: 7201, forTorrent: got); try? await Task.sleep(for: .seconds(2)) } }
        check(await wait(60, { theirs.torrent(got)?.status.isFinished ?? false }), "a second Swarm finishes it from the magnet link alone")
        check(tree(inbox.appendingPathComponent("Report")) == tree(content), "every file is byte-identical")

        // 3. It keeps sharing: the "stop at ratio 1" rule is for downloads.
        try? await Task.sleep(for: .seconds(8))
        let me = mine.torrent(hash)
        check(me?.status == .sharing && me?.ratio ?? 0 >= 0.9, "still sharing after the other side has everything (ratio \(String(format: "%.2f", me?.ratio ?? 0)))")

        // 4. Trackers and private option.
        let job2 = ShareJob(path: content.appendingPathComponent("data"))
        job2.trackers = "http://tracker.example.invalid/announce\nudp://other.example.invalid:6969"
        job2.makePrivate = true
        check(job2.trackerList.count == 2, "tracker list parsed")
        job2.start(store: mine)
        _ = await wait(30, { if case .ready = job2.state { return true } else { return false } })
        if case .ready(let h2) = job2.state {
            let m2 = mine.magnet(h2) ?? ""
            let low = m2.lowercased()
            check(low.contains("tr=http%3a%2f%2ftracker.example.invalid") && low.contains("tr=udp%3a%2f%2fother.example.invalid"), "the magnet link carries both trackers")
            check(job2.torrentData.flatMap { TBMaker.describeTorrentData($0) }?["private"] as? Bool == true, "private torrent when asked for")
        } else { check(false, "second job ready") }

        // 5. Cancelling while hashing leaves nothing behind.
        let big = scratch.appendingPathComponent("mine/Big"); try? fm.createDirectory(at: big, withIntermediateDirectories: true)
        fm.createFile(atPath: big.appendingPathComponent("zeros.bin").path, contents: nil)
        if let h = try? FileHandle(forWritingTo: big.appendingPathComponent("zeros.bin")) { try? h.truncate(atOffset: 3_000_000_000); try? h.close() }   // sparse: 3 GB takes a few seconds to hash
        let before = mine.torrents.count
        let job3 = ShareJob(path: big); job3.start(store: mine)
        try? await Task.sleep(for: .milliseconds(150)); job3.stop()
        try? await Task.sleep(for: .seconds(3))
        check(mine.torrents.count == before, "cancelled while hashing: nothing was added")

        // 6. Finder's Services entry.
        let pb = NSPasteboard(name: NSPasteboard.Name("swarm-test"))
        pb.clearContents(); pb.writeObjects([content as NSURL])
        var err: NSString = ""
        ServiceProvider.shared.shareFiles(pb, userData: nil, error: &err)
        check(AppModel.shared.shareJob?.path.path == content.path, "the Services handler opens the share window for the chosen item")
        pb.clearContents()
        var err2: NSString = ""
        ServiceProvider.shared.shareFiles(pb, userData: nil, error: &err2)
        check(err2.length > 0, "an empty selection gives a message, not a crash")

        mine.shutDown(); theirs.shutDown()
        print(failures == 0 ? "OK" : "FAILED"); exit(failures == 0 ? 0 : 1)
    }
}
app.run()
