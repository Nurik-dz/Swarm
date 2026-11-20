import SwiftUI
import AppKit

/// Add a magnet link, wait for the file list, choose files, start.
struct AddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(TorrentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var request: AppModel.AddRequest
    @State private var text = ""
    @State private var chosen: Set<Int> = []
    @State private var choiceMade = false
    @State private var existingFolder: URL?
    @State private var waitingSince = Date()
    @FocusState private var fieldFocused: Bool

    private var torrent: Torrent? { request.hash.flatMap(store.torrent) }

    /// 0 link, 1 waiting for the file list, 2 choosing.
    private var stage: Int { request.hash == nil ? 0 : (torrent?.hasFileList == true ? 2 : 1) }

    var body: some View {
        VStack(spacing: 0) {
            if let hash = request.hash {
                if let t = torrent, t.hasFileList {
                    choose(t, hash: hash)
                        .transition(.blurReplace)
                } else {
                    waiting(hash: hash)
                        .transition(.blurReplace)
                }
            } else {
                enterLink
                    .transition(.blurReplace)
            }
        }
        .frame(width: 580)
        .animation(.smooth(duration: 0.45), value: stage)
        .onAppear { text = request.text }
    }

    // MARK: 1. The link

    private var magnets: [String] { AppModel.magnets(in: text) }

    private var enterLink: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(symbol: "link", title: "Add Magnet Link",
                   subtitle: "Paste a link that starts with \u{201C}magnet:\u{201D}.")
            HStack(spacing: 8) {
                TextField("magnet:?xt=urn:btih:…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(fieldFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2))
                PasteButton(payloadType: String.self) { strings in
                    text = strings.joined(separator: "\n")
                }
                .labelStyle(.iconOnly)
                .help("Paste")
            }
            if !text.isEmpty && magnets.isEmpty {
                Label("That doesn't look like a magnet link.", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            } else if magnets.count > 1 {
                Label("\(magnets.count) magnet links: all of them will start downloading.", systemImage: "square.stack")
                    .font(.callout).foregroundStyle(.secondary)
            }
            footer {
                Button("Open Torrent File…") {
                    dismiss()
                    model.openTorrentFilePanel()
                }
                .buttonStyle(.glass)
            } trailing: {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { addLink() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(magnets.isEmpty)
            }
        }
        .padding(24)
        .onAppear { fieldFocused = true }
    }

    private func addLink() {
        let list = magnets
        if list.count == 1 && Prefs.chooseFiles {
            let isNew = !store.torrents.contains { list[0].lowercased().contains($0.id) }
            if let hash = store.add(magnet: list[0], chooseFiles: true) {
                waitingSince = Date()
                request.hash = hash
                request.addedHere = isNew
            }
        } else {
            for m in list { store.add(magnet: m, chooseFiles: false) }
            dismiss()
        }
    }

    // MARK: 2. Waiting for the file list

    private func waiting(hash: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(symbol: "antenna.radiowaves.left.and.right",
                   title: torrent?.displayName ?? "Getting the file list",
                   subtitle: "Asking people who share this torrent which files it contains…")
            VStack(alignment: .leading, spacing: 8) {
                ProgressView().progressViewStyle(.linear)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let seconds = Int(ctx.date.timeIntervalSince(waitingSince))
                    HStack {
                        Text(torrent.map { $0.peers > 0 ? "Connected to \(Format.peers($0.peers, swarm: 0))" : "Looking for peers" } ?? "Starting")
                        Spacer()
                        Text("\(seconds) s")
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if seconds > 30 {
                        Text("This can take a few minutes when only a few people are sharing. You can close this window: the torrent stays in the list and asks again when its files are known.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            footer {
                Button("Download Everything") {
                    store.startAll(hash)
                    request.addedHere = false
                    dismiss()
                }
                .buttonStyle(.glass)
                .help("Skip choosing: every file in the torrent will download")
            } trailing: {
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Close") {
                    request.addedHere = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    // MARK: 3. Choosing files

    private func choose(_ t: Torrent, hash: String) -> some View {
        let files = store.files(of: hash)
        return VStack(alignment: .leading, spacing: 0) {
            header(icon: t, title: t.displayName,
                   subtitle: "\(files.count == 1 ? "1 file" : "\(files.count) files"), \(Format.bytes(t.totalSize))")
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 14)
            FileChooser(files: files, chosen: $chosen)
                .frame(height: min(CGFloat(files.count) * 34 + 60, 340))
            Divider()
            footer {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary(files)).font(.callout.weight(.medium)).monospacedDigit()
                    if let w = spaceWarning(files), existingFolder == nil {
                        Label(w, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.red).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else if let f = existingFolder {
                        Label("Using files already in \(f.lastPathComponent)", systemImage: "folder.badge.gearshape")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(destinationLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(existingFolder == nil ? "I already have some of these files\u{2026}" : "Choose a different folder\u{2026}") {
                        if let folder = ExistingFiles.pickFolder(for: t) {
                            existingFolder = folder
                            // Checked right away, while nothing is chosen yet: no placeholder
                            // files appear in the usual download folder.
                            store.useExistingFiles(hash, at: folder)
                        }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            } trailing: {
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") {
                    store.start(hash, files: Array(chosen))
                    request.addedHere = false
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || (spaceWarning(files) != nil && existingFolder == nil))
            }
            .padding(24)
        }
        .onAppear {
            guard !choiceMade else { return }
            choiceMade = true
            chosen = Set(files.map(\.index))
        }
    }

    private func summary(_ files: [TorrentFile]) -> String {
        let size = files.filter { chosen.contains($0.index) }.reduce(Int64(0)) { $0 + $1.size }
        return "\(chosen.count) of \(files.count) chosen, \(Format.bytes(size))"
    }

    private func chosenSize(_ files: [TorrentFile]) -> Int64 {
        files.filter { chosen.contains($0.index) }.reduce(Int64(0)) { $0 + $1.size }
    }

    private var destinationLine: String {
        let free = Rescue.freeSpace(at: Prefs.folder.path).map { ", \(Format.bytes($0)) free" } ?? ""
        return "Saving to \(Prefs.folder.lastPathComponent)\(free)"
    }

    /// Stops a download that cannot fit before it starts. A small margin
    /// covers the file system's own overhead.
    private func spaceWarning(_ files: [TorrentFile]) -> String? {
        let need = chosenSize(files)
        guard need > 0, let free = Rescue.freeSpace(at: Prefs.folder.path) else { return nil }
        let margin = max(need / 100, 50_000_000)
        guard free < need + margin else { return nil }
        return "Needs \(Format.bytes(need)) but only \(Format.bytes(free)) is free in \(Prefs.folder.lastPathComponent). Choose fewer files or another folder in Settings."
    }

    private func cancel() {
        // Never delete files in a folder the person pointed us at: they are theirs.
        if request.addedHere, let hash = request.hash { store.remove([hash], deleteFiles: existingFolder == nil) }
        dismiss()
    }

    // MARK: Pieces

    private func header(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.gradient))
            titles(title, subtitle)
        }
    }

    private func header(icon t: Torrent, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            TorrentIcon(torrent: t, size: 46)
            titles(title, subtitle)
        }
    }

    private func titles(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold)).lineLimit(2).truncationMode(.middle)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private func footer<L: View, T: View>(@ViewBuilder leading: () -> L, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            leading()
            Spacer()
            trailing()
        }
        .controlSize(.large)
    }
}

// MARK: - File chooser (also used in the inspector)

struct FileChooser: View {
    let files: [TorrentFile]
    @Binding var chosen: Set<Int>
    var showProgress = false
    @State private var choice = SmartPicks.Choice()
    @State private var applied = false

    private var picks: SmartPicks { SmartPicks(files) }

    private var folders: [(name: String, files: [TorrentFile])] {
        let groups = Dictionary(grouping: files, by: \.folder)
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) }
    }

    private var kinds: [FileKind] {
        let present = Set(files.map(\.kind))
        return [FileKind.video, .audio, .subtitle, .image, .document, .archive, .other].filter(present.contains)
    }

    var body: some View {
        VStack(spacing: 0) {
            if files.count > 1 {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { chosen.count == files.count },
                                         set: { chosen = $0 ? Set(files.map(\.index)) : [] })) {
                        Text("All").font(.callout.weight(.medium))
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    if kinds.count > 1 {
                        Text("Only:").font(.caption).foregroundStyle(.secondary)
                        ForEach(kinds, id: \.self) { k in
                            Button {
                                chosen = Set(files.filter { $0.kind == k }.map(\.index))
                            } label: {
                                Label(k.plural, systemImage: k.symbol).font(.caption)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            smartBar
            List {
                ForEach(folders, id: \.name) { group in
                    if group.name.isEmpty {
                        rows(group.files)
                    } else {
                        Section {
                            rows(group.files)
                        } header: {
                            Label(group.name, systemImage: "folder").font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    /// Suggestions from the file names. Nothing changes until one is chosen,
    /// and every tick stays editable afterwards.
    @ViewBuilder
    private var smartBar: some View {
        let p = picks
        if p.isUseful {
            HStack(spacing: 8) {
                Label("Suggest", systemImage: "sparkles").font(.caption.weight(.semibold)).fixedSize()
                if !p.resolutions.isEmpty {
                    Picker("Video", selection: Binding(get: { choice.resolution ?? 0 }, set: { choice.resolution = $0 == 0 ? nil : $0; apply(p) })) {
                        Text("Best quality").tag(0)
                        ForEach(p.resolutions, id: \.self) { Text(SmartPicks.label(forResolution: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if !p.languages.isEmpty {
                    Picker("Subtitles", selection: Binding(get: { choice.language ?? "*" }, set: { choice.language = $0 == "*" ? nil : $0; apply(p) })) {
                        Text("All languages").tag("*")
                        ForEach(p.languages, id: \.self) { Text(SmartPicks.displayName(forLanguage: $0)).tag($0) }
                        Text("No subtitles").tag("")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if p.hasJunk {
                    Toggle("No samples", isOn: Binding(get: { choice.skipJunk }, set: { choice.skipJunk = $0; apply(p) }))
                        .toggleStyle(.checkbox).font(.caption).fixedSize()
                        .help("Leave out sample, trailer and extras files")
                }
                Spacer()
                if !applied {
                    Button("Apply") { apply(p) }.buttonStyle(.glass).controlSize(.small).fixedSize()
                } else {
                    Button("Reset") { applied = false; choice = .init(); chosen = Set(files.map(\.index)) }
                        .buttonStyle(.borderless).font(.caption).fixedSize()
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private func apply(_ p: SmartPicks) {
        applied = true
        chosen = p.select(choice)
    }

    private func rows(_ list: [TorrentFile]) -> some View {
        ForEach(list) { f in
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { chosen.contains(f.index) },
                                         set: { if $0 { chosen.insert(f.index) } else { chosen.remove(f.index) } }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Image(systemName: f.kind.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                    if showProgress && chosen.contains(f.index) && f.progress < 1 {
                        ProgressCapsule(value: f.progress, tint: .accentColor, height: 3)
                    }
                }
                Spacer(minLength: 8)
                if showProgress && f.progress >= 1 {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
                Text(Format.bytes(f.size))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .opacity(chosen.contains(f.index) ? 1 : 0.55)
            .contentShape(Rectangle())
            .onTapGesture {
                if chosen.contains(f.index) { chosen.remove(f.index) } else { chosen.insert(f.index) }
            }
        }
    }
}
