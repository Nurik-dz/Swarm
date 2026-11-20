import AppKit
import CryptoKit
import Network

// Two Swarms in one process: a sender and a receiver, talking over a real TCP connection on this Mac.
// usage: lan <scratch dir>        (set SWARM_STATE_DIR to a scratch folder too)
let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failures += 1 }; fflush(stdout) }

/// A folder's content as relative path -> hash.
func tree(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
    for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        let rel = String(u.path.dropFirst(root.path.count))
        out[rel] = SHA256.hash(data: (try? Data(contentsOf: u)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    return out
}

/// Waits (up to `seconds`) for a condition on the main actor.
@MainActor func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 10) { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
    return cond()
}

MainActor.assumeIsolated {
    Prefs.register()
    let fm = FileManager.default
    try? fm.removeItem(at: scratch); try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    // What will be sent: a folder with three files (about 6 MB).
    let content = scratch.appendingPathComponent("send/Holiday")
    try? fm.createDirectory(at: content.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try? Data("hello from the sender\n".utf8).write(to: content.appendingPathComponent("a.txt"))
    try? Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: content.appendingPathComponent("sub/b.bin"))
    try? Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: content.appendingPathComponent("c.bin"))
    let inbox = scratch.appendingPathComponent("inbox"); try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)

    let senderStore = TorrentStore(stateFolder: scratch.appendingPathComponent("stateA"))
    let receiverStore = TorrentStore(stateFolder: scratch.appendingPathComponent("stateB"))
    senderStore.start(); receiverStore.start()
    senderStore.session.setListenPort(7101); receiverStore.session.setListenPort(7102)
    let sender = LanService(store: senderStore, deviceName: "Sender Mac")
    let receiver = LanService(store: receiverStore, deviceName: "Receiver Mac")

    Task { @MainActor in
        // Not receiving yet: nobody can reach this Mac.
        check(receiver.listeningPort == nil, "receiving is off until switched on")
        receiver.startReceiving(advertise: false)
        guard await wait(5, { receiver.listeningPort != nil }), let port = receiver.listeningPort else { print("no listener"); exit(1) }

        // 1. The person declines.
        sender.send(content, toHost: "127.0.0.1", port: port, named: "Receiver Mac")
        check(await wait(20, { receiver.incoming != nil }), "the offer reaches the receiver")
        if let inc = receiver.incoming {
            check(inc.offer.name == "Holiday" && inc.offer.files == 3, "it shows the folder name and 3 files (from the torrent)")
            check(abs(Int(inc.offer.size) - 6_000_022) < 1000, "and the real size: \(inc.offer.size) bytes")
            check(inc.offer.code == sender.outgoing?.code && inc.offer.code.count == 4, "both Macs show the same four digits: \(inc.offer.code)")
            check(inc.offer.sender == "Sender Mac", "sender name shown")
            check(receiverStore.torrents.isEmpty, "nothing added before the person says yes")
        }
        receiver.declineIncoming()
        check(await wait(10, { if case .declined = sender.outgoing?.state { return true } else { return false } }), "the sender is told it was declined")
        check(receiverStore.torrents.isEmpty, "declined: nothing on the receiver")
        check(await wait(5, { senderStore.torrents.isEmpty }), "declined: the sender stops sharing it")
        sender.dismissOutgoing()

        // 2. The person accepts; the transfer is interrupted halfway and resumes.
        sender.send(content, toHost: "127.0.0.1", port: port, named: "Receiver Mac")
        check(await wait(20, { receiver.incoming != nil }), "second offer reaches the receiver")
        guard let senderHash = senderStore.torrents.first?.id else { print("sender not sharing"); exit(1) }
        senderStore.session.setUploadLimit(1_500_000, forTorrent: senderHash)   // ~4 s for 6 MB, so there is time to interrupt
        let hash = receiver.acceptIncoming(into: inbox)
        check(hash != nil, "accepted: the torrent is added")
        check(await wait(10, { if case .accepted = sender.outgoing?.state { return true } else { return false } }), "the sender is told it was accepted")
        _ = await wait(15, { (receiverStore.torrent(hash ?? "")?.wantedDone ?? 0) > 1_500_000 })
        receiverStore.pause([hash!])
        try? await Task.sleep(for: .seconds(1))
        let partial = receiverStore.torrent(hash!)?.wantedDone ?? 0
        check(partial > 0 && partial < 6_000_000, "interrupted partway (\(partial / 1024) KB of about 5.9 MB)")
        receiverStore.resume([hash!])
        let finished = await wait(60, { receiverStore.torrent(hash!)?.status.isFinished ?? false })
        check(finished, "after the interruption it finishes by itself")
        check(tree(inbox.appendingPathComponent("Holiday")) == tree(content), "every received file is byte-identical to the original")
        check(receiverStore.torrent(hash!)?.savePath == inbox.path, "saved where the person chose")

        // 3. Hostile traffic: nothing reaches the person, nothing is added.
        func poke(_ bytes: Data, hold: Double = 1.0) async {
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            c.start(queue: .main)
            try? await Task.sleep(for: .milliseconds(300))
            c.send(content: bytes, completion: .contentProcessed { _ in })
            try? await Task.sleep(for: .seconds(hold)); c.cancel()
        }
        let before = receiverStore.torrents.count
        await poke(Data("GET / HTTP/1.1\r\n\r\n".utf8))
        await poke(Data([0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3]))
        await poke(try! LanProtocol.frame(LanProtocol.Reply(v: 1, type: "accept", id: UUID().uuidString, reason: nil)))
        await poke(try! LanProtocol.frame(LanProtocol.Offer(v: 1, type: "offer", id: UUID().uuidString, code: "0000", from: "Evil", port: 7000, torrent: Data("not a torrent".utf8))))
        await poke(try! LanProtocol.frame(LanProtocol.Offer(v: 1, type: "offer", id: "x", code: "0000", from: "Evil", port: 7000, torrent: Data())))
        check(receiver.incoming == nil, "garbage, oversize, wrong-type and fake offers never reach the person")
        check(receiverStore.torrents.count == before, "and nothing was added")

        // 4. Switching receiving off closes the door.
        receiver.stopReceiving()
        try? await Task.sleep(for: .milliseconds(500))
        let closed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            var done = false
            c.stateUpdateHandler = { s in
                if done { return }
                switch s { case .ready: done = true; c.cancel(); cont.resume(returning: false)
                           case .failed, .waiting: done = true; c.cancel(); cont.resume(returning: true)
                           default: break }
            }
            c.start(queue: .main)
        }
        check(closed, "with receiving switched off the port refuses connections")

        senderStore.shutDown(); receiverStore.shutDown()
        print(failures == 0 ? "OK" : "FAILED"); exit(failures == 0 ? 0 : 1)
    }
}
app.run()
