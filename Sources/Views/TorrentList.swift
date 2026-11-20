import SwiftUI
import AppKit

struct TorrentList: View {
    @Environment(AppModel.self) private var model
    @Environment(TorrentStore.self) private var store
    let torrents: [Torrent]
    let shelf: Shelf
    let searching: Bool
    @Binding var selection: Set<String>
    @Binding var removing: [Torrent]

    private var seeThrough: Bool { AppearanceModel.shared.isSeeThrough }

    var body: some View {
        ZStack {
            if torrents.isEmpty {
                EmptyState(shelf: shelf, searching: searching, anyTorrents: !store.torrents.isEmpty)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                list.transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: torrents.isEmpty)
    }

    private var list: some View {
            List(selection: $selection) {
                ForEach(torrents) { t in
                    TorrentRow(torrent: t)
                        .tag(t.id)
                        .onDrag { dragItem(t) }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(seeThrough ? .hidden : .visible)
            .animation(.smooth(duration: 0.35), value: torrents.map(\.id))
            .contextMenu(forSelectionType: String.self) { ids in
                menu(for: store.torrents.filter { ids.contains($0.id) })
            } primaryAction: { ids in
                open(store.torrents.filter { ids.contains($0.id) })
            }
            .onKeyPress(.space) {
                QuickLook.shared.toggle(selected.compactMap(\.contentURL))
                return .handled
            }
            .onDeleteCommand { removing = selected }
    }

    private var selected: [Torrent] { store.torrents.filter { selection.contains($0.id) } }

    private func open(_ list: [Torrent]) {
        for t in list {
            if t.status == .choosingFiles { model.chooseFiles(for: t.id) }
            else if t.contentExists, let url = t.contentURL { NSWorkspace.shared.open(url) }
        }
    }

    /// Drag a finished download straight into Finder or another app.
    private func dragItem(_ t: Torrent) -> NSItemProvider {
        guard t.contentExists, let url = t.contentURL else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    @ViewBuilder
    private func menu(for list: [Torrent]) -> some View {
        let ids = list.map(\.id)
        if list.contains(where: \.contentExists) {
            Button("Open", systemImage: "arrow.up.forward.app") { open(list) }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(list.compactMap { $0.contentExists ? $0.contentURL : nil })
            }
            Button("Quick Look", systemImage: "eye") { QuickLook.shared.toggle(list.compactMap(\.contentURL)) }
            if list.count == 1, list[0].status.isFinished, let url = list[0].contentURL {
                Button("Send to Nearby Mac\u{2026}", systemImage: "paperplane") { model.sendToNearbyMac(url) }
            }
            Divider()
        }
        if list.count == 1, list[0].status == .choosingFiles {
            Button("Choose Files…", systemImage: "checklist") { model.chooseFiles(for: list[0].id) }
        }
        if list.contains(where: \.canPause) {
            Button("Pause", systemImage: "pause") { store.pause(ids) }
        }
        if list.contains(where: \.canResume) {
            Button("Resume", systemImage: "play") { store.resume(ids) }
        }
        if list.contains(where: \.canStopSharing) {
            Button("Stop Sharing", systemImage: "stop.circle") { store.stopSharing(ids) }
        }
        if list.contains(where: \.canShareAgain) {
            Button("Share Again", systemImage: "arrow.up.circle") { store.shareAgain(ids) }
        }
        if list.count == 1, list[0].hasFileList, !list[0].status.isFinished {
            Toggle("Download in Order", isOn: Binding(get: { list[0].sequential }, set: { store.setSequential(list[0].id, $0) }))
        }
        Divider()
        Button("Copy Magnet Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ids.compactMap { store.magnet($0) }.joined(separator: "\n"), forType: .string)
        }
        Button("Check Files Again", systemImage: "arrow.clockwise") { ids.forEach(store.recheck) }
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive) { removing = list }
    }
}

// MARK: - Row

struct TorrentRow: View {
    @Environment(AppModel.self) private var model
    @Environment(TorrentStore.self) private var store
    let torrent: Torrent

    var body: some View {
        HStack(spacing: 12) {
            TorrentIcon(torrent: torrent, size: 38)
                .overlay(alignment: .bottomTrailing) { badge }
            VStack(alignment: .leading, spacing: 5) {
                Text(torrent.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                bar
                StatusLine(torrent: torrent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.4), value: torrent.status)
        .accessibilityElement(children: .combine)
    }

    /// Small status mark on the icon; bounces when the torrent finishes.
    @ViewBuilder
    private var badge: some View {
        let s = torrent.status
        if s == .done || s == .sharing || s == .paused || s == .failed {
            Image(systemName: s.symbol)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, s.tint == .secondary ? Color.gray : s.tint)
                .background(Circle().fill(.background).padding(1))
                .offset(x: 4, y: 4)
                .symbolEffect(.bounce, value: s)
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var bar: some View {
        switch torrent.status {
        case .gettingFileList:
            ProgressView().progressViewStyle(.linear).controlSize(.small).frame(height: 5)
                .transition(.opacity)
        case .downloading where torrent.isStarting:
            // Still finding people: a moving bar, never a frozen one at 0.
            ProgressView().progressViewStyle(.linear).controlSize(.small).frame(height: 5)
                .transition(.opacity)
        case .done, .sharing, .choosingFiles:
            EmptyView()
        default:
            ProgressCapsule(value: torrent.progress, tint: torrent.status.tint)
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.6, anchor: .leading))))
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch torrent.status {
            case .choosingFiles:
                Button("Choose Files…") { model.chooseFiles(for: torrent.id) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            case .downloading, .gettingFileList, .checking, .queued, .paused, .failed:
                let paused = torrent.canResume
                RoundButton(symbol: paused ? "play.fill" : "pause.fill", help: paused ? "Resume" : "Pause", prominent: paused) {
                    if paused { store.resume([torrent.id]) } else { store.pause([torrent.id]) }
                }
            case .done, .sharing:
                // Finished: the file is the point now, not the transfer.
                if torrent.isSingleFile && torrent.contentExists {
                    RoundButton(symbol: "arrow.up.forward.app", help: "Open") {
                        if let url = torrent.contentURL { NSWorkspace.shared.open(url) }
                    }
                }
            }
            if torrent.contentExists {
                RoundButton(symbol: "magnifyingglass", help: "Show in Finder") {
                    if let url = torrent.contentURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }
    }
}

/// One line of plain words about where the torrent is.
struct StatusLine: View {
    @Environment(TorrentStore.self) private var store
    let torrent: Torrent

    var body: some View {
        if torrent.isStarting {
            // Ticks every second so the wait is never silent.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let waited = store.startingFor(torrent)
                let reason = torrent.startupReason(after: waited)
                Text((reason ?? torrent.startupLine) + (waited >= 3 ? "  \(Int(waited)) s" : ""))
                    .font(.caption)
                    .foregroundStyle(reason == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(reason ?? torrent.startupLine)
            }
        } else {
            Text(text)
                .font(.caption)
                .foregroundStyle(torrent.status == .failed ? AnyShapeStyle(.red)
                                 : (torrent.status == .downloading ? store.diagnosis(for: torrent).map { AnyShapeStyle($0.tint) } : nil) ?? AnyShapeStyle(.secondary))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }

    private var text: String {
        let t = torrent
        switch t.status {
        case .gettingFileList:
            return t.peers > 0 ? "Getting the file list from \(Format.peers(t.peers, swarm: 0))…" : "Looking for people sharing this…"
        case .checking:
            return "Checking files… \(Int(t.progress * 100))%"
        case .choosingFiles:
            return "\(t.fileCount) files, \(Format.bytes(t.totalSize)). Choose what to download"
        case .queued:
            return "Waiting for a free slot \u{2014} Swarm downloads 4 at a time"
        case .downloading:
            var parts = ["\(Format.bytes(min(t.wantedDone, t.chosenSize))) of \(Format.bytes(t.chosenSize))"]
            if t.downRate > 1024 {
                parts.append(Format.speed(t.downRate))
                parts.append(store.timeLeft(t).map(Format.timeLeft) ?? "Working out the time left")
            } else {
                // Had data before, none this moment.
                parts.append(t.peers == 0 ? "Lost all connections, looking for people sharing" : "Waiting for data from \(Format.peers(t.peers, swarm: 0))")
            }
            if let d = store.diagnosis(for: t), d.level != .info { return d.title }
            return parts.joined(separator: " \u{2014} ")
        case .done, .sharing:
            return t.finishedLine
        case .paused:
            return "Paused \u{2014} \(Format.bytes(min(t.wantedDone, t.chosenSize))) of \(Format.bytes(t.chosenSize))"
        case .failed:
            return t.error ?? "Something went wrong. Click Resume to try again."
        }
    }
}

// MARK: - Empty states

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false
    let shelf: Shelf
    let searching: Bool
    let anyTorrents: Bool

    var body: some View {
        if searching {
            ContentUnavailableView.search
        } else if anyTorrents {
            ContentUnavailableView(emptyTitle, systemImage: shelf.symbol, description: Text(emptyMessage))
        } else {
            welcome
        }
    }

    private var emptyTitle: String {
        switch shelf {
        case .downloading: "Nothing Downloading"
        case .done: "Nothing Finished Yet"
        case .paused: "Nothing Paused"
        case .all: "No Torrents"
        }
    }

    private var emptyMessage: String {
        switch shelf {
        case .downloading: "Torrents that are downloading appear here."
        case .done: "Finished downloads appear here, ready to open."
        case .paused: "Paused torrents and ones that hit a problem appear here."
        case .all: ""
        }
    }

    /// First launch: what to do, and the buttons to do it.
    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor.gradient)
                .symbolEffect(.bounce, value: appeared)
                .onAppear { appeared = true }
            VStack(spacing: 6) {
                Text("Add Your First Torrent").font(.title2.weight(.semibold))
                Text("Paste a magnet link, or drop a .torrent file anywhere in this window.\nYou choose which files to download before anything starts.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    model.receive(text: strings.joined(separator: "\n"))
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                Button("Open Torrent File…") { model.openTorrentFilePanel() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            Text("Tip: press \u{2318}V anywhere in Swarm to add a copied magnet link.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
