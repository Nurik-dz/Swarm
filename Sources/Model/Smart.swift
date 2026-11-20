import Foundation

/// Understands release file names: which videos are the same episode in
/// different sizes, which subtitles belong to them, what is a sample or an
/// extra. Local string parsing only; every result is a suggestion the person
/// can edit.
struct SmartPicks {
    struct Choice: Equatable {
        /// Video height to prefer (2160, 1080, ...). nil = best available.
        var resolution: Int?
        /// Subtitle language code to keep ("en"). nil = all, "" = none.
        var language: String?
        var skipJunk = true
    }

    let files: [TorrentFile]
    private let info: [Int: Info]

    struct Info {
        var resolution: Int?      // video height
        var episode: String?      // "S01E02", "1x02"
        var language: String?     // subtitles
        var junk: Bool            // sample / trailer / extras
    }

    init(_ files: [TorrentFile]) {
        self.files = files
        var info: [Int: Info] = [:]
        for f in files { info[f.index] = Self.parse(f) }
        self.info = info
    }

    // MARK: What is there

    /// Resolutions present in more than one version of the same thing: only then is choosing useful.
    var resolutions: [Int] {
        var groups: [String: Set<Int>] = [:]
        for f in files where f.kind == .video && !(info[f.index]?.junk ?? false) {
            guard let r = info[f.index]?.resolution else { continue }
            groups[groupKey(f), default: []].insert(r)
        }
        let multi = groups.values.filter { $0.count > 1 }
        return Set(multi.flatMap { $0 }).sorted(by: >)
    }

    /// Subtitle languages found, when there is more than one.
    var languages: [String] {
        let set = Set(files.compactMap { $0.kind == .subtitle ? info[$0.index]?.language : nil })
        return set.count > 1 ? set.sorted() : []
    }

    var hasJunk: Bool { files.contains { info[$0.index]?.junk == true } }

    /// Worth showing at all?
    var isUseful: Bool { !resolutions.isEmpty || !languages.isEmpty || hasJunk }

    // MARK: Choosing

    func select(_ c: Choice) -> Set<Int> {
        let videos = files.filter { $0.kind == .video && !(info[$0.index]?.junk ?? false) }
        var keptVideos = Set<Int>()
        for (_, group) in Dictionary(grouping: videos, by: groupKey) {
            let rs = Set(group.compactMap { info[$0.index]?.resolution })
            guard rs.count > 1, let wanted = pick(c.resolution, from: rs) else {
                keptVideos.formUnion(group.map(\.index)); continue
            }
            keptVideos.formUnion(group.filter { info[$0.index]?.resolution == wanted }.map(\.index))
        }
        let keptEpisodes = Set(keptVideos.compactMap { idx in files.first { $0.index == idx }.flatMap { info[$0.index]?.episode } })
        let anyKeys = !keptEpisodes.isEmpty

        var out = Set<Int>()
        for f in files {
            let i = info[f.index] ?? Info(junk: false)
            if c.skipJunk && i.junk { continue }
            switch f.kind {
            case .video:
                if keptVideos.contains(f.index) { out.insert(f.index) }
                else if i.junk { out.insert(f.index) }   // junk kept only when not skipping
            case .subtitle:
                if let l = c.language {
                    if l.isEmpty { continue }
                    if let fl = i.language, fl != l { continue }
                }
                // Belongs to a video we dropped? (same episode only counts when we can tell.)
                if anyKeys, let e = i.episode, !keptEpisodes.contains(e) { continue }
                out.insert(f.index)
            default:
                out.insert(f.index)
            }
        }
        return out
    }

    /// The wanted height, or the closest one we do have (prefer lower than asked, else the best).
    private func pick(_ wanted: Int?, from available: Set<Int>) -> Int? {
        guard let wanted else { return available.max() }
        if available.contains(wanted) { return wanted }
        return available.filter { $0 < wanted }.max() ?? available.min()
    }

    /// Things that are the same item in different versions share a key.
    private func groupKey(_ f: TorrentFile) -> String {
        if let e = info[f.index]?.episode { return (f.folder.isEmpty ? "" : f.folder + "/") + e }
        // No episode number: versions of one movie sit side by side; group by what is left of the name.
        return f.folder + "/" + Self.stem(f.name)
    }

    // MARK: Parsing

    static func parse(_ f: TorrentFile) -> Info {
        let lower = f.path.lowercased()
        var info = Info(junk: false)
        let name = (f.name as NSString).deletingPathExtension.lowercased()

        info.episode = firstMatch(in: name, #"s(\d{1,2})[ ._-]?e(\d{1,3})"#).map { "S\($0[0])E\($0[1])" }
            ?? firstMatch(in: name, #"(?<![\d])(\d{1,2})x(\d{2,3})(?![\d])"#).map { "S\($0[0])E\($0[1])" }
        if let e = info.episode {   // normalise "S1E2" and "S01E02" to the same key
            let nums = e.dropFirst().split(separator: "E").compactMap { Int($0) }
            if nums.count == 2 { info.episode = String(format: "S%02dE%02d", nums[0], nums[1]) }
        }

        if f.kind == .video {
            if lower.contains("2160") || lower.range(of: #"(?<![a-z])4k(?![a-z])"#, options: .regularExpression) != nil || lower.contains("uhd") {
                info.resolution = 2160
            } else if let r = firstMatch(in: lower, #"(?<!\d)(1080|720|576|480|360)[pi]?(?!\d)"#), let n = Int(r[0]) {
                info.resolution = n
            }
        }
        if f.kind == .subtitle { info.language = language(in: name) }

        let parts = lower.split(separator: "/").map(String.init)
        let folders = parts.dropLast()
        let junkWords = ["sample", "trailer", "extras", "extra", "featurette", "featurettes", "bonus", "behind the scenes", "deleted scenes", "promo"]
        if f.kind == .video || f.kind == .audio {
            let hay = Array(folders) + [name]
            info.junk = hay.contains { part in
                junkWords.contains { w in part.range(of: #"(^|[^a-z])\#(w)([^a-z]|$)"#, options: .regularExpression) != nil }
            }
        }
        return info
    }

    private static let languages: [(code: String, words: [String])] = [
        ("en", ["en", "eng", "english"]), ("es", ["es", "spa", "spanish", "espanol"]),
        ("fr", ["fr", "fre", "fra", "french"]), ("de", ["de", "ger", "deu", "german"]),
        ("it", ["it", "ita", "italian"]), ("pt", ["pt", "por", "portuguese", "ptbr"]),
        ("ru", ["ru", "rus", "russian"]), ("ja", ["ja", "jpn", "japanese"]),
        ("ko", ["ko", "kor", "korean"]), ("zh", ["zh", "chi", "zho", "chinese", "chs", "cht"]),
        ("ar", ["ar", "ara", "arabic"]), ("tr", ["tr", "tur", "turkish"]),
        ("nl", ["nl", "dut", "nld", "dutch"]), ("pl", ["pl", "pol", "polish"]),
    ]

    static func language(in name: String) -> String? {
        let tokens = name.split { !$0.isLetter }.map(String.init)
        for (code, words) in languages where tokens.contains(where: words.contains) { return code }
        return nil
    }

    static func displayName(forLanguage code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    private static func stem(_ name: String) -> String {
        var s = (name as NSString).deletingPathExtension.lowercased()
        for pattern in [#"(2160|1080|720|576|480|360)[pi]?"#, #"\b4k\b"#, #"\buhd\b"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return s.filter { $0.isLetter || $0.isNumber }
    }

    private static func firstMatch(in s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }
}

extension SmartPicks.Info {
    init(junk: Bool) { self.init(resolution: nil, episode: nil, language: nil, junk: junk) }
}

extension SmartPicks {
    static func label(forResolution r: Int) -> String { r >= 2160 ? "4K" : "\(r)p" }
}
