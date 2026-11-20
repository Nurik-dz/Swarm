import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(TorrentStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var shelf: Shelf? = .all
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var removing: [Torrent] = []
    @State private var dropTargeted = false
    @AppStorage(Prefs.Key.inspector) private var showInspector = true
    private var appearance = AppearanceModel.shared

    static let sidebarMinWidth: CGFloat = 190
    static let listMinWidth: CGFloat = 320
    static let paneWidth: CGFloat = 300

    private var visible: [Torrent] { store.torrents(in: shelf ?? .all, matching: search) }
    private var selected: [Torrent] { store.torrents.filter { selection.contains($0.id) } }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(shelf: $shelf)
                .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: 220, max: 300)
        } detail: {
            TorrentList(torrents: visible, shelf: shelf ?? .all, searching: !search.isEmpty,
                        selection: $selection, removing: $removing)
                .overlay { if dropTargeted { DropHighlight() } }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let p = model.player { NowPlayingBar(model: p) }
                }
                .frame(minWidth: Self.listMinWidth)
                .background { DetailSurface(seeThrough: appearance.isSeeThrough) }
                .navigationTitle((shelf ?? .all).title)
                .navigationSubtitle(subtitle)
        }
        // Apple's inspector column at one fixed width. The window's minimum
        // width comes from the columns themselves: a .frame(minWidth:) on the
        // window content fought the split view's own minimums and AppKit
        // aborted ("more Update Constraints in Window passes than there are
        // views"). Reproduced and A/B tested in Tests/harness.
        .inspector(isPresented: $showInspector) {
            Inspector(selected: selected, removing: $removing)
                .inspectorColumnWidth(Self.paneWidth)
        }
        .toolbar { toolbar }
        // No separate darker band behind the title: the toolbar sits on the
        // same surface as the columns.
        .toolbarBackgroundVisibility(appearance.isSeeThrough ? .hidden : .automatic, for: .windowToolbar)
        .background { WindowBackdrop(look: appearance.look).ignoresSafeArea() }
        .sheet(item: $model.adding) { request in
            AddSheet(request: request)
        }
        .sheet(item: $model.shareJob) { job in
            ShareSheet(job: job)
        }
        .sheet(item: $model.sendPath) { url in
            SendSheet(path: url)
        }
        .sheet(item: Binding(get: { model.lan.incoming }, set: { _ in })) { inc in
            IncomingSheet(incoming: inc)
        }
        .onChange(of: model.lan.incoming?.id) { _, new in
            // A Mac is asking to send something: make sure the person sees it.
            if new != nil { model.showWindow(); NSApp.requestUserAttention(.criticalRequest) }
        }
        .confirmationDialog("Use these files for \u{201C}\(model.existingOffer?.torrent.displayName ?? "")\u{201D}?",
                            isPresented: Binding(get: { model.existingOffer != nil }, set: { if !$0 { model.existingOffer = nil } }),
                            titleVisibility: .visible) {
            Button("Check and Use Them") {
                if let o = model.existingOffer { store.useExistingFiles(o.torrent.id, at: o.folder) }
                model.existingOffer = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.existingOffer = nil }
        } message: {
            Text("Swarm checks \u{201C}\(model.existingOffer?.dropped ?? "")\u{201D} against the torrent. Whatever is correct is kept where it is; only missing or damaged parts download. Nothing is moved or overwritten.")
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }),
                            titleVisibility: .visible) {
            Button("Remove from List") {
                store.remove(removing.map(\.id), deleteFiles: false)
                removing = []
            }
            .keyboardShortcut(.defaultAction)
            Button("Remove and Move Files to Trash", role: .destructive) {
                trash(removing)
                removing = []
            }
        } message: {
            Text("\u{201C}Remove from List\u{201D} keeps the downloaded files in your Downloads folder.")
        }
        .alert(item: Binding(get: { store.problem }, set: { store.problem = $0 })) { p in
            Alert(title: Text(p.title), message: Text(p.message))
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted) { providers in
            model.receive(providers: providers)
            return true
        }
        .onPasteCommand(of: [.fileURL, .url, .plainText]) { providers in
            model.receive(providers: providers)
        }
        .focusedSceneValue(\.selectedTorrents, selected)
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .onChange(of: store.torrents.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
    }

    private var subtitle: String {
        let active = store.activeCount
        if active > 0 {
            var s = active == 1 ? "1 downloading" : "\(active) downloading"
            s += "  \u{2193} " + Format.speed(store.downRate)
            if store.upRate > 1024 { s += "  \u{2191} " + Format.speed(store.upRate) }
            if store.scheduleActive { s += "  \u{2022} Schedule limit on" }
            return s
        }
        let n = visible.count
        let count = n == 1 ? "1 torrent" : "\(n) torrents"
        return store.scheduleActive ? count + "  \u{2022} Schedule limit on" : count
    }

    private var removeTitle: String {
        removing.count == 1 ? "Remove \u{201C}\(removing[0].displayName)\u{201D}?" : "Remove \(removing.count) torrents?"
    }

    private func trash(_ list: [Torrent]) {
        let ids = list.map(\.id)
        let urls = list.compactMap { $0.contentExists ? $0.contentURL : nil }
        store.pause(ids)
        store.remove(ids, deleteFiles: false)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error {
                Task { @MainActor in store.problem = .init(title: "Couldn't move to the Trash", message: error.localizedDescription) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            let resume = !store.canPauseAll && store.canResumeAll
            Button {
                if resume { store.resumeAll() } else { store.pauseAll() }
            } label: {
                Label(resume ? "Resume All" : "Pause All", systemImage: resume ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!store.canPauseAll && !store.canResumeAll)
            .help(resume ? "Resume all torrents (\u{2325}\u{2318}R)" : "Pause all torrents (\u{2325}\u{2318}P)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            // One action, no menu: the Add window has its own
            // "Open Torrent File…" button.
            Button("Add", systemImage: "plus") { model.newTorrent() }
                .help("Add a torrent (\u{2318}N)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            SearchButton(text: $search)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            // No withAnimation: the inspector column animates itself, and a
            // second animation around it made AppKit's layout loop (crash).
            Button("Details", systemImage: "sidebar.trailing") {
                model.togglePanel()
            }
            .help(showInspector ? "Hide details" : "Show details")
        }
    }
}

/// The list column's surface. With glass, it gets the same glass layer the
/// sidebar and details panel have, so all three columns read as one surface
/// (on the bare window glass it looked darker than the panels beside it).
private struct DetailSurface: View {
    let seeThrough: Bool

    var body: some View {
        if seeThrough {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect)
                .ignoresSafeArea()
        } else {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        }
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.06)))
            .overlay {
                Label("Drop to add", systemImage: "arrow.down.doc")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
            }
            .padding(10)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(TorrentStore.self) private var store
    @Binding var shelf: Shelf?

    var body: some View {
        List(selection: $shelf) {
            Section {
                ForEach(Shelf.allCases) { s in
                    Label(s.title, systemImage: s.symbol)
                        .badge(s == .all ? 0 : store.count(s))
                        .tag(s)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SpeedPanel() }
    }
}

/// Bottom of the sidebar: live speed graph, speeds and free space.
private struct SpeedPanel: View {
    @Environment(TorrentStore.self) private var store
    @State private var freeSpace: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SpeedGraph(samples: store.history)
                .frame(height: 34)
            HStack(spacing: 12) {
                Label(Format.speed(store.downRate), systemImage: "arrow.down")
                    .foregroundStyle(Color.accentColor)
                Label(Format.speed(store.upRate), systemImage: "arrow.up")
                    .foregroundStyle(.green)
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .labelStyle(.titleAndIcon)
            .contentTransition(.numericText())
            Button {
                NSWorkspace.shared.open(Prefs.folder)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Prefs.folder.lastPathComponent).font(.caption.weight(.medium))
                        if let freeSpace {
                            Text("\(Format.bytes(freeSpace)) available").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Open the downloads folder")
        }
        .padding(12)
        .animation(.default, value: store.downRate)
        .task {
            while !Task.isCancelled {
                freeSpace = (try? Prefs.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}
