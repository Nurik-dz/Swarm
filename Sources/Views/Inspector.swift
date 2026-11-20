import SwiftUI
import AppKit

/// Right-hand panel: everything about the selected torrent.
struct Inspector: View {
    @Environment(TorrentStore.self) private var store
    let selected: [Torrent]
    @Binding var removing: [Torrent]

    var body: some View {
        Group {
            if selected.isEmpty {
                ContentUnavailableView("No Selection", systemImage: "sidebar.trailing",
                                       description: Text("Select a torrent to see its files and details."))
            } else if selected.count == 1, let t = selected.first {
                Details(torrent: t, removing: $removing)
                    .id(t.id)
            } else {
                many
            }
        }
    }

    private var many: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(selected.count) Torrents").font(.title3.weight(.semibold))
            Text(Format.bytes(selected.reduce(0) { $0 + $1.wanted })).foregroundStyle(.secondary)
            HStack {
                if selected.contains(where: \.canPause) {
                    Button("Pause", systemImage: "pause.fill") { store.pause(selected.map(\.id)) }
                }
                if selected.contains(where: \.canResume) {
                    Button("Resume", systemImage: "play.fill") { store.resume(selected.map(\.id)) }
                }
                Button("Remove…", systemImage: "trash") { removing = selected }
            }
            .buttonStyle(.glass)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Details: View {
    @Environment(AppModel.self) private var model
    @Environment(TorrentStore.self) private var store
    let torrent: Torrent
    @Binding var removing: [Torrent]
    @State private var chosen: Set<Int> = []
    @State private var loadedChoice = false
    @State private var showSkipped = false

    var body: some View {
        let t = torrent
        let files = t.hasFileList ? store.files(of: t.id) : []
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(t)
                buttons(t)
                if t.status == .choosingFiles {
                    Button("Choose Files…") { model.chooseFiles(for: t.id) }
                        .buttonStyle(.glassProminent)
                        .frame(maxWidth: .infinity)
                }
                healthCard(t)
                if let error = t.error, t.status == .failed, store.diagnosis(for: t) == nil {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if !files.isEmpty && t.status != .choosingFiles {
                    filesSection(t, files)
                }
                detailsSection(t)
                if t.hasFileList { PeersPanel(torrent: t) }
                if t.hasFileList && !t.status.isFinished {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Download in order", isOn: Binding(get: { t.sequential }, set: { store.setSequential(t.id, $0) }))
                            .toggleStyle(.switch)
                        Text("Gets the start of each file first, so a video can play before it finishes. Usually a little slower overall.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)   // never wider than the panel
        }
        .scrollContentBackground(.hidden)
        .transition(.opacity)
        .onAppear { syncChoice(files) }
        .onChange(of: files.map(\.wanted)) { _, _ in if !loadedChoice { syncChoice(files) } }
    }

    /// Why it is slow or stuck, how much of the rest is available, and what Swarm did.
    @ViewBuilder
    private func healthCard(_ t: Torrent) -> some View {
        let d = store.diagnosis(for: t)
        let f = Rescue.feasibility(t, health: store.health[t.id])
        let log = store.rescueLog[t.id] ?? []
        if d != nil || f != nil || !log.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let d {
                    Label(d.title, systemImage: d.symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(d.tint)
                    Text(d.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let a = d.action { rescueButton(a, t) }
                }
                if let f {
                    Label(f.text, systemImage: f.good ? "checkmark.circle" : "circle.dotted")
                        .font(.caption).foregroundStyle(f.good ? Color.green : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !log.isEmpty {
                    DisclosureGroup("What Swarm did") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
            .animation(.smooth(duration: 0.3), value: d)
        }
    }

    @ViewBuilder
    private func rescueButton(_ a: Diagnosis.Action, _ t: Torrent) -> some View {
        switch a {
        case .askTrackers:
            Button("Ask Trackers Again", systemImage: "arrow.clockwise") { store.askTrackersAgain(t.id) }
                .buttonStyle(.glass).controlSize(.small)
        case .checkFiles:
            Button("Check Files Again", systemImage: "checkmark.arrow.trianglehead.counterclockwise") { store.recheck(t.id) }
                .buttonStyle(.glass).controlSize(.small)
        case .chooseFolder:
            SettingsLink { Label("Open Settings", systemImage: "gearshape") }
                .buttonStyle(.glass).controlSize(.small)
        }
    }

    private func syncChoice(_ files: [TorrentFile]) {
        guard !files.isEmpty else { return }
        chosen = Set(files.filter(\.wanted).map(\.index))
        loadedChoice = true
    }

    private func header(_ t: Torrent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if t.status.isFinished {
                    TorrentIcon(torrent: t, size: 64)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    ProgressRing(value: t.progress, tint: t.status.tint)
                        .frame(width: 64, height: 64)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.5, bounce: 0.3), value: t.status.isFinished)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.displayName)
                    .font(.headline)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Label(t.status.title, systemImage: t.status.symbol)
                    .font(.callout)
                    .foregroundStyle(t.status.tint)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce, value: t.status)
                    .contentTransition(.symbolEffect(.replace))
                if t.isStarting {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let reason = t.startupReason(after: store.startingFor(t))
                        Text(reason ?? t.startupLine)
                            .font(.caption)
                            .foregroundStyle(reason == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if t.status == .downloading {
                    Text(timeLeftText(t)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else if t.isUploading {
                    Text("Sharing with others \u{2191} \(Format.speed(t.upRate))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func timeLeftText(_ t: Torrent) -> String {
        if let left = store.timeLeft(t) { return Format.timeLeft(left) }
        if t.downRate > 1024 { return "Working out the time left…" }
        return t.peers > 0 ? "Waiting for data from \(Format.peers(t.peers, swarm: 0))" : "Lost all connections, looking for people sharing"
    }

    /// At most four round actions so the row always fits the panel; the rest
    /// live in More. Each state shows only what makes sense for it.
    private func buttons(_ t: Torrent) -> some View {
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                if t.canPause {
                    GlassAction(title: "Pause", symbol: "pause.fill") { store.pause([t.id]) }
                } else if t.canResume {
                    GlassAction(title: "Resume", symbol: "play.fill", tint: .accentColor) { store.resume([t.id]) }
                } else if t.status.isFinished, t.isSingleFile, t.contentExists {
                    GlassAction(title: "Open", symbol: "arrow.up.forward.app", tint: .accentColor) {
                        if let u = t.contentURL { NSWorkspace.shared.open(u) }
                    }
                }
                if t.contentExists {
                    GlassAction(title: "Show", symbol: "folder") {
                        if let u = t.contentURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                    }
                }
                if t.status.isFinished, t.contentExists {
                    GlassAction(title: "Preview", symbol: "eye") { QuickLook.shared.toggle([t.contentURL!]) }
                }
                GlassMenuAction(title: "More", symbol: "ellipsis") { moreMenu(t) }
            }
        }
        .animation(.smooth(duration: 0.3), value: t.status)
    }

    @ViewBuilder
    private func moreMenu(_ t: Torrent) -> some View {
        if t.canStopSharing {
            Button("Stop Sharing", systemImage: "stop.circle") { store.stopSharing([t.id]) }
        } else if t.canShareAgain {
            Button("Share Again", systemImage: "arrow.up.circle") { store.shareAgain([t.id]) }
        }
        if t.status.isFinished, t.contentExists, let url = t.contentURL {
            Button("Send to Nearby Mac\u{2026}", systemImage: "paperplane") { model.sendToNearbyMac(url) }
        }
        Button("Copy Magnet Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(store.magnet(t.id) ?? "", forType: .string)
        }
        if t.hasFileList {
            Button("Check Files Again", systemImage: "arrow.clockwise") { store.recheck(t.id) }
            Button("Use Files I Already Have\u{2026}", systemImage: "folder.badge.gearshape") {
                if let folder = ExistingFiles.pickFolder(for: t) { store.useExistingFiles(t.id, at: folder) }
            }
        }
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive) { removing = [t] }
    }

    private func filesSection(_ t: Torrent, _ files: [TorrentFile]) -> some View {
        let skippedCount = files.count - chosen.count
        // Only what is downloading, unless asked: a torrent with 1,200 files
        // and three chosen should show three.
        let shown = files.filter { chosen.contains($0.index) || showSkipped }
            .sorted { chosen.contains($0.index) && !chosen.contains($1.index) }
        let rows = Array(shown.prefix(200))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files").font(.subheadline.weight(.semibold))
                Spacer()
                Text(skippedCount > 0 ? "\(chosen.count) of \(files.count) chosen" : "\(files.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(rows) { f in
                    fileRow(f, t)
                    if f.id != rows.last?.id { Divider().padding(.leading, 30) }
                }
                if shown.count > rows.count {
                    Text("and \(shown.count - rows.count) more").font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
            if skippedCount > 0 {
                Button(showSkipped ? "Hide \(skippedCount.formatted()) skipped files" : "Show \(skippedCount.formatted()) skipped files") {
                    showSkipped.toggle()
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func fileRow(_ f: TorrentFile, _ t: Torrent) -> some View {
        HStack(spacing: 8) {
            let on = chosen.contains(f.index)
            Button {
                if on { chosen.remove(f.index) } else { chosen.insert(f.index) }
                store.setWanted(t.id, files: Array(chosen))
            } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(on && chosen.count == 1)   // keep at least one file
            .help(on ? "Skip this file" : "Download this file")
            VStack(alignment: .leading, spacing: 3) {
                Text(f.name).font(.callout).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if chosen.contains(f.index) && f.progress < 1 {
                        ProgressCapsule(value: f.progress, tint: .accentColor, height: 3)
                    }
                    Text(chosen.contains(f.index) ? (f.progress >= 1 ? Format.bytes(f.size) : "\(Int(f.progress * 100))% of \(Format.bytes(f.size))") : "Skipped, \(Format.bytes(f.size))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize()
                }
            }
            Spacer(minLength: 4)
            if chosen.contains(f.index), f.progress < 1, canPlayEarly(t),
               TorrentStream.contentType(forExtension: f.ext) != nil {
                Button {
                    play(f, in: t)
                } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .help(f.kind == .audio ? "Listen while it downloads" : "Play while it downloads")
            }
            if chosen.contains(f.index), f.progress >= 1,
               FileManager.default.fileExists(atPath: URL(fileURLWithPath: t.savePath).appendingPathComponent(f.path).path) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: t.savePath).appendingPathComponent(f.path))
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .opacity(chosen.contains(f.index) ? 1 : 0.6)
    }

    private func canPlayEarly(_ t: Torrent) -> Bool {
        t.status == .downloading || t.status == .paused || t.status == .queued
    }

    private func play(_ f: TorrentFile, in t: Torrent) {
        if t.canResume { store.resume([t.id]) }
        if !chosen.contains(f.index) { chosen.insert(f.index); store.setWanted(t.id, files: Array(chosen)) }
        model.play(f, of: t)
    }

    private func detailsSection(_ t: Torrent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Details").font(.subheadline.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                if t.hasFileList { row("Size", sizeText(t)) }
                if !t.status.isFinished && t.status != .choosingFiles {
                    row("Downloaded", t.wantedDone == 0 ? "Nothing yet" : "\(Format.bytes(min(t.wantedDone, t.chosenSize))) of \(Format.bytes(t.chosenSize))")
                }
                if t.uploaded > 0 {
                    row("Shared", "\(Format.bytes(t.uploaded)) (\(Format.ratio(t.ratio))\u{00D7} the download)")
                }
                if t.status.isActive {
                    row("Speed", "\u{2193} \(Format.speed(t.downRate))   \u{2191} \(Format.speed(t.upRate))")
                    row("People", peopleText(t))
                    if t.trackers > 0 {
                        row("Trackers", trackersText(t))
                    }
                } else if t.isUploading {
                    row("Sharing", t.peers > 0 ? "\u{2191} \(Format.speed(t.upRate)) to \(t.peers == 1 ? "1 person" : "\(t.peers) people")" : "\u{2191} \(Format.speed(t.upRate))")
                }
                row("Added", Format.date(t.added))
                if let c = t.completed { row("Finished", Format.date(c)) }
                GridRow {
                    Text("Saved in").foregroundStyle(.secondary)
                    Button(URL(fileURLWithPath: t.savePath).lastPathComponent) {
                        NSWorkspace.shared.activateFileViewerSelecting([t.contentExists ? t.contentURL! : URL(fileURLWithPath: t.savePath)])
                    }
                    .buttonStyle(.link)
                }
                GridRow {
                    Text("Hash").foregroundStyle(.secondary)
                    Text(t.id.uppercased())
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(t.id)
                }
            }
            .font(.callout)
            .monospacedDigit()
        }
    }

    private func peopleText(_ t: Torrent) -> String {
        if t.peers > 0 { return "\(t.peers) connected, \(t.seeds) of them have everything" }
        if t.knownPeers > 0 { return "\(t.knownPeers) found, connecting" }
        return "Looking"
    }

    private func trackersText(_ t: Torrent) -> String {
        var text = "\(t.trackersAnswered) of \(t.trackers) answered"
        if t.trackersFailed > 0 { text += ", \(t.trackersFailed) not reachable" }
        return text
    }

    /// Exact sizes from the files chosen (libtorrent's own total is rounded to whole pieces).
    private func sizeText(_ t: Torrent) -> String {
        let files = store.files(of: t.id)
        let chosenFiles = files.filter { chosen.contains($0.index) }
        let size = chosenFiles.reduce(Int64(0)) { $0 + $1.size }
        if chosenFiles.count == files.count { return Format.bytes(size) }
        return "\(Format.bytes(size)) chosen of \(Format.bytes(t.totalSize))"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}


enum ExistingFiles {
    /// The folder that holds this torrent's top-level file or folder.
    @MainActor
    static func pickFolder(for t: Torrent) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder that contains \u{201C}\(t.displayName)\u{201D}. Swarm checks what is there and downloads only what's missing."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
