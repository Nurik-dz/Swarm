import Foundation

enum Prefs {
    enum Key {
        static let folder = "downloadFolder"
        static let chooseFiles = "chooseFilesBeforeDownloading"
        static let afterDone = "afterDownloading"
        static let downLimit = "downloadLimitKB"
        static let upLimit = "uploadLimitKB"
        static let port = "listenPort"
        static let notify = "notifyWhenDone"
        static let menuBar = "showInMenuBar"
        static let inspector = "showInspector"
        static let theme = "theme"
        static let look = "windowLook"
        static let lanReceive = "lanReceive"
        static let scheduleOn = "scheduleOn"
        static let scheduleDays = "scheduleDays"
        static let scheduleFrom = "scheduleFromMinutes"
        static let scheduleTo = "scheduleToMinutes"
        static let scheduleDown = "scheduleDownloadLimitKB"
        static let scheduleUp = "scheduleUploadLimitKB"
    }

    /// Different limits at set times (for example slower during working hours).
    enum Schedule {
        enum Days: String, CaseIterable, Identifiable {
            case every, weekdays, weekends
            var id: String { rawValue }
            var title: String {
                switch self {
                case .every: "Every day"
                case .weekdays: "Weekdays"
                case .weekends: "Weekends"
                }
            }
        }

        struct Window: Equatable {
            var days: Days
            var from: Int      // minutes after midnight
            var to: Int

            /// A window may run past midnight (22:00 to 07:00). The weekday it belongs to
            /// is the one it started on.
            func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
                let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
                let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                func allowed(_ weekday: Int) -> Bool {
                    let weekend = weekday == 1 || weekday == 7
                    switch days { case .every: return true; case .weekdays: return !weekend; case .weekends: return weekend }
                }
                let today = c.weekday ?? 1
                if from == to { return false }
                if from < to { return now >= from && now < to && allowed(today) }
                // Overnight: the evening part belongs to today, the morning part to yesterday.
                if now >= from { return allowed(today) }
                if now < to { return allowed(today == 1 ? 7 : today - 1) }
                return false
            }
        }

        static var enabled: Bool { UserDefaults.standard.bool(forKey: Key.scheduleOn) }
        static var window: Window {
            let d = UserDefaults.standard
            return Window(days: Days(rawValue: d.string(forKey: Key.scheduleDays) ?? "") ?? .every,
                          from: d.integer(forKey: Key.scheduleFrom), to: d.integer(forKey: Key.scheduleTo))
        }
        static var downKB: Int { UserDefaults.standard.integer(forKey: Key.scheduleDown) }
        static var upKB: Int { UserDefaults.standard.integer(forKey: Key.scheduleUp) }

        static func isActive(at date: Date = Date()) -> Bool { enabled && window.contains(date) }

        /// "9:00" style for a minute count.
        static func clock(_ minutes: Int) -> String {
            let d = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            return d.formatted(date: .omitted, time: .shortened)
        }
    }

    /// What happens when a torrent finishes.
    enum AfterDone: String, CaseIterable, Identifiable {
        case shareFairly, stop, keepSharing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shareFairly: "Share until uploaded as much as downloaded"
            case .stop: "Stop right away"
            case .keepSharing: "Keep sharing until I stop it"
            }
        }
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.chooseFiles: true,
            Key.afterDone: AfterDone.shareFairly.rawValue,
            Key.downLimit: 0,
            Key.upLimit: 0,
            Key.port: 6881,
            Key.notify: true,
            Key.menuBar: true,
            Key.inspector: true,
            Key.theme: "system",
            Key.look: "glass",
            Key.lanReceive: false,
            Key.scheduleOn: false,
            Key.scheduleDays: Schedule.Days.weekdays.rawValue,
            Key.scheduleFrom: 9 * 60,
            Key.scheduleTo: 23 * 60,
            Key.scheduleDown: 512,
            Key.scheduleUp: 64,
        ])
    }

    static let defaultFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    static var folder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: Key.folder), !p.isEmpty {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
            return defaultFolder
        }
        set { UserDefaults.standard.set(newValue.path, forKey: Key.folder) }
    }

    static var chooseFiles: Bool { UserDefaults.standard.bool(forKey: Key.chooseFiles) }
    static var notify: Bool { UserDefaults.standard.bool(forKey: Key.notify) }
    static var afterDone: AfterDone {
        AfterDone(rawValue: UserDefaults.standard.string(forKey: Key.afterDone) ?? "") ?? .shareFairly
    }
    static var downLimitKB: Int { UserDefaults.standard.integer(forKey: Key.downLimit) }
    static var upLimitKB: Int { UserDefaults.standard.integer(forKey: Key.upLimit) }
    static var port: Int { UserDefaults.standard.integer(forKey: Key.port) }

    static var stateFolder: URL {
        // Tests point this elsewhere so they never touch real torrents.
        if let dir = ProcessInfo.processInfo.environment["SWARM_STATE_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swarm", isDirectory: true)
    }
}
