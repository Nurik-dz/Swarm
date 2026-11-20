import Foundation
// Checks the scheduled-limits window logic. build: Tests/schedule/build.sh
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {   // October 2026: 23 = Fri, 24 = Sat, 25 = Sun, 26 = Mon, 27 = Tue
    cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2026, month: 10, day: day, hour: h, minute: m))!
}
var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok:  " : "FAIL:", what); if !ok { failed += 1 } }
typealias W = Prefs.Schedule.Window
let work = W(days: .weekdays, from: 9 * 60, to: 23 * 60)
check(work.contains(at(23, 10), calendar: cal), "Friday 10:00 is inside weekday 9-23")
check(!work.contains(at(23, 8, 59), calendar: cal), "Friday 08:59 is outside")
check(!work.contains(at(23, 23), calendar: cal), "Friday 23:00 is outside (end is exclusive)")
check(!work.contains(at(24, 12), calendar: cal), "Saturday noon is outside a weekday window")
check(W(days: .weekends, from: 0, to: 24 * 60 - 1).contains(at(25, 12), calendar: cal), "Sunday noon is inside a weekend window")
let night = W(days: .weekdays, from: 22 * 60, to: 7 * 60)
check(night.contains(at(23, 23), calendar: cal), "overnight 22-07: Friday 23:00 inside")
check(night.contains(at(24, 3), calendar: cal), "Saturday 03:00 belongs to Friday's night: inside")
check(!night.contains(at(24, 23), calendar: cal), "Saturday 23:00 starts a weekend night: outside")
check(!night.contains(at(26, 3), calendar: cal), "Monday 03:00 belongs to Sunday's night: outside")
check(night.contains(at(27, 3), calendar: cal), "Tuesday 03:00 belongs to Monday's night: inside")
check(!night.contains(at(23, 12), calendar: cal), "overnight window: midday is outside")
check(!W(days: .every, from: 600, to: 600).contains(at(23, 10), calendar: cal), "empty window (from == to) is never active")
check(W(days: .every, from: 22 * 60, to: 7 * 60).contains(at(25, 2), calendar: cal), "every day overnight: Sunday 02:00 inside")
exit(failed == 0 ? 0 : 1)
