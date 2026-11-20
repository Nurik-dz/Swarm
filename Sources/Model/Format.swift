import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Int64) -> String {
        bytesPerSecond < 1024 ? "0 KB/s" : bytes(bytesPerSecond) + "/s"
    }

    /// "About 3 minutes left", "Less than a minute left", like Finder.
    static func timeLeft(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 50 { return "Less than a minute left" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        if seconds >= 86_400 {
            f.allowedUnits = [.day, .hour]
            f.maximumUnitCount = 2
        } else if seconds >= 3600 {
            f.allowedUnits = [.hour, .minute]
            f.maximumUnitCount = 2
        } else {
            f.allowedUnits = [.minute]
        }
        let rounded = max(60, (seconds / 60).rounded() * 60)
        return "About \(f.string(from: rounded) ?? "") left"
    }

    static func ratio(_ r: Double) -> String { String(format: "%.2f", r) }

    static func date(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today, " + d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday, " + d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func peers(_ connected: Int, swarm: Int) -> String {
        if connected == 0 { return "No peers yet" }
        if swarm > connected { return "\(connected) of \(swarm) peers" }
        return connected == 1 ? "1 peer" : "\(connected) peers"
    }
}
