import Foundation
import AppKit
import Observation

/// Owns the libtorrent session and everything the windows show about it.
@MainActor
@Observable
final class TorrentStore {
    private(set) var torrents: [Torrent] = []
    /// Total speed over the last two minutes, one sample a second.
    private(set) var history: [(down: Int64, up: Int64)] = []
    var problem: Problem?
    /// What connected peers can still give each running download (sampled every 3 s).
    private(set) var health: [String: HealthSnapshot] = [:]
    /// What Swarm did by itself to help a stalled download, newest last.
    private(set) var rescueLog: [String: [String]] = [:]

    struct Problem: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    /// Called when a torrent finishes downloading while the app runs.
    var onFinished: ((Torrent) -> Void)?
    /// Called when a torrent's file list arrives (to show the file chooser).
    var onFileList: ((String) -> Void)?

    let session: TBSession
    private var timer: Timer?
    private var samples: [String: [(time: Date, done: Int64)]] = [:]
    /// When each download entered its start-up phase (no data yet).
    private var startingSince: [String: Date] = [:]
    /// When each running download last stopped receiving data.
    private var idleSince: [String: Date] = [:]
    private var lastHealthCheck = Date.distantPast
    private var lastReannounce: [String: Date] = [:]
    private var reannounceCount: [String: Int] = [:]
    private var lastErrors: [String: String] = [:]
    /// Finished torrents the person chose to keep sharing by hand.
    private var sharingByChoice: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sharingByChoice") ?? []) {
        didSet { UserDefaults.standard.set(Array(sharingByChoice), forKey: "sharingByChoice") }
    }

    /// Tests give each store its own folder so two can run side by side.
    init(stateFolder: URL? = nil) {
        let folder = stateFolder ?? Prefs.stateFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        session = TBSession(stateFolder: folder.path)
    }

    // MARK: Sharing your own files

    /// Starts sharing a torrent made from files you have, and keeps sharing until you stop it
    /// (the usual "stop at ratio 1" rule is for downloads, not for something you chose to share).
    @discardableResult
    func addShared(_ torrent: Data, folder: URL) -> String? {
        var error: NSString?
        let hash = session.addTorrentData(torrent, savePath: folder.path, privateTransfer: false, error: &error)
        guard let hash else { problem = Problem(title: "Couldn't start sharing", message: (error as String?) ?? "Unknown problem."); return nil }
        sharingByChoice.insert(hash)
        refresh()
        return hash
    }

    // MARK: Transfers from a nearby Mac

    /// Where each nearby-Mac transfer comes from, so it can reconnect after an interruption
    /// (these torrents are private: nothing else would find the sender again).
    private(set) var lanSources: [String: String] = UserDefaults.standard.dictionary(forKey: "lanSources") as? [String: String] ?? [:]
    private var lastLanReconnect = Date.distantPast

    /// Adds the torrent from an accepted offer and connects straight to the sender.
    @discardableResult
    func addLanTransfer(_ torrent: Data, to folder: URL, host: String, port: Int, infoHash: String) -> String? {
        var error: NSString?
        let hash = session.addTorrentData(torrent, savePath: folder.path, privateTransfer: true, error: &error)
        guard let hash else { problem = Problem(title: "Couldn't receive the files", message: (error as String?) ?? "Unknown problem."); return nil }
        lanSources[hash] = "\(host)|\(port)"
        UserDefaults.standard.set(lanSources, forKey: "lanSources")
        session.connectPeer(host, port: Int32(port), forTorrent: hash)
        refresh()
        return hash
    }

    /// Every 10 s: a nearby-Mac download with nobody connected asks its sender again.
    private func reconnectLanSources(_ list: [Torrent], now: Date) {
        guard !lanSources.isEmpty, now.timeIntervalSince(lastLanReconnect) >= 10 else { return }
        lastLanReconnect = now
        for t in list where t.status == .downloading && t.peers == 0 {
            guard let src = lanSources[t.id]?.split(separator: "|"), src.count == 2, let port = Int32(src[1]) else { continue }
            session.connectPeer(String(src[0]), port: port, forTorrent: t.id)
        }
        // Finished transfers no longer need an address.
        let done = Set(list.filter { $0.status.isFinished }.map(\.id))
        if lanSources.keys.contains(where: done.contains) {
            for id in done { lanSources[id] = nil }
            UserDefaults.standard.set(lanSources, forKey: "lanSources")
        }
    }

    func start() {
        session.restoreTorrents()
        applyLimits()
        session.setListenPort(Int32(Prefs.port))
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.2
    }

    func shutDown() {
        timer?.invalidate()
        session.saveAllAndWait(4)
    }

    // MARK: Refresh

    func refresh() {
        let events = session.popEvents()
        let now = Date()
        var list = session.torrents().map(Torrent.init)
        for i in list.indices {
            if list[i].error == nil, let e = lastErrors[list[i].id] { list[i].error = e }
        }
        list.sort { $0.added > $1.added }
        if list != torrents { torrents = list }   // no redraw when nothing changed

        for t in list {
            if t.isStarting {
                if startingSince[t.id] == nil { startingSince[t.id] = now }
            } else {
                startingSince[t.id] = nil
            }
            if t.status == .downloading && !t.isStarting && t.downRate < 1024 {
                if idleSince[t.id] == nil { idleSince[t.id] = now }
            } else {
                idleSince[t.id] = nil
            }
            if t.status == .downloading {
                var s = samples[t.id, default: []]
                s.append((now, t.wantedDone))
                s.removeAll { now.timeIntervalSince($0.time) > 60 }
                samples[t.id] = s
            } else {
                samples[t.id] = nil
            }
        }
        let sample = (down: list.reduce(Int64(0)) { $0 + $1.downRate }, up: list.reduce(Int64(0)) { $0 + $1.upRate })
        // A flat line needs no new frame: only record while something moves.
        if sample.down > 0 || sample.up > 0 || history.contains(where: { $0.down > 0 || $0.up > 0 }) {
            history.append(sample)
            if history.count > 120 { history.removeFirst(history.count - 120) }
        }

        for line in events.errors {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { lastErrors[parts[0]] = parts[1] }
        }
        for hash in events.gotMetadata { onFileList?(hash) }
        for hash in events.checked where verifying[hash] != nil { verifying[hash]?.checked = true }
        for hash in events.finished {
            if let t = torrents.first(where: { $0.id == hash }) {
                onFinished?(t)
                if Prefs.afterDone == .stop { session.pause(hash) }
            }
        }
        enforceSharingRule()
        updateHealth(list, now: now)
        checkSchedule()
        finishVerifying(list, now: now)
        reconnectLanSources(list, now: now)
    }

    // MARK: Health and rescue

    /// Every 3 s, for downloads that have their file list: how much of what is
    /// left the connected peers offer. Then the bounded automatic help.
    private func updateHealth(_ list: [Torrent], now: Date) {
        guard now.timeIntervalSince(lastHealthCheck) >= 3 else { return }
        lastHealthCheck = now
        var next: [String: HealthSnapshot] = [:]
        for t in list where t.status == .downloading && t.hasFileList && !t.isStarting {
            if let h = session.health(forTorrent: t.id) { next[t.id] = HealthSnapshot(h) }
        }
        if next != health { health = next }
        for t in list { autoRescue(t, now: now) }
    }

    /// Asks the trackers again when a download has been silent with nobody
    /// connected: first after 60 s, then at most every 10 min, 5 times in all.
    private func autoRescue(_ t: Torrent, now: Date) {
        guard t.status == .downloading, t.peers == 0, let since = idleSince[t.id],
              now.timeIntervalSince(since) >= 60,
              reannounceCount[t.id, default: 0] < 5 else { return }
        if let last = lastReannounce[t.id], now.timeIntervalSince(last) < 600 { return }
        session.reannounce(t.id)
        lastReannounce[t.id] = now
        reannounceCount[t.id, default: 0] += 1
        log(t.id, "Asked the trackers again (nobody was connected for \(Int(now.timeIntervalSince(since))) s)")
    }

    private func log(_ id: String, _ line: String) {
        var l = rescueLog[id, default: []]
        l.append(Date().formatted(date: .omitted, time: .shortened) + "  " + line)
        if l.count > 20 { l.removeFirst(l.count - 20) }
        rescueLog[id] = l
    }

    func diagnosis(for t: Torrent) -> Diagnosis? {
        Rescue.diagnose(t, health: health[t.id], idleFor: idleSince[t.id].map { Date().timeIntervalSince($0) } ?? 0,
                        free: Rescue.freeSpace(at: t.savePath))
    }

    /// Read on demand for the torrent being looked at, not on every refresh.
    func peers(of id: String) -> [Peer] { session.peers(forTorrent: id).map(Peer.init) }

    struct PieceMap { let pieceCount: Int; let have: [Double]; let wanted: [Double] }

    func pieceMap(of id: String) -> PieceMap? {
        guard let m = session.pieceMap(forTorrent: id, buckets: 400) else { return nil }
        return PieceMap(pieceCount: Int(m.pieceCount), have: m.have.map(\.doubleValue), wanted: m.wanted.map(\.doubleValue))
    }

    func askTrackersAgain(_ id: String) {
        session.reannounce(id)
        lastReannounce[id] = Date()
        log(id, "You asked the trackers again")
    }

    /// "Share until uploaded as much as downloaded": stop at ratio 1.
    private func enforceSharingRule() {
        guard Prefs.afterDone == .shareFairly else {
            if Prefs.afterDone == .stop {
                for t in torrents where t.status == .sharing && !sharingByChoice.contains(t.id) { session.pause(t.id) }
            }
            return
        }
        for t in torrents where t.status == .sharing && t.ratio >= 1 && !sharingByChoice.contains(t.id) {
            session.pause(t.id)
        }
    }

    // MARK: Reading

    func torrents(in shelf: Shelf, matching search: String) -> [Torrent] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return torrents.filter { shelf.contains($0) && (q.isEmpty || $0.displayName.lowercased().contains(q)) }
    }

    func count(_ shelf: Shelf) -> Int { torrents.lazy.filter { shelf.contains($0) }.count }

    func torrent(_ id: String) -> Torrent? { torrents.first { $0.id == id } }

    func files(of id: String) -> [TorrentFile] { session.files(forTorrent: id).map(TorrentFile.init) }

    /// From the speed over the last minute, after 5 seconds of measuring.
    func timeLeft(_ t: Torrent) -> Double? {
        guard t.status == .downloading, t.wanted > t.wantedDone,
              let s = samples[t.id], let first = s.first, let last = s.last else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        guard span >= 5, last.done > first.done else { return nil }
        let speed = Double(last.done - first.done) / span
        return Double(t.wanted - t.wantedDone) / speed
    }

    var downRate: Int64 { torrents.reduce(0) { $0 + $1.downRate } }
    var upRate: Int64 { torrents.reduce(0) { $0 + $1.upRate } }
    var activeCount: Int { torrents.filter { $0.status.isActive }.count }

    /// Progress across everything downloading, for the Dock and menu bar.
    var overallProgress: Double? {
        let active = torrents.filter { $0.status == .downloading && $0.wanted > 0 }
        guard !active.isEmpty else { return nil }
        let done = active.reduce(Int64(0)) { $0 + $1.wantedDone }
        let all = active.reduce(Int64(0)) { $0 + $1.wanted }
        return Double(done) / Double(all)
    }

    var canPauseAll: Bool { torrents.contains { $0.canPause } }
    var canResumeAll: Bool { torrents.contains { $0.canResume } }

    // MARK: Adding

    /// Returns the info hash, or nil after reporting the problem.
    @discardableResult
    func add(magnet: String, chooseFiles: Bool) -> String? {
        var error: NSString?
        let hash = session.addMagnet(magnet, savePath: Prefs.folder.path, startPaused: chooseFiles, error: &error)
        return finishAdding(hash, error)
    }

    @discardableResult
    func add(file: URL, chooseFiles: Bool) -> String? {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        var error: NSString?
        let hash = session.addTorrentFile(file.path, savePath: Prefs.folder.path, startPaused: chooseFiles, error: &error)
        return finishAdding(hash, error)
    }

    private func finishAdding(_ hash: String?, _ error: NSString?) -> String? {
        refresh()
        if let error, hash == nil {
            problem = Problem(title: "Couldn't add the torrent", message: error as String)
            return nil
        }
        if let error, let hash {
            // Already in the list: say so, and point at it.
            problem = Problem(title: "Already added", message: error as String)
            return hash
        }
        return hash
    }

    // MARK: Actions

    func start(_ id: String, files wanted: [Int]) {
        session.setWanted(wanted.map { NSNumber(value: $0) }, forTorrent: id)
        session.resume(id)
        refresh()
    }

    func startAll(_ id: String) { session.startAll(id); refresh() }

    func setWanted(_ id: String, files wanted: [Int]) {
        session.setWanted(wanted.map { NSNumber(value: $0) }, forTorrent: id)
        refresh()
    }

    func pause(_ ids: [String]) { ids.forEach(session.pause); refresh() }

    func resume(_ ids: [String]) {
        for id in ids {
            lastErrors[id] = nil
            if torrent(id)?.status.isFinished == true { sharingByChoice.insert(id) }
            session.resume(id)
        }
        refresh()
    }

    /// Seconds a download has been waiting for its first data.
    func startingFor(_ t: Torrent) -> TimeInterval {
        startingSince[t.id].map { Date().timeIntervalSince($0) } ?? 0
    }

    func stopSharing(_ ids: [String]) {
        for id in ids { sharingByChoice.remove(id) }
        pause(ids)
    }

    func shareAgain(_ ids: [String]) { resume(ids) }

    func pauseAll() { pause(torrents.filter(\.canPause).map(\.id)) }
    func resumeAll() { resume(torrents.filter(\.canResume).map(\.id)) }

    func remove(_ ids: [String], deleteFiles: Bool) {
        for id in ids {
            AppModel.shared.stopPlayer(forTorrent: id)
            samples[id] = nil
            idleSince[id] = nil
            health[id] = nil
            rescueLog[id] = nil
            lastReannounce[id] = nil
            reannounceCount[id] = nil
            verifying[id] = nil
            lastErrors[id] = nil
            sharingByChoice.remove(id)
            session.remove(id, deleteFiles: deleteFiles)
        }
        refresh()
    }

    func setSequential(_ id: String, _ on: Bool) { session.setSequential(on, forTorrent: id); refresh() }
    func recheck(_ id: String) { session.recheck(id); log(id, "Checked the files again"); refresh() }
    func magnet(_ id: String) -> String? { session.magnetLink(for: id) }

    // MARK: Using files you already have

    private struct Verifying { let folder: URL; let started: Date; var checked = false }
    private var verifying: [String: Verifying] = [:]

    /// Points a torrent at a folder that may hold its files. Swarm checks them against the
    /// torrent's hashes: good parts are kept, missing or damaged parts download again.
    func useExistingFiles(_ id: String, at folder: URL) {
        guard torrent(id) != nil else { return }
        verifying[id] = Verifying(folder: folder, started: Date())
        let old = torrent(id).map { (URL(fileURLWithPath: $0.savePath), files(of: id)) }
        session.useExistingFiles(folder.path, forTorrent: id)
        if let (oldRoot, oldFiles) = old, oldRoot.path != folder.path { removeEmptyPlaceholders(oldFiles, in: oldRoot) }
        log(id, "Checking the files in \(folder.lastPathComponent) against this torrent")
        refresh()
    }

    /// A torrent that already started leaves empty full-size placeholder files in its old
    /// folder. Remove those, and ONLY those: a file with any real data in it stays.
    private func removeEmptyPlaceholders(_ files: [TorrentFile], in root: URL) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))   // after libtorrent let go of them
            for f in files {
                let url = root.appendingPathComponent(f.path)
                guard let v = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]),
                      let size = v.fileSize, size > 0, (v.fileAllocatedSize ?? 1) == 0 else { continue }
                try? FileManager.default.removeItem(at: url)
                // Folders that are now empty, up to (not including) the download folder.
                var dir = url.deletingLastPathComponent()
                while dir.path != root.path, (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: dir)
                    dir.deleteLastPathComponent()
                }
            }
        }
    }

    /// Torrents a dropped file or folder could belong to, with the folder to point them at.
    func torrentsMatching(_ url: URL) -> [(torrent: Torrent, folder: URL)] {
        let name = url.lastPathComponent
        let direct = torrents.filter { !$0.name.isEmpty && $0.name == name }
        if !direct.isEmpty { return direct.map { ($0, url.deletingLastPathComponent()) } }
        // A folder that holds the torrent's folder or file (a whole Downloads folder).
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { return [] }
        return torrents.filter { !$0.name.isEmpty && FileManager.default.fileExists(atPath: url.appendingPathComponent($0.name).path) }
            .map { ($0, url) }
    }

    /// Says what the check found once it is over.
    private func finishVerifying(_ list: [Torrent], now: Date) {
        for t in list {
            guard let v = verifying[t.id] else { continue }
            // Wait for libtorrent to say the check is over (or give up after a minute).
            guard v.checked || now.timeIntervalSince(v.started) > 60 else { continue }
            verifying[t.id] = nil
            let total = t.chosenSize
            if t.status == .choosingFiles || total <= 0 {
                log(t.id, "Now using \(v.folder.lastPathComponent); the files are checked when you start the download")
                continue
            }
            let found = min(t.wantedDone, total)
            let line: String
            if found >= total { line = "Everything was already there and correct (\(Format.bytes(total))). Nothing to download." }
            else if found <= 0 { line = "Nothing in \(v.folder.lastPathComponent) matched this torrent, so all \(Format.bytes(total)) will download." }
            else { line = "Reused \(Format.bytes(found)) of \(Format.bytes(total)) already on disk. The remaining \(Format.bytes(total - found)) will download." }
            log(t.id, line)
            problem = Problem(title: "Files checked", message: line)
        }
    }

    /// True while the scheduled limits are the ones in force.
    private(set) var scheduleActive = false
    private var appliedScheduleKey = ""

    /// Limits in force right now: the schedule's during its hours, else the usual ones.
    func applyLimits() {
        let scheduled = Prefs.Schedule.isActive()
        if scheduled != scheduleActive { scheduleActive = scheduled }
        let down = scheduled ? Prefs.Schedule.downKB : Prefs.downLimitKB
        let up = scheduled ? Prefs.Schedule.upKB : Prefs.upLimitKB
        session.setDownloadLimit(Int32(down * 1024), uploadLimit: Int32(up * 1024))
        appliedScheduleKey = "\(scheduled)"
    }

    /// Called every refresh: cheap, and only touches the session when the schedule flips.
    private func checkSchedule() {
        guard Prefs.Schedule.isActive() != scheduleActive || (scheduleActive && appliedScheduleKey != "true") else { return }
        applyLimits()
    }

    func applyPort() { session.setListenPort(Int32(Prefs.port)) }
}
