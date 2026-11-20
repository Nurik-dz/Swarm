import AppKit

/// A progress bar across the app icon in the Dock while torrents download,
/// as Finder and Safari do, plus the number still downloading.
@MainActor
final class DockProgress {
    static let shared = DockProgress()

    private let view = DockTileView()
    private var shown: Double?? = .none
    private var badge: String?

    func update(progress: Double?, active: Int) {
        let tile = NSApp.dockTile
        let newBadge = active > 0 ? "\(active)" : nil
        if newBadge != badge {
            tile.badgeLabel = newBadge
            badge = newBadge
        }
        let rounded = progress.map { ($0 * 100).rounded() / 100 }
        if case .some(let old) = shown, old == rounded { return }
        shown = .some(rounded)
        if let rounded {
            view.fraction = rounded
            if tile.contentView !== view {
                view.frame = NSRect(origin: .zero, size: tile.size)
                tile.contentView = view
            }
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

private final class DockTileView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let inset = bounds.width * 0.15
        let h = bounds.height * 0.08
        let track = NSRect(x: inset, y: bounds.height * 0.11, width: bounds.width - inset * 2, height: h)
        let r = h / 2
        NSColor.black.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: track.insetBy(dx: -1.5, dy: -1.5), xRadius: r + 1.5, yRadius: r + 1.5).fill()
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
        var bar = track
        bar.size.width = max(h, track.width * CGFloat(min(max(fraction, 0), 1)))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).fill()
    }
}
