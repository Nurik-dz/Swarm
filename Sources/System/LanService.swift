import Foundation
import Network
import Observation

/// Sends a file or folder to another Mac on the same network, and receives one. Finding Macs
/// uses Bonjour; the offer travels over one short TCP connection; the transfer itself is a
/// private torrent between the two Swarms (see LanProtocol for what the messages mean).
///
/// Receiving is off until the person turns it on in Settings, and nothing is ever added
/// without their yes. Bonjour finds Macs but proves nothing about who they are: both screens
/// show the same four digits so the person can see an offer is really from their other Mac.
@MainActor
@Observable
final class LanService {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    /// An offer waiting for a yes or a no.
    struct Incoming: Identifiable {
        let id = UUID()
        let offer: LanProtocol.Checked
        let host: String
    }

    enum SendState: Equatable {
        case preparing(Double)          // hashing the pieces
        case asking                     // offer sent, waiting for the answer
        case accepted
        case declined(String)
        case failed(String)

        var isFinished: Bool {
            switch self { case .accepted, .declined, .failed: true; default: false }
        }
    }

    struct Outgoing: Identifiable {
        let id = UUID()
        let path: URL
        let deviceName: String
        var code = ""
        var state: SendState = .preparing(0)
    }

    private(set) var devices: [Device] = []
    private(set) var incoming: Incoming?
    private(set) var outgoing: Outgoing?
    private(set) var listeningPort: UInt16?
    private(set) var receiveError: String?

    /// Tests set this to see their own advertisement.
    var includeSelf = false
    let deviceName: String
    private let instanceID: String
    private let store: TorrentStore
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var pending: (conn: NWConnection, id: String)?
    private var expiry: Task<Void, Never>?
    private var recentOffers: [Date] = []
    private var cancelFlag = CancelFlag()
    private var sendConnection: NWConnection?

    init(store: TorrentStore, deviceName: String? = nil) {
        self.store = store
        self.deviceName = deviceName ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        if let saved = UserDefaults.standard.string(forKey: "lanInstanceID") { instanceID = saved }
        else { instanceID = UUID().uuidString; UserDefaults.standard.set(instanceID, forKey: "lanInstanceID") }
    }

    // MARK: Receiving

    /// Starts advertising this Mac and listening for offers. `port` is for tests; normally any free one.
    func startReceiving(port: NWEndpoint.Port = .any, advertise: Bool = true) {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: port)
            if advertise {
                l.service = NWListener.Service(name: instanceID, type: Self.serviceType, txtRecord: NWTXTRecord(["name": deviceName, "v": "1"]))
            }
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.listeningPort = l.port?.rawValue; self?.receiveError = nil
                    case .failed(let e): self?.receiveError = e.localizedDescription; self?.stopReceiving()
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(connection: conn) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            receiveError = error.localizedDescription
        }
    }

    func stopReceiving() {
        listener?.cancel(); listener = nil; listeningPort = nil
        declineIncoming(reason: "No longer receiving")
    }

    static let serviceType = "_swarmlan._tcp"

    private func accept(connection conn: NWConnection) {
        // One offer at a time; a flood of offers is ignored.
        let now = Date()
        recentOffers.removeAll { now.timeIntervalSince($0) > 60 }
        guard incoming == nil, pending == nil, recentOffers.count < 5 else { conn.cancel(); return }
        recentOffers.append(now)
        conn.start(queue: .main)
        var reader = LanProtocol.Reader()
        let giveUp = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled, self.pending?.conn !== conn, self.incoming == nil { conn.cancel() }
        }
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let data, !data.isEmpty {
                        let frames = reader.feed(data)
                        if reader.failed != nil { conn.cancel(); giveUp.cancel(); return }
                        if let first = frames.first {
                            giveUp.cancel()
                            self.received(offer: first, on: conn)
                            return
                        }
                    }
                    if done || error != nil { conn.cancel(); giveUp.cancel() } else { read() }
                }
            }
        }
        read()
    }

    private func received(offer data: Data, on conn: NWConnection) {
        switch LanProtocol.check(offer: data, describe: { TBMaker.describeTorrentData($0) }) {
        case .failure:
            conn.cancel()   // silence: a stranger learns nothing
        case .success(let offer):
            guard store.torrent(offer.infoHash) == nil else {
                reply("decline", id: offer.id, reason: "Already have it", on: conn); return
            }
            let host = Self.hostString(conn.endpoint)
            pending = (conn, offer.id)
            incoming = Incoming(offer: offer, host: host)
            expiry?.cancel()
            expiry = Task { @MainActor in
                try? await Task.sleep(for: .seconds(LanProtocol.offerLifetime))
                if !Task.isCancelled { self.declineIncoming(reason: "No answer in time") }
            }
            // The sender hanging up cancels the offer.
            conn.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .failed = state { self?.dropPending(ifMatches: conn) }
                    if case .cancelled = state { self?.dropPending(ifMatches: conn) }
                }
            }
        }
    }

    private func dropPending(ifMatches conn: NWConnection) {
        guard pending?.conn === conn else { return }
        pending = nil; incoming = nil; expiry?.cancel()
    }

    /// The person said yes: save into `folder`, connect to the sender, tell the sender.
    @discardableResult
    func acceptIncoming(into folder: URL) -> String? {
        guard let inc = incoming, let p = pending else { return nil }
        expiry?.cancel()
        let hash = store.addLanTransfer(inc.offer.torrent, to: folder, host: inc.host, port: inc.offer.port, infoHash: inc.offer.infoHash)
        reply(hash == nil ? "decline" : "accept", id: inc.offer.id, reason: hash == nil ? "Could not start" : nil, on: p.conn)
        incoming = nil; pending = nil
        return hash
    }

    func declineIncoming(reason: String = "Declined") {
        guard let inc = incoming, let p = pending else { incoming = nil; return }
        expiry?.cancel()
        reply("decline", id: inc.offer.id, reason: reason, on: p.conn)
        incoming = nil; pending = nil
    }

    private func reply(_ type: String, id: String, reason: String?, on conn: NWConnection) {
        guard let data = try? LanProtocol.frame(LanProtocol.Reply(v: LanProtocol.version, type: type, id: id, reason: reason)) else { conn.cancel(); return }
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: Finding Macs

    func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.devices = results.compactMap { r in
                    guard case .service(let id, _, _, _) = r.endpoint else { return nil }
                    if id == self.instanceID && !self.includeSelf { return nil }
                    var name = id
                    if case .bonjour(let txt) = r.metadata, let n = txt["name"] { name = LanProtocol.clean(n, fallback: id) }
                    return Device(id: id, name: name, endpoint: r.endpoint)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopBrowsing() { browser?.cancel(); browser = nil; devices = [] }

    // MARK: Sending

    /// Makes a private torrent of `path`, shares it, offers it to `device`.
    func send(_ path: URL, to device: Device) {
        guard outgoing == nil || outgoing?.state.isFinished == true else { return }
        outgoing = Outgoing(path: path, deviceName: device.name)
        prepare(path, then: .endpoint(device.endpoint))
    }

    /// Hashes the pieces off the main thread, then makes the offer.
    private func prepare(_ path: URL, then target: Target) {
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        let work = outgoing!.id
        Task.detached { [weak self] in
            let (data, problem) = Self.makeTorrent(path, flag: flag) { p in
                Task { @MainActor in if self?.outgoing?.id == work, case .preparing = self?.outgoing?.state { self?.outgoing?.state = .preparing(p) } }
            }
            await MainActor.run {
                guard let self, self.outgoing?.id == work, !flag.isCancelled else { return }
                guard let data else { self.outgoing?.state = .failed(problem ?? "Couldn't prepare the files."); return }
                self.offer(torrent: data, of: path, to: target, work: work)
            }
        }
    }

    nonisolated private static func makeTorrent(_ path: URL, flag: CancelFlag, progress: @escaping (Double) -> Void) -> (Data?, String?) {
        var err: NSString?
        let data = TBMaker.createTorrent(forPath: path.path, isPrivate: true, comment: nil, trackers: [], progress: progress,
                                         shouldCancel: { flag.isCancelled }, error: &err)
        return (data, err as String?)
    }

    /// Where an offer goes. Tests use a plain host and port.
    enum Target { case endpoint(NWEndpoint); case hostPort(String, UInt16) }

    func send(_ path: URL, toHost host: String, port: UInt16, named name: String) {
        guard outgoing == nil || outgoing?.state.isFinished == true else { return }
        outgoing = Outgoing(path: path, deviceName: name)
        prepare(path, then: .hostPort(host, port))
    }

    func cancelSending() {
        cancelFlag.cancel()
        sendConnection?.cancel(); sendConnection = nil
        if let o = outgoing, !o.state.isFinished { outgoing = nil } 
    }

    func dismissOutgoing() { outgoing = nil }

    private func offer(torrent: Data, of path: URL, to target: Target, work: UUID) {
        // Start sharing first, so the receiver can connect the moment it says yes.
        var err: NSString?
        guard let info = TBMaker.describeTorrentData(torrent), let hash = info["hash"] as? String else { outgoing?.state = .failed("Couldn't prepare the files."); return }
        let existing = store.torrent(hash) != nil
        let added = store.session.addTorrentData(torrent, savePath: path.deletingLastPathComponent().path, privateTransfer: true, error: &err)
        guard added != nil || existing else { outgoing?.state = .failed((err as String?) ?? "Couldn't start sharing."); return }
        store.refresh()

        let code = LanProtocol.makeCode()
        outgoing?.code = code
        let message = LanProtocol.Offer(v: LanProtocol.version, type: "offer", id: UUID().uuidString.lowercased(), code: code, from: deviceName,
                                        port: Int(store.session.listenPort()), torrent: torrent)
        guard let frame = try? LanProtocol.frame(message) else {
            outgoing?.state = .failed("That is too many files to send in one go."); stopSharing(hash, existing: existing); return
        }
        let conn: NWConnection
        switch target {
        case .endpoint(let e): conn = NWConnection(to: e, using: .tcp)
        case .hostPort(let h, let p): conn = NWConnection(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
        }
        sendConnection = conn
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(LanProtocol.offerLifetime + 30))
            if !Task.isCancelled, self.outgoing?.id == work, self.outgoing?.state == .asking {
                self.outgoing?.state = .failed("No answer."); conn.cancel(); self.stopSharing(hash, existing: existing)
            }
        }
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.outgoing?.id == work else { return }
                switch state {
                case .ready:
                    self.outgoing?.state = .asking
                    conn.send(content: frame, completion: .contentProcessed { _ in })
                    var reader = LanProtocol.Reader()
                    func read() {
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 12) { data, _, done, error in
                            MainActor.assumeIsolated {
                                guard self.outgoing?.id == work, self.outgoing?.state == .asking else { return }
                                if let data, let first = reader.feed(data).first {
                                    timeout.cancel()
                                    switch LanProtocol.check(reply: first, expecting: message.id) {
                                    case .success(let r) where r.type == "accept": self.outgoing?.state = .accepted
                                    case .success(let r): self.outgoing?.state = .declined(LanProtocol.clean(r.reason ?? "Declined", fallback: "Declined")); self.stopSharing(hash, existing: existing)
                                    case .failure(let f): self.outgoing?.state = .failed(f.text); self.stopSharing(hash, existing: existing)
                                    }
                                    conn.cancel(); return
                                }
                                if done || error != nil { timeout.cancel(); self.outgoing?.state = .failed("The other Mac closed the connection."); self.stopSharing(hash, existing: existing); conn.cancel() }
                                else { read() }
                            }
                        }
                    }
                    read()
                case .failed(let e):
                    timeout.cancel()
                    self.outgoing?.state = .failed("Couldn't reach \(self.outgoing?.deviceName ?? "that Mac"): \(e.localizedDescription)")
                    self.stopSharing(hash, existing: existing)
                default: break
                }
            }
        }
        conn.start(queue: .main)
    }

    /// An offer that was not taken: stop sharing what was only prepared for it.
    private func stopSharing(_ hash: String, existing: Bool) {
        if !existing { store.remove([hash], deleteFiles: false) }
    }

    // MARK: Helpers

    static func hostString(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        var s: String
        switch host {
        case .ipv4(let a): s = "\(a)"
        case .ipv6(let a): s = "\(a)"
        case .name(let n, _): s = n
        @unknown default: s = "\(host)"
        }
        // A scope ("%en0") is kept for link-local IPv6 only.
        if let pct = s.firstIndex(of: "%"), !s.lowercased().hasPrefix("fe80") { s = String(s[..<pct]) }
        return s
    }
}


/// Set from the main thread, read from the hashing thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
