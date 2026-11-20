import Foundation

// Step 0: can Swift drive libtorrent on this Mac? Magnet -> file list ->
// choose one file -> download -> save state -> restore in a new session.
let root = CommandLine.arguments[1]
let state = root + "/state", save = root + "/downloads"
let magnet = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Fexplodie.org%3A6969&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce&tr=wss%3A%2F%2Ftracker.openwebtorrent.com&ws=https%3A%2F%2Fwebtorrent.io%2Ftorrents%2F&xs=https%3A%2F%2Fwebtorrent.io%2Ftorrents%2Fbig-buck-bunny.torrent"

func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func line(_ s: String) { print(String(format: "[%6.1fs] ", Date().timeIntervalSince(start)) + s); fflush(stdout) }
let start = Date()

let session = TBSession(stateFolder: state)
var err: NSString?
guard let hash = session.addMagnet(magnet, savePath: save, startPaused: true, error: &err) else {
    print("add failed:", err ?? ""); exit(1)
}
line("added \(hash)")

// 1. Wait for the file list.
var files: [TBFile] = []
for _ in 0..<240 {
    spin(0.5)
    let ev = session.popEvents()
    if ev.gotMetadata.contains(hash) { files = session.files(forTorrent: hash); break }
    if let t = session.torrents().first { if Int(Date().timeIntervalSince(start)) % 5 == 0 { line("state \(t.state.rawValue) peers \(t.peers)") } }
}
guard !files.isEmpty else { line("NO METADATA"); exit(2) }
let t0 = session.torrents()[0]
line("metadata: '\(t0.name)' \(t0.fileCount) files, state=\(t0.state.rawValue) (7 = waiting for a choice) paused=\(t0.isPaused)")
for f in files { line("  [\(f.index)] \(f.path)  \(f.size) bytes  wanted=\(f.wanted)") }

// 2. Choose only the .mp4 and start.
let mp4 = files.filter { $0.path.hasSuffix(".mp4") }.map { NSNumber(value: $0.index) }
session.setWanted(mp4, forTorrent: hash)
session.resume(hash)
var finished = false
for i in 0..<360 {
    spin(0.5)
    let ev = session.popEvents()
    if !ev.errors.isEmpty { line("errors: \(ev.errors)") }
    if ev.finished.contains(hash) { finished = true }
    let t = session.torrents()[0]
    if i % 4 == 0 || finished {
        line(String(format: "state=%d %.1f%%  %lld/%lld  down %.1f MB/s  peers %d seeds %d",
                    t.state.rawValue, t.progress * 100, t.totalWantedDone, t.totalWanted,
                    Double(t.downloadRate) / 1_048_576, t.peers, t.seeds))
    }
    if finished { break }
}
line("finished=\(finished)")
session.saveAllAndWait(10)
line("saved; state folder: \((try? FileManager.default.contentsOfDirectory(atPath: state)) ?? [])")
let onDisk = (FileManager.default.enumerator(atPath: save)?.allObjects as? [String]) ?? []
line("on disk: \(onDisk)")

// 3. A fresh session restores it from the saved state.
let again = TBSession(stateFolder: state + "-copy")
_ = again
try? FileManager.default.copyItem(atPath: state, toPath: state + "-copy2")
let restored = TBSession(stateFolder: state + "-copy2")
restored.restoreTorrents()
spin(3)
if let r = restored.torrents().first {
    line(String(format: "restored: '%@' state=%d progress %.1f%% wanted %lld", r.name, r.state.rawValue, r.progress * 100, r.totalWanted))
} else {
    line("restore FAILED")
}
