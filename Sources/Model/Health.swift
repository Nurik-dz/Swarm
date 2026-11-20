import Foundation
import SwiftUI

/// What the connected peers can give us, sampled every few seconds.
struct HealthSnapshot: Equatable {
    var pieceCount: Int
    var missing: Int            // pieces still needed for the chosen files
    var unadvertised: Int       // of those, pieces nobody connected has
    var peers: Int
    var completeSource: Bool
    var copies: Double

    init(_ h: TBHealth) {
        pieceCount = Int(h.pieceCount)
        missing = Int(h.missingWanted)
        unadvertised = Int(h.missingUnadvertised)
        peers = Int(h.peersChecked)
        completeSource = h.completeSourceSeen
        copies = h.copies
    }
}

/// A plain-language reason and, when there is one, a safe thing to try.
/// Always worded as "right now": nothing here claims a torrent is impossible.
struct Diagnosis: Equatable {
    enum Level { case info, warning, problem }
    enum Action: Equatable { case askTrackers, checkFiles, chooseFolder }

    var level: Level
    var title: String
    var detail: String
    var action: Action?

    var tint: Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .problem: .red
        }
    }
    var symbol: String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .problem: "exclamationmark.octagon"
        }
    }
}

enum Rescue {
    /// Seconds with no data before a stall is worth explaining.
    static let stallAfter: TimeInterval = 30

    /// Free bytes on the volume that holds `path` (nil when unknown).
    static func freeSpace(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: path)
        // The folder may not exist yet: ask about the nearest one that does.
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let n = v.volumeAvailableCapacityForImportantUsage { return n }
        return nil
    }

    /// Bytes still to write for what is chosen.
    static func remaining(_ t: Torrent) -> Int64 { max(0, t.chosenSize - min(t.wantedDone, t.chosenSize)) }

    /// Does the rest fit? nil = fine or unknown.
    static func diskProblem(_ t: Torrent, free: Int64?) -> Diagnosis? {
        guard t.status == .downloading || t.status == .failed || t.status == .paused else { return nil }
        let need = remaining(t)
        if t.status == .failed, let e = t.error?.lowercased(), e.contains("space") {
            return Diagnosis(level: .problem, title: "The disk is full",
                             detail: "There is no room left to save this. Free some space, then resume, or move to another disk.",
                             action: .chooseFolder)
        }
        guard need > 0, let free, free < need else { return nil }
        return Diagnosis(level: .problem, title: "Not enough room on this disk",
                         detail: "\(Format.bytes(need)) is still to come, but only \(Format.bytes(free)) is free. Free up space or pick another disk in Settings.",
                         action: .chooseFolder)
    }

    /// The best single explanation for why a download is not moving, or nil.
    static func diagnose(_ t: Torrent, health: HealthSnapshot?, idleFor: TimeInterval, free: Int64?) -> Diagnosis? {
        if let d = diskProblem(t, free: free) { return d }
        guard t.status == .downloading, !t.isStarting, t.wanted > t.wantedDone else { return nil }

        let stalled = t.downRate < 1024 && idleFor >= stallAfter
        if let h = health, h.missing > 0, h.peers > 0, h.unadvertised > 0 {
            let all = h.unadvertised == h.missing
            if all {
                return Diagnosis(level: .warning, title: "Nobody connected has what's left",
                                 detail: "None of the \(people(h.peers)) connected to Swarm offers the \(pieces(h.missing)) still needed. This can change when someone new joins, so Swarm keeps looking.",
                                 action: .askTrackers)
            }
            if t.progress >= 0.9 || stalled {
                return Diagnosis(level: .warning, title: "\(pieces(h.unadvertised)) not offered right now",
                                 detail: "\(h.unadvertised) of the \(h.missing) pieces still needed aren't available from anyone connected. The rest keep downloading.",
                                 action: stalled ? .askTrackers : nil)
            }
        }
        guard stalled else { return nil }

        if t.peers == 0 {
            if t.trackers > 0 && t.trackersFailed >= t.trackers {
                let why = t.trackerError.map { " (\($0))" } ?? ""
                return Diagnosis(level: .warning, title: "The trackers aren't answering",
                                 detail: "Connection lost and no tracker replied\(why). Swarm still looks for people through the DHT network.",
                                 action: .askTrackers)
            }
            return Diagnosis(level: .warning, title: "No one is connected",
                             detail: "Swarm lost its connections and is looking for people sharing this. It may be that nobody is online right now.",
                             action: .askTrackers)
        }
        if let h = health, h.missing > 0, h.unadvertised == 0 {
            return Diagnosis(level: .info, title: "Connected, waiting for data",
                             detail: "\(people(t.peers)) can supply what's left but haven't sent anything for a while. They may be busy or limiting their speed.",
                             action: nil)
        }
        return Diagnosis(level: .info, title: "Connected, waiting for data",
                         detail: "\(people(t.peers)) connected but nothing is arriving. Swarm keeps asking.",
                         action: nil)
    }

    private static func people(_ n: Int) -> String { n == 1 ? "1 person" : "\(n) people" }
    private static func pieces(_ n: Int) -> String { n == 1 ? "1 piece" : "\(n) pieces" }

    /// One line about whether the chosen files can finish with who's connected.
    static func feasibility(_ t: Torrent, health: HealthSnapshot?) -> (text: String, good: Bool)? {
        guard t.status == .downloading, !t.isStarting, let h = health, h.missing > 0 else { return nil }
        if h.unadvertised == 0 {
            return h.completeSource ? ("Someone connected has everything", true)
                                    : ("Everything still needed is available from the people connected", true)
        }
        if h.unadvertised == h.missing { return ("Nobody connected has what's left, for now", false) }
        let pct = Int((Double(h.missing - h.unadvertised) / Double(h.missing) * 100).rounded())
        return ("\(pct)% of what's left is available from the people connected", false)
    }
}
