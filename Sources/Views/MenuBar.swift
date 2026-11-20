import SwiftUI
import AppKit

/// Menu bar icon: an arrow that fills a ring as torrents download.
struct MenuBarLabel: View {
    let store: TorrentStore

    var body: some View {
        let p = store.overallProgress
        Image(nsImage: Self.image(progress: p.map { ($0 * 20).rounded() / 20 }))
            .accessibilityLabel(p == nil ? "Swarm" : "Swarm, \(Int((p ?? 0) * 100)) percent downloaded")
    }

    static func image(progress: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let ring = rect.insetBy(dx: 1.5, dy: 1.5)
            NSColor.black.setStroke()
            if let progress {
                let track = NSBezierPath(ovalIn: ring)
                track.lineWidth = 1.6
                NSColor.black.withAlphaComponent(0.3).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: ring.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * CGFloat(max(progress, 0.03)), clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            } else {
                let circle = NSBezierPath(ovalIn: ring)
                circle.lineWidth = 1.6
                circle.stroke()
            }
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: rect.midX, y: rect.maxY - 5))
            arrow.line(to: NSPoint(x: rect.midX, y: rect.minY + 5))
            arrow.move(to: NSPoint(x: rect.midX - 3.2, y: rect.minY + 8.2))
            arrow.line(to: NSPoint(x: rect.midX, y: rect.minY + 5))
            arrow.line(to: NSPoint(x: rect.midX + 3.2, y: rect.minY + 8.2))
            arrow.lineWidth = 1.7
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            NSColor.black.setStroke()
            arrow.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(TorrentStore.self) private var store

    /// Downloading first, then the most recent.
    private var shown: [Torrent] {
        let active = store.torrents.filter { $0.status.isActive || $0.status == .choosingFiles }
        let rest = store.torrents.filter { !($0.status.isActive || $0.status == .choosingFiles) }
        return Array((active + rest).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Swarm").font(.headline)
                Spacer()
                HStack(spacing: 10) {
                    Label(Format.speed(store.downRate), systemImage: "arrow.down").foregroundStyle(Color.accentColor)
                    Label(Format.speed(store.upRate), systemImage: "arrow.up").foregroundStyle(.green)
                }
                .font(.caption.weight(.medium))
                .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.dotted").font(.title).foregroundStyle(.secondary)
                    Text("No torrents yet").font(.callout.weight(.medium))
                    Text("Copy a magnet link, then click Paste.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 2) {
                    ForEach(shown) { t in MiniRow(torrent: t) }
                }
                .padding(.horizontal, 6)
            }

            Divider().padding(.vertical, 6)

            HStack(spacing: 8) {
                PasteButton(payloadType: String.self) { strings in
                    model.receive(text: strings.joined(separator: "\n"))
                }
                .controlSize(.small)
                if store.canPauseAll {
                    Button("Pause All", systemImage: "pause.fill") { store.pauseAll() }
                } else if store.canResumeAll {
                    Button("Resume All", systemImage: "play.fill") { store.resumeAll() }
                }
                Spacer()
                Button("Open Swarm") { model.showWindow() }
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Swarm")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .frame(width: 330)
    }
}

private struct MiniRow: View {
    @Environment(AppModel.self) private var model
    let torrent: Torrent
    @State private var hover = false

    var body: some View {
        Button {
            if torrent.status == .choosingFiles { model.chooseFiles(for: torrent.id) }
            else if torrent.contentExists, let u = torrent.contentURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            else { model.showWindow() }
        } label: {
            HStack(spacing: 10) {
                TorrentIcon(torrent: torrent, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(torrent.displayName).font(.callout).lineLimit(1).truncationMode(.middle)
                    if torrent.status == .downloading {
                        ProgressCapsule(value: torrent.progress, tint: .accentColor, height: 3)
                    }
                    Text(caption).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var caption: String {
        switch torrent.status {
        case .downloading where torrent.isStarting: "Finding people sharing…"
        case .downloading: "\(Int(torrent.progress * 100))%  \u{2193} \(Format.speed(torrent.downRate))"
        case .choosingFiles: "Choose files to start"
        case .done, .sharing: "Done"
        default: torrent.status.title
        }
    }
}
