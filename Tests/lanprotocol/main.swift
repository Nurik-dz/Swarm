import Foundation
// Checks the nearby-Mac message rules. build: Tests/lanprotocol/build.sh
var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failed += 1 } }
typealias P = LanProtocol
let torrent = Data("not really a torrent but the stub accepts it".utf8)
let good: ([String: Any]) = ["name": "Holiday Photos", "size": NSNumber(value: 1_500_000), "files": NSNumber(value: 3), "hash": "abc123"]
let describe: (Data) -> [String: Any]? = { $0 == torrent ? good : nil }
func offer(id: String = UUID().uuidString, code: String = "4821", port: Int = 6881, from: String = "Test MacBook", v: Int = 1, type: String = "offer", t: Data = torrent) -> Data {
    try! JSONEncoder().encode(P.Offer(v: v, type: type, id: id, code: code, from: from, port: port, torrent: t))
}

// Framing
let msg = try! P.frame(P.Reply(v: 1, type: "accept", id: "x", reason: nil))
var r = P.Reader()
check(r.feed(msg).count == 1, "one message in one piece")
var r2 = P.Reader(); var got: [Data] = []
for byte in msg { got += r2.feed(Data([byte])) }
check(got.count == 1 && got[0] == msg.dropFirst(4), "one message arriving a byte at a time")
var r3 = P.Reader()
check(r3.feed(msg + msg + msg).count == 3, "three messages glued together")
var r4 = P.Reader(); _ = r4.feed(Data([0xFF, 0xFF, 0xFF, 0xFF]))
check(r4.failed == .tooLarge, "a 4 GB length is refused")
var r5 = P.Reader(); _ = r5.feed(Data([0, 0, 0, 0]))
check(r5.failed == .tooLarge, "a zero length is refused")
var r6 = P.Reader(); _ = r6.feed(Data([0xFF, 0, 0, 0])); check(r6.feed(Data(count: 100)).isEmpty, "nothing more is read after a failure")

// Offers
if case .success(let c) = P.check(offer: offer(), describe: describe) {
    check(c.name == "Holiday Photos" && c.size == 1_500_000 && c.files == 3, "name, size and files come from the torrent")
    check(c.sender == "Test MacBook" && c.code == "4821", "sender and code kept")
} else { check(false, "a good offer is accepted") }
func fails(_ d: Data, _ why: P.Failure, _ what: String) {
    if case .failure(let f) = P.check(offer: d, describe: describe) { check(f == why, what + " (\(f))") } else { check(false, what) }
}
fails(Data("hello".utf8), .malformed, "garbage refused")
fails(offer(type: "reply"), .malformed, "wrong message type refused")
fails(offer(v: 2), .wrongVersion, "other version refused")
fails(offer(id: "not-a-uuid"), .badField("id"), "bad id refused")
fails(offer(code: "12a4"), .badField("code"), "non-digit code refused")
fails(offer(code: "123"), .badField("code"), "short code refused")
fails(offer(port: 80), .badField("port"), "port below 1024 refused")
fails(offer(port: 70000), .badField("port"), "port above 65535 refused")
fails(offer(t: Data()), .notATorrent, "empty torrent refused")
fails(offer(t: Data("junk".utf8)), .notATorrent, "unreadable torrent refused")
let big = ["name": "Big", "size": NSNumber(value: 1), "files": NSNumber(value: 100_001), "hash": "h"] as [String: Any]
if case .failure(let f) = P.check(offer: offer(), describe: { _ in big }) { check(f == .badField("size"), "100,001 files refused") } else { check(false, "100,001 files refused") }

// A lying sender cannot change what the receiver is shown.
let lying = try! JSONSerialization.data(withJSONObject: ["v": 1, "type": "offer", "id": UUID().uuidString, "code": "1111", "from": "Mum", "port": 6881,
    "torrent": torrent.base64EncodedString(), "name": "Tax return.pdf", "size": 5] as [String: Any])
if case .success(let c) = P.check(offer: lying, describe: describe) { check(c.name == "Holiday Photos" && c.size == 1_500_000, "claimed name and size are ignored") } else { check(false, "extra fields ignored") }

// Text from another computer is made safe to show.
check(P.clean("Mac\u{202E}gpj.exe", fallback: "?") == "Macgpj.exe", "direction override removed")
check(P.clean("a\nb\tc", fallback: "?") == "abc", "line breaks and tabs removed")
check(P.clean("   ", fallback: "Another Mac") == "Another Mac", "empty name replaced")
check(P.clean(String(repeating: "x", count: 500), fallback: "?").count == 120, "long name cut to 120")

// Replies
let id = UUID().uuidString
let ok = try! JSONEncoder().encode(P.Reply(v: 1, type: "accept", id: id.lowercased(), reason: nil))
if case .success = P.check(reply: ok, expecting: id) { check(true, "reply with the right id accepted") } else { check(false, "reply with the right id accepted") }
if case .failure = P.check(reply: ok, expecting: UUID().uuidString) { check(true, "reply for another offer refused") } else { check(false, "reply for another offer refused") }
let weird = try! JSONEncoder().encode(P.Reply(v: 1, type: "shutdown", id: id, reason: nil))
if case .failure = P.check(reply: weird, expecting: id) { check(true, "unknown reply type refused") } else { check(false, "unknown reply type refused") }
exit(failed == 0 ? 0 : 1)
