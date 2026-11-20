import SwiftUI
import AppKit

/// Light / Dark / Match my Mac, and the window look: Liquid Glass (the
/// desktop shows through), Frosted, or Solid.
enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Match my Mac"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Applied per window with .preferredColorScheme (never by forcing
    /// NSApp.appearance, which relaid every window out at once).
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum WindowLook: String, CaseIterable, Identifiable {
    case glass, frosted, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .frosted: "Frosted"
        case .solid: "Solid"
        }
    }
    var symbol: String {
        switch self {
        case .glass: "drop"
        case .frosted: "snowflake"
        case .solid: "square.fill"
        }
    }
    var note: String {
        switch self {
        case .glass: "Clear glass: your desktop shows softly through the window."
        case .frosted: "Heavily blurred, like the Dock and menus."
        case .solid: "A plain window background."
        }
    }

    /// Reduce Transparency in Accessibility settings always wins.
    static var effective: WindowLook {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { return .solid }
        return WindowLook(rawValue: UserDefaults.standard.string(forKey: Prefs.Key.look) ?? "") ?? .glass
    }
}

/// Sits behind the whole window and makes it glass, frosted or solid.
struct WindowBackdrop: NSViewRepresentable {
    var look: WindowLook

    func makeNSView(context: Context) -> BackdropView { BackdropView() }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.look = look
    }

    final class BackdropView: NSView {
        var look: WindowLook = .glass { didSet { if look != oldValue { rebuild() } } }
        private var effect: NSView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            rebuild()
        }

        private func rebuild() {
            effect?.removeFromSuperview()
            effect = nil
            guard let window else { return }
            switch look {
            case .solid:
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
            case .glass:
                window.isOpaque = false
                window.backgroundColor = .clear
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.cornerRadius = 0
                add(glass)
            case .frosted:
                window.isOpaque = false
                window.backgroundColor = .clear
                let blur = NSVisualEffectView()
                blur.material = .underWindowBackground
                blur.blendingMode = .behindWindow
                blur.state = .active
                add(blur)
            }
        }

        private func add(_ v: NSView) {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
            effect = v
        }
    }
}

/// The current look, kept in step with Settings and Accessibility.
@MainActor
@Observable
final class AppearanceModel {
    static let shared = AppearanceModel()
    private(set) var look: WindowLook = WindowLook.effective
    private var observers: [Any] = []

    private(set) var scheme: ColorScheme? = Theme(rawValue: UserDefaults.standard.string(forKey: Prefs.Key.theme) ?? "")?.scheme

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            // Defaults change during window layout too: act on the next turn
            // of the run loop, and only when something really changed.
            DispatchQueue.main.async { AppearanceModel.shared.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { AppearanceModel.shared.refresh() }
        })
    }

    func refresh() {
        let newLook = WindowLook.effective
        if newLook != look { look = newLook }
        let newScheme = (Theme(rawValue: UserDefaults.standard.string(forKey: Prefs.Key.theme) ?? "") ?? .system).scheme
        if newScheme != scheme { scheme = newScheme }
    }

    var isSeeThrough: Bool { look != .solid }
}
