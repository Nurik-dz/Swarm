import Foundation

/// Subtitle files (.srt and .vtt) turned into timed lines of text.
struct SubtitleTrack: Equatable {
    struct Cue: Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    let cues: [Cue]

    /// The line to show at this moment, if any.
    func text(at time: Double) -> String? {
        // Cues are sorted by start; find the last one that has started.
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        // Overlapping cues are rare; look back a few for one still showing.
        var i = lo - 1
        while i >= 0, i > lo - 4 {
            if cues[i].end > time { return cues[i].text }
            i -= 1
        }
        return nil
    }

    // MARK: Reading

    /// Decodes the file's bytes (UTF-8, UTF-16, else Windows Latin-1) and parses it.
    static func parse(data: Data) -> SubtitleTrack? {
        let utf16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])   // only with a byte-order mark: any even-length bytes "decode" as UTF-16
        let text = String(data: data, encoding: .utf8)
            ?? (utf16 ? String(data: data, encoding: .utf16) : nil)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    static func parse(_ raw: String) -> SubtitleTrack? {
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let t = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[t].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1]) else { continue }
            let body = lines[(t + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
            if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
        }
        guard !cues.isEmpty else { return nil }
        return SubtitleTrack(cues: cues.sorted { $0.start < $1.start })
    }

    /// "00:01:02,500", "01:02.500" or "1:02:03" to seconds. Ignores cue settings after the time.
    private static func seconds(_ s: String) -> Double? {
        let token = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let parts = token.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// Strips <i>, <font ...>, {\an8} and similar markup.
    private static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespaces)
    }
}
