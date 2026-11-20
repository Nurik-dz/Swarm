import Foundation
// Checks SmartPicks on representative file lists.
// build: see Tests/smart/build.sh
func f(_ i: Int, _ path: String, _ mb: Int64 = 500) -> TorrentFile {
    let t = TBFile(); t.index = Int32(i); t.path = path; t.size = mb * 1_000_000; t.done = 0; t.wanted = true
    return TorrentFile(t)
}
var failed = 0
func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL:", what) } else { print("ok:  ", what) } }

// Season in two resolutions, two subtitle languages, a sample and extras.
let files = [
    f(0, "Show/Show.S01E01.2160p.mkv"), f(1, "Show/Show.S01E01.1080p.mkv"),
    f(2, "Show/Show.S01E02.2160p.mkv"), f(3, "Show/Show.S01E02.1080p.mkv"),
    f(4, "Show/Subs/Show.S01E01.English.srt"), f(5, "Show/Subs/Show.S01E01.Spanish.srt"),
    f(6, "Show/Subs/Show.S01E02.English.srt"), f(7, "Show/Subs/Show.S01E02.Spanish.srt"),
    f(8, "Show/Sample/sample.mkv"), f(9, "Show/Extras/Making of.mkv"), f(10, "Show/cover.jpg"),
]
let p = SmartPicks(files)
check(p.isUseful, "useful")
check(p.resolutions == [2160, 1080], "resolutions \(p.resolutions)")
check(p.languages == ["en", "es"], "languages \(p.languages)")
check(p.hasJunk, "junk found")
check(p.select(.init(resolution: 1080, language: "en")) == [1, 3, 4, 6, 10], "1080p + English: \(p.select(.init(resolution: 1080, language: "en")).sorted())")
check(p.select(.init(resolution: nil, language: nil)) == [0, 2, 4, 5, 6, 7, 10], "best + all subs: \(p.select(.init(resolution: nil, language: nil)).sorted())")
check(p.select(.init(resolution: 1080, language: "", skipJunk: false)) == [1, 3, 8, 9, 10], "no subs, keep junk: \(p.select(.init(resolution: 1080, language: "", skipJunk: false)).sorted())")
// Asked for 720p but only 2160/1080 exist: closest lower is not there, falls to the smallest.
check(p.select(.init(resolution: 720, language: nil)).isSuperset(of: [1, 3]), "720p falls back to 1080p")

// A plain movie: nothing to suggest.
let movie = SmartPicks([f(0, "Movie (2020)/Movie.2020.1080p.mkv", 4000), f(1, "Movie (2020)/Movie.srt", 1)])
check(!movie.isUseful, "single movie: nothing to suggest")

// Two unrelated movies must never be treated as versions of each other.
let two = SmartPicks([f(0, "A.Film.1080p.mkv"), f(1, "B.Film.720p.mkv")])
check(two.resolutions.isEmpty, "unrelated movies are not alternatives")
check(two.select(.init(resolution: 1080, language: nil)) == [0, 1], "both kept")

// Same movie in two encodes (no episode number).
let enc = SmartPicks([f(0, "Film.2160p.mkv"), f(1, "Film.1080p.mkv")])
check(enc.resolutions == [2160, 1080], "same title two sizes")
check(enc.select(.init(resolution: 1080, language: nil)) == [1], "keeps only 1080p")
exit(failed == 0 ? 0 : 1)
