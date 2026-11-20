import AppKit
import UserNotifications

/// "Download finished" notifications with Open and Show in Finder buttons.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func setUp() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // command-line test runs
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open")
        let show = UNNotificationAction(identifier: "show", title: "Show in Finder")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "done", actions: [open, show], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func finished(_ t: Torrent) {
        guard Prefs.notify, Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = "Download finished"
        c.body = t.displayName
        if !t.isSingleFile, t.fileCount > 1 { c.subtitle = "\(t.fileCount) files, \(Format.bytes(t.wanted))" }
        c.sound = .default
        c.categoryIdentifier = "done"
        if let url = t.contentURL { c.userInfo = ["path": url.path] }
        center.add(UNNotificationRequest(identifier: t.id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let path else { NSApp.activate(); return }
            let url = URL(fileURLWithPath: path)
            if action == "open" { NSWorkspace.shared.open(url) }
            else if action == "show" { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { AppModel.shared.showWindow(); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
