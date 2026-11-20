import AppKit
import SwiftUI

// Opens the main window off-screen with a forced theme, then reports.
// usage: harness <light|dark|system> <appkit|swiftui>
let theme = CommandLine.arguments[1], method = CommandLine.arguments[2]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    Prefs.register()
    if method == "appkit" {
        if theme == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        if theme == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
    }
    let model = AppModel.shared
    let scheme: ColorScheme? = method == "swiftui" ? (theme == "light" ? .light : theme == "dark" ? .dark : nil) : nil
    let frameMode = ProcessInfo.processInfo.environment["FRAME"] ?? "wh"
    let base = MainView().environment(model).environment(model.store)
    let root: AnyView
    switch frameMode {
    case "none": root = AnyView(base.preferredColorScheme(scheme))
    case "w": root = AnyView(base.frame(minWidth: CGFloat(830)).preferredColorScheme(scheme))
    case "h": root = AnyView(ThemedRoot { base.frame(minHeight: 440) })
    default: root = AnyView(base.frame(minWidth: CGFloat(830), minHeight: 440).preferredColorScheme(scheme))
    }
    let hc = NSHostingController(rootView: root)
    hc.sceneBridgingOptions = [.toolbars, .title]
    let w = NSWindow(contentViewController: hc)
    w.styleMask.insert(.fullSizeContentView)
    w.toolbarStyle = .unified
    let width = CGFloat(Double(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "1000") ?? 1000)
    w.setFrame(NSRect(x: -6000, y: 200, width: width, height: 640), display: true)
    w.orderFront(nil)
    if method == "late" {
        // As in the app: the theme arrives while the window lays out.
        DispatchQueue.main.async {
            NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        }
    }
    if method == "launch" {
        UserDefaults.standard.set(theme, forKey: Prefs.Key.theme)
        AppearanceModel.shared.start()
        model.store.start()
        DockProgress.shared.update(progress: 0.4, active: 1)
    }
    // Stress: resize sweep, theme flips, details pane toggles.
    var steps: [() -> Void] = []
    let minW = CGFloat(830)
    for i in 0..<40 {
        let wdt = i < 20 ? minW + CGFloat(i) * 55 : minW + CGFloat(39 - i) * 55
        steps.append { w.setFrame(NSRect(x: -6000, y: 200, width: wdt, height: 640), display: true) }
    }
    for i in 0..<12 {
        steps.append {
            UserDefaults.standard.set(i % 2 == 0 ? "light" : "dark", forKey: Prefs.Key.theme)
            AppearanceModel.shared.refresh()
        }
    }
    for _ in 0..<(CommandLine.arguments.count > 4 ? 0 : 20) {
        steps.append {
            AppModel.shared.togglePanel()
        }
    }
    for _ in 0..<(CommandLine.arguments.count > 4 ? 0 : 10) {
        steps.append {
            _ = w.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
        }
    }
    if ProcessInfo.processInfo.environment["NOSTEPS"] == "1" { steps.removeAll() }
    // ONLY=resize|theme|inspector|sidebar keeps one kind of step.
    if let only = ProcessInfo.processInfo.environment["ONLY"] {
        let ranges: [String: Range<Int>] = ["resize": 0..<40, "theme": 40..<52, "inspector": 52..<72, "sidebar": 72..<82]
        let all = steps
        steps = only.split(separator: ",").flatMap { name in ranges[String(name)].map { Array(all[$0]) } ?? [] }
    }
    // FASTHUMAN=1: four theme clicks 200 ms apart, then 8 panel clicks 250 ms apart.
    if ProcessInfo.processInfo.environment["FASTHUMAN"] == "1" {
        steps = []
        for i in 0..<4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.2) {
                UserDefaults.standard.set(i % 2 == 0 ? "light" : "dark", forKey: Prefs.Key.theme)
                AppearanceModel.shared.refresh()
            }
        }
        for i in 0..<8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9 + Double(i) * 0.25) { AppModel.shared.togglePanel() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { print("OK fasthuman"); exit(0) }
    }
    // GAPMS=n: one theme change, then open the panel n ms later.
    if let g = ProcessInfo.processInfo.environment["GAPMS"], let ms = Double(g) {
        UserDefaults.standard.set(false, forKey: Prefs.Key.inspector)
        steps = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            UserDefaults.standard.set(theme == "dark" ? "dark" : "light", forKey: Prefs.Key.theme)
            AppearanceModel.shared.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { AppModel.shared.togglePanel() }
        }
    }
    // HUMAN=1: one theme change, then panel clicks a second apart.
    if ProcessInfo.processInfo.environment["HUMAN"] == "1" {
        steps = [{ NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua) }]
        for _ in 0..<6 {
            steps.append { AppModel.shared.togglePanel() }
        }
    }
    let gap = ProcessInfo.processInfo.environment["HUMAN"] == "1" ? 1.0 : 0.06
    for (n, step) in steps.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(n) * gap) {
            print("step \(n) inspector=\(UserDefaults.standard.bool(forKey: Prefs.Key.inspector)) scheme=\(String(describing: AppearanceModel.shared.scheme))"); fflush(stdout)
            step()
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(steps.count) * gap) {
        if let v = w.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/harness-\(theme)-\(method).png"))
        }
        var splits: [String] = []
        func walk(_ v: NSView) {
            if let sp = v as? NSSplitView { splits.append(sp.arrangedSubviews.map { "\(Int($0.frame.width))\(sp.isSubviewCollapsed($0) ? "c" : "")" }.joined(separator: "|")) }
            v.subviews.forEach(walk)
        }
        walk(w.contentView!.superview!)
        print("  columns: \(splits)")
        print("OK \(theme) \(method): window alive, appearance \(w.effectiveAppearance.name.rawValue)")
        exit(0)
    }
}
app.run()

/// Same as the app: the window follows AppearanceModel's scheme.
struct ThemedRoot<C: View>: View {
    @ViewBuilder var content: C
    var body: some View { content.preferredColorScheme(AppearanceModel.shared.scheme) }
}
