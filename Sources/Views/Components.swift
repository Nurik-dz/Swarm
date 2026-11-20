import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Thin rounded bar with a smooth fill, coloured by state.
struct ProgressCapsule: View {
    var value: Double
    var tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
                    .opacity(value > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.6), value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

/// Circular progress with the percentage inside (the inspector header).
struct ProgressRing: View {
    var value: Double
    var tint: Color
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
        }
        .animation(.smooth(duration: 0.6), value: value)
    }
}

/// Live speed graph: download filled, upload as a line.
struct SpeedGraph: View {
    var samples: [(down: Int64, up: Int64)]

    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1 else { return }
            let peak = Double(max(samples.map { max($0.down, $0.up) }.max() ?? 1, 64 * 1024))
            let step = size.width / CGFloat(max(samples.count - 1, 1))
            func y(_ v: Int64) -> CGFloat { size.height - CGFloat(Double(v) / peak) * (size.height - 2) - 1 }

            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for (i, s) in samples.enumerated() { area.addLine(to: CGPoint(x: CGFloat(i) * step, y: y(s.down))) }
            area.addLine(to: CGPoint(x: CGFloat(samples.count - 1) * step, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [.accentColor.opacity(0.45), .accentColor.opacity(0.05)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            var down = Path()
            var up = Path()
            for (i, s) in samples.enumerated() {
                let x = CGFloat(i) * step
                if i == 0 { down.move(to: CGPoint(x: x, y: y(s.down))); up.move(to: CGPoint(x: x, y: y(s.up))) }
                else { down.addLine(to: CGPoint(x: x, y: y(s.down))); up.addLine(to: CGPoint(x: x, y: y(s.up))) }
            }
            ctx.stroke(down, with: .color(.accentColor), lineWidth: 1.5)
            ctx.stroke(up, with: .color(.green.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
        .accessibilityHidden(true)
    }
}

/// The real Finder icon: the file type for single files, a folder for packs,
/// a magnet while the file list is still on its way.
struct TorrentIcon: View {
    let torrent: Torrent
    var size: CGFloat = 36

    var body: some View {
        Group {
            if !torrent.hasFileList {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .overlay {
                        Image(systemName: "link")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                            .symbolEffect(.pulse, options: .repeating, isActive: torrent.status == .gettingFileList)
                    }
                    .padding(size * 0.06)
            } else {
                Image(nsImage: Self.icon(for: torrent))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: size, height: size)
    }

    static func icon(for t: Torrent) -> NSImage {
        if let ext = t.fileExtension, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .folder)
    }
}

/// Round icon-only button used on rows.
struct RoundButton: View {
    let symbol: String
    let help: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .foregroundStyle(prominent ? Color.white : (hover ? Color.primary : Color.secondary))
                .background(Circle().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(hover ? 1 : 0.6))))
                .contentShape(Circle())
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(PressScale())
        .animation(.smooth(duration: 0.2), value: hover)
        .animation(.smooth(duration: 0.25), value: prominent)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shrinks a little while pressed, springs back on release.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// Round glass action with its name underneath (the inspector's row).
struct GlassAction: View {
    let title: String
    let symbol: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint ?? .primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    // The colour goes on the icon, not into the glass: tinted glass
                    // blanked the whole panel header in the paused state.
                    .glassEffect(.regular.interactive(), in: .circle)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)   // share the row evenly, never overflow
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(title)
    }
}

/// GlassAction that opens a menu (the panel's "More").
struct GlassMenuAction<Items: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(PressScale())
        .menuIndicator(.hidden)
        .help(title)
    }
}

extension Torrent.Status {
    var tint: Color {
        switch self {
        case .downloading, .gettingFileList, .checking: .accentColor
        case .done, .sharing: .green
        case .queued: .secondary
        case .paused, .choosingFiles: .secondary
        case .failed: .red
        }
    }

    var symbol: String {
        switch self {
        case .downloading: "arrow.down.circle.fill"
        case .queued: "clock"
        case .gettingFileList: "antenna.radiowaves.left.and.right"
        case .checking: "checklist"
        case .choosingFiles: "checklist.unchecked"
        case .done: "checkmark.circle.fill"
        case .sharing: "checkmark.circle.fill"   // finished; sharing is secondary
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
