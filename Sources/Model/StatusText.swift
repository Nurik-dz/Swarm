import Foundation

/// Plain words for each state, shared by the row, the details panel and the
/// menu bar so they always say the same thing.
extension Torrent {
    private func people(_ n: Int) -> String { n == 1 ? "1 person" : "\(n) people" }

    /// The step a download is on before its first data arrives.
    var startupLine: String {
        if peers > 0 {
            return "Connected to \(people(peers)), asking for the first pieces…"
        }
        if knownPeers > 0 {
            let attempt = connecting > 0 ? ", connecting to \(connecting)" : ", connecting"
            return "Found \(people(knownPeers)) sharing\(attempt)…"
        }
        if trackersAnswered > 0 || peersFromDHT > 0 {
            return "Trackers answered, waiting for people sharing this…"
        }
        if trackers > 0 {
            return "Asking \(trackers == 1 ? "1 tracker" : "\(trackers) trackers") and the DHT network for people sharing…"
        }
        return "Asking the DHT network for people sharing…"
    }

    /// Why it is taking long, once it has (20 s with no data). nil before.
    func startupReason(after seconds: TimeInterval) -> String? {
        guard seconds >= 20 else { return nil }
        if knownPeers == 0 {
            if trackers > 0 && trackersFailed >= trackers {
                let why = trackerError.map { " (\($0))" } ?? ""
                return "No tracker answered\(why). Very few people may be sharing this; Swarm keeps trying."
            }
            return "Nobody sharing this has been found yet. Swarm keeps looking."
        }
        if peers == 0 {
            return "People were found, but none has accepted a connection yet. Swarm keeps trying."
        }
        return "Connected, but nobody has sent data yet. The people sharing may be busy; Swarm keeps asking."
    }

    /// Finished: what it is and when, plus sharing only while someone takes pieces.
    var finishedLine: String {
        var line = "\(Format.bytes(chosenSize)) \u{2014} Done"
        if let completed { line += ", " + Format.date(completed) }
        if isUploading { line += " \u{2014} sharing \u{2191} \(Format.speed(upRate))" }
        return line
    }
}
