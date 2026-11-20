import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Speed", systemImage: "speedometer") { SpeedSettings() }
            Tab("Network", systemImage: "network") { NetworkSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.Key.chooseFiles) private var chooseFiles = true
    @AppStorage(Prefs.Key.afterDone) private var afterDone = Prefs.AfterDone.shareFairly.rawValue
    @AppStorage(Prefs.Key.notify) private var notify = true
    @AppStorage(Prefs.Key.menuBar) private var menuBar = true
    @AppStorage(Prefs.Key.theme) private var theme = "system"
    @AppStorage(Prefs.Key.look) private var look = "glass"
    @State private var folder = Prefs.folder
    @State private var magnetApp = ""
    @State private var torrentApp = ""

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(Theme.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Window", selection: $look) {
                    ForEach(WindowLook.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                     ? "Reduce Transparency is on in Accessibility settings, so the window is solid."
                     : (WindowLook(rawValue: look) ?? .glass).note)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Save downloads to") {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                            .resizable().frame(width: 18, height: 18)
                        Text(folder.lastPathComponent)
                        Button("Change…") { pickFolder() }
                    }
                }
                Toggle("Choose files before downloading", isOn: $chooseFiles)
                Text("Shows the list of files in a torrent first, so you can skip what you don't need.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("When a download finishes") {
                Picker("Sharing", selection: $afterDone) {
                    ForEach(Prefs.AfterDone.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show a notification", isOn: $notify)
            }
            Section {
                Toggle("Show Swarm in the menu bar", isOn: $menuBar)
                LabeledContent("Magnet links open in") {
                    HStack {
                        Text(magnetApp).foregroundStyle(.secondary)
                        if magnetApp != "Swarm" { Button("Use Swarm") { makeDefault() } }
                    }
                }
                LabeledContent(".torrent files open in") {
                    HStack {
                        Text(torrentApp).foregroundStyle(.secondary)
                        if torrentApp != "Swarm" { Button("Use Swarm") { makeDefault() } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: readDefaults)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        panel.message = "New torrents will be saved here. Torrents already added stay where they are."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Prefs.folder = url
        folder = url
    }

    private func appName(_ url: URL?) -> String {
        guard let url else { return "None" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func readDefaults() {
        magnetApp = appName(NSWorkspace.shared.urlForApplication(toOpen: URL(string: "magnet:?xt=urn:btih:0")!))
        torrentApp = appName(UTType(filenameExtension: "torrent").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) })
    }

    private func makeDefault() {
        let app = Bundle.main.bundleURL
        Task {
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet")
            if let type = UTType(filenameExtension: "torrent") {
                try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            }
            readDefaults()
        }
    }
}

private struct SpeedSettings: View {
    @Environment(TorrentStore.self) private var store
    @AppStorage(Prefs.Key.downLimit) private var down = 0
    @AppStorage(Prefs.Key.upLimit) private var up = 0
    @AppStorage(Prefs.Key.scheduleOn) private var scheduleOn = false
    @AppStorage(Prefs.Key.scheduleDays) private var days = Prefs.Schedule.Days.weekdays.rawValue
    @AppStorage(Prefs.Key.scheduleFrom) private var from = 9 * 60
    @AppStorage(Prefs.Key.scheduleTo) private var to = 23 * 60
    @AppStorage(Prefs.Key.scheduleDown) private var schedDown = 512
    @AppStorage(Prefs.Key.scheduleUp) private var schedUp = 64

    private let downChoices = [0, 256, 512, 1024, 2048, 5120, 10240, 20480]
    private let upChoices = [0, 32, 64, 128, 256, 512, 1024, 2048]

    var body: some View {
        Form {
            Section {
                Picker("Download limit", selection: $down) {
                    ForEach(downChoices, id: \.self) { Text(label($0)).tag($0) }
                }
                Picker("Upload limit", selection: $up) {
                    ForEach(upChoices, id: \.self) { Text(label($0)).tag($0) }
                }
            } footer: {
                Text("Limits apply to all torrents together. A modest upload limit keeps web browsing and video calls smooth while sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Use different limits at set times", isOn: $scheduleOn)
                if scheduleOn {
                    Picker("Days", selection: $days) {
                        ForEach(Prefs.Schedule.Days.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    DatePicker("From", selection: minutesBinding($from), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minutesBinding($to), displayedComponents: .hourAndMinute)
                    Picker("Download limit", selection: $schedDown) {
                        ForEach(downChoices, id: \.self) { Text(label($0)).tag($0) }
                    }
                    Picker("Upload limit", selection: $schedUp) {
                        ForEach(upChoices, id: \.self) { Text(label($0)).tag($0) }
                    }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text(scheduleOn
                     ? (store.scheduleActive ? "The schedule's limits are in force now." : "Outside these hours the limits above apply.")
                     : "For example slower during working hours and unlimited at night. A window may run past midnight.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: down) { _, _ in store.applyLimits() }
        .onChange(of: up) { _, _ in store.applyLimits() }
        .onChange(of: scheduleOn) { _, _ in store.applyLimits() }
        .onChange(of: days) { _, _ in store.applyLimits() }
        .onChange(of: from) { _, _ in store.applyLimits() }
        .onChange(of: to) { _, _ in store.applyLimits() }
        .onChange(of: schedDown) { _, _ in store.applyLimits() }
        .onChange(of: schedUp) { _, _ in store.applyLimits() }
    }

    /// A time-of-day picker over a "minutes after midnight" setting.
    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
        )
    }

    private func label(_ kb: Int) -> String {
        kb == 0 ? "Unlimited" : Format.bytes(Int64(kb) * 1024) + "/s"
    }
}

private struct NetworkSettings: View {
    @Environment(TorrentStore.self) private var store
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.Key.lanReceive) private var lanReceive = false
    @AppStorage(Prefs.Key.port) private var port = 6881
    @State private var text = ""
    @State private var actual = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("Listening port") {
                    HStack {
                        TextField("", text: $text)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(apply)
                        Button("Random") {
                            text = String(Int.random(in: 20000...60000))
                            apply()
                        }
                    }
                }
                LabeledContent("Status") {
                    if actual > 0 {
                        Label("Listening on port \(actual)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not listening", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("Other people connect to you on this port. Swarm asks your router to open it automatically (UPnP and NAT-PMP).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Receive files from nearby Macs", isOn: Binding(get: { lanReceive }, set: { lanReceive = $0; model.setReceiving($0) }))
                LabeledContent("This Mac appears as") { Text(model.lan.deviceName).foregroundStyle(.secondary) }
                if let e = model.lan.receiveError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
            } header: {
                Text("Nearby Macs")
            } footer: {
                Text("Other Macs running Swarm on this network can offer you a file or folder. Nothing is saved until you press Accept, and each offer shows four digits to compare with the other Mac. Off by default; when it is off, this Mac cannot be found.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            text = String(port)
            actual = Int(store.session.listenPort())
        }
    }

    private func apply() {
        guard let p = Int(text), (1024...65535).contains(p) else {
            text = String(port)
            NSSound.beep()
            return
        }
        port = p
        store.applyPort()
        Task {
            try? await Task.sleep(for: .seconds(1))
            actual = Int(store.session.listenPort())
        }
    }
}
