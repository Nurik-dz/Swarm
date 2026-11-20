import Foundation

/// What two Swarms say to each other to hand a file or folder over on the same network.
/// Nothing here touches the disk or a torrent: it only decides what a message means, and
/// refuses anything that does not look exactly right.
///
/// The flow: the sender makes a torrent of what it wants to send and starts sharing it,
/// then sends an Offer carrying that torrent. The receiver shows who, what and how big
/// (taken from the torrent itself, never from what the sender claims) and waits for a yes.
/// Only after a yes does it add the torrent and connect to the sender; the torrent protocol
/// does the transfer, checks every piece, and picks up where it stopped after an interruption.
enum LanProtocol {
    static let version = 1
    /// Largest message accepted. A torrent for 100,000 files is a few MB.
    static let maxFrame = 8 << 20
    /// The receiver answers within this time or the offer is dropped.
    static let offerLifetime: TimeInterval = 120
    static let maxFiles = 100_000

    // MARK: Messages

    struct Offer: Codable, Equatable {
        var v: Int
        var type: String            // "offer"
        var id: String              // a UUID, chosen by the sender
        var code: String            // four digits shown on both Macs to compare
        var from: String            // the sender Mac's name (shown, not trusted)
        var port: Int               // where the sender's torrent engine listens
        var torrent: Data           // the .torrent
    }

    struct Reply: Codable, Equatable {
        var v: Int
        var type: String            // "accept" or "decline"
        var id: String
        var reason: String?
    }

    static func makeCode() -> String { String(format: "%04d", Int.random(in: 0...9999)) }

    // MARK: Framing: 4 bytes of length (big endian), then JSON

    static func frame<T: Encodable>(_ message: T) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= maxFrame else { throw Failure.tooLarge }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Cuts a stream of bytes into messages as they arrive, whatever size the pieces come in.
    struct Reader {
        private var buffer = Data()
        private(set) var failed: Failure?

        /// Adds bytes; returns every complete message now available.
        mutating func feed(_ data: Data) -> [Data] {
            guard failed == nil else { return [] }
            buffer.append(data)
            var out: [Data] = []
            while buffer.count >= 4 {
                let n = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                if n == 0 || n > UInt32(LanProtocol.maxFrame) { failed = .tooLarge; buffer = Data(); return out }
                guard buffer.count >= 4 + Int(n) else { break }
                out.append(buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + Int(n)))
                buffer = Data(buffer.dropFirst(4 + Int(n)))
            }
            return out
        }
    }

    enum Failure: Error, Equatable {
        case tooLarge, malformed, wrongVersion, badField(String), notATorrent, mismatch
        var text: String {
            switch self {
            case .tooLarge: "The message was too large."
            case .malformed: "The message was not understood."
            case .wrongVersion: "That Mac uses a different version of Swarm."
            case .badField(let f): "The offer had an invalid \(f)."
            case .notATorrent: "The offer did not contain a valid torrent."
            case .mismatch: "The offer did not match what it contained."
            }
        }
    }

    // MARK: Checking an offer

    /// An offer that passed every check, with the facts taken from the torrent.
    struct Checked: Equatable {
        let id: String
        let code: String
        let sender: String
        let port: Int
        let torrent: Data
        let name: String
        let size: Int64
        let files: Int
        let infoHash: String
    }

    /// `describe` reads a torrent's name, size, file count and hash (the bridge does this).
    static func check(offer data: Data, describe: (Data) -> [String: Any]?) -> Result<Checked, Failure> {
        guard let o = try? JSONDecoder().decode(Offer.self, from: data), o.type == "offer" else { return .failure(.malformed) }
        guard o.v == version else { return .failure(.wrongVersion) }
        guard UUID(uuidString: o.id) != nil else { return .failure(.badField("id")) }
        guard o.code.count == 4, o.code.allSatisfy(\.isASCII), o.code.allSatisfy(\.isNumber) else { return .failure(.badField("code")) }
        guard (1024...65535).contains(o.port) else { return .failure(.badField("port")) }
        guard !o.torrent.isEmpty, o.torrent.count <= maxFrame else { return .failure(.notATorrent) }
        guard let d = describe(o.torrent), let name = d["name"] as? String, let size = (d["size"] as? NSNumber)?.int64Value,
              let files = (d["files"] as? NSNumber)?.intValue, let hash = d["hash"] as? String else { return .failure(.notATorrent) }
        guard files >= 1, files <= maxFiles, size >= 0 else { return .failure(.badField("size")) }
        return .success(Checked(id: o.id.lowercased(), code: o.code, sender: clean(o.from, fallback: "Another Mac"), port: o.port,
                                torrent: o.torrent, name: clean(name, fallback: "Unnamed"), size: size, files: files, infoHash: hash))
    }

    static func check(reply data: Data, expecting id: String) -> Result<Reply, Failure> {
        guard let r = try? JSONDecoder().decode(Reply.self, from: data), r.type == "accept" || r.type == "decline" else { return .failure(.malformed) }
        guard r.v == version else { return .failure(.wrongVersion) }
        guard r.id.lowercased() == id.lowercased() else { return .failure(.badField("id")) }
        return .success(r)
    }

    /// Text that came from another computer, made safe to show: no control or direction-changing
    /// characters, no line breaks, a sensible length.
    static func clean(_ s: String, fallback: String) -> String {
        let bad: Set<Unicode.Scalar> = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200E}", "\u{200F}"]
        var scalars = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !bad.contains($0) }
        if scalars.count > 120 { scalars = Array(scalars.prefix(120))[...].map { $0 }.reduce(into: String.UnicodeScalarView()) { $0.append($1) } }
        let out = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? fallback : out
    }
}
