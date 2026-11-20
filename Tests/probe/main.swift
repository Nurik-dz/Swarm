import AppKit
import SwiftUI

// Draws single pieces off-screen to find one that renders blank.
let out = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let pieces: [(String, AnyView)] = [
        ("ring-secondary", AnyView(ProgressRing(value: 0.3, tint: .secondary).frame(width: 64, height: 64))),
        ("ring-accent", AnyView(ProgressRing(value: 0.3, tint: .accentColor).frame(width: 64, height: 64))),
        ("label-secondary", AnyView(Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(Color.secondary).symbolEffect(.bounce, value: 1))),
        ("action-plain", AnyView(GlassAction(title: "Show", symbol: "folder") {})),
        ("action-tinted", AnyView(GlassAction(title: "Resume", symbol: "play.fill", tint: .accentColor) {})),
        ("text-only", AnyView(Text("Big Buck Bunny").font(.headline))),
    ]
    for (name, view) in pieces {
        let host = NSHostingView(rootView: view.padding(20).background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        let w = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: 220, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = host
        w.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        // Count non-white pixels: 0 means nothing was drawn.
        var ink = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) { for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 } } }
        print(name, "ink pixels:", ink)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
        w.orderOut(nil)
    }
    exit(0)
}
