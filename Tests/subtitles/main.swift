import Foundation
var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failed += 1 } }
let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i> there\r\n\r\n2\r\n00:00:04,000 --> 00:00:06,000 \r\n{\\an8}Second line\r\nwith two rows\r\n\r\n3\r\n01:02:03,250 --> 01:02:05,000\r\nLate one\r\n"
let t = SubtitleTrack.parse(srt)!
check(t.cues.count == 3, "three cues from SRT with CRLF and BOM")
check(t.text(at: 2) == "Hello there", "markup removed: \(t.text(at: 2) ?? "-")")
check(t.text(at: 3.6) == nil, "nothing between cues")
check(t.text(at: 5) == "Second line\nwith two rows", "two rows kept, {\\an8} removed")
check(t.text(at: 3723.5) == "Late one", "hour-long timestamp")
check(t.text(at: 0.5) == nil, "before the first cue")
let vtt = "WEBVTT\n\nintro\n00:01.000 --> 00:02.000 align:start position:0%\nShort time form\n\n00:00:03.000 --> 00:00:04.000\nSecond\n"
let v = SubtitleTrack.parse(vtt)!
check(v.cues.count == 2 && v.text(at: 1.5) == "Short time form", "VTT with note, short times and cue settings")
check(v.text(at: 3.5) == "Second", "VTT long time form")
check(SubtitleTrack.parse("not a subtitle file") == nil, "garbage is rejected")
let cp = "1\n00:00:01,000 --> 00:00:02,000\nCaf\u{E9}\n".data(using: .isoLatin1)!
check(SubtitleTrack.parse(data: cp)?.text(at: 1.5) == "Café", "Latin-1 file decoded")
let u16 = ("\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nHi\n").data(using: .utf16)!
check(SubtitleTrack.parse(data: u16)?.text(at: 1.5) == "Hi", "UTF-16 file with BOM decoded")
exit(failed == 0 ? 0 : 1)
