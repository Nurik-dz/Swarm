import AppKit
import Network
// Does Bonjour find a Mac advertising Swarm, and does an offer sent to the found device arrive?
// (Needs macOS's local network permission for the program running it.)  usage: bonjour <scratch>
let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failures += 1 }; fflush(stdout) }
MainActor.assumeIsolated {
    Prefs.register()
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let file = scratch.appendingPathComponent("note.txt"); try? Data("hi".utf8).write(to: file)
    let a = TorrentStore(stateFolder: scratch.appendingPathComponent("A")), b = TorrentStore(stateFolder: scratch.appendingPathComponent("B"))
    a.start(); b.start(); a.session.setListenPort(7111); b.session.setListenPort(7112)
    let sender = LanService(store: a, deviceName: "Sender"), receiver = LanService(store: b, deviceName: "Bonjour Receiver")
    sender.includeSelf = true
    Task { @MainActor in
        receiver.startReceiving()                       // advertises
        sender.startBrowsing()
        for _ in 0..<200 where sender.devices.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        check(!sender.devices.isEmpty, "Bonjour found the advertising Mac: \(sender.devices.map(\.name))")
        check(sender.devices.first?.name == "Bonjour Receiver", "with the name it advertises")
        if let d = sender.devices.first {
            sender.send(file, to: d)
            for _ in 0..<200 where receiver.incoming == nil { try? await Task.sleep(for: .milliseconds(100)) }
            check(receiver.incoming?.offer.name == "note.txt", "an offer sent to the found device arrives")
            receiver.declineIncoming()
        }
        sender.stopBrowsing(); receiver.stopReceiving()
        print(failures == 0 ? "OK" : "FAILED"); exit(failures == 0 ? 0 : 1)
    }
}
app.run()
