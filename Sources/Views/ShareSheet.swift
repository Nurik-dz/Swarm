import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What "Share" is doing for one file or folder.
@MainActor
@Observable
final class ShareJob: Identifiable {
    enum State: Equatable {
        case options
        case hashing(Double)
        case ready(hash: String)
        case failed(String)
    }

    let id = UUID()
    let path: URL
    var state: State = .options
    var trackers = ""
    var makePrivate = false
    private(set) var torrentData: Data?
    private let cancel = CancelFlag()

    init(path: URL) { self.path = path }

    var trackerList: [String] {
        trackers.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " }).map(String.init).filter { $0.contains("://") }
    }

    /// Reads every piece (off the main thread), makes the torrent, starts sharing it.
    func start(store: TorrentStore) {
        state = .hashing(0)
        let flag = cancel, path = path, list = trackerList, priv = makePrivate && !trackerList.isEmpty
        Task.detached { [weak self] in
            var err: NSString?
            let data = TBMaker.createTorrent(forPath: path.path, isPrivate: priv, comment: nil, trackers: list, progress: { p in
                Task { @MainActor in if case .hashing = self?.state { self?.state = .hashing(p) } }
            }, shouldCancel: { flag.isCancelled }, error: &err)
            let problem = err as String?
            await MainActor.run {
                guard let self, !flag.isCancelled else { return }
                guard let data else { self.state = .failed(problem ?? "Couldn't prepare the files."); return }
                self.torrentData = data
                if let hash = store.addShared(data, folder: path.deletingLastPathComponent()) { self.state = .ready(hash: hash) }
                else { self.state = .failed("Swarm couldn't start sharing it.") }
            }
        }
    }

    func stop() { cancel.cancel() }
}

struct ShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(TorrentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var job: ShareJob
    @State private var showAdvanced = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: job.path.path)).resizable().frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share \u{201C}\(job.path.lastPathComponent)\u{201D}").font(.title3.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                    Text(summary).foregroundStyle(.secondary)
                }
            }
            switch job.state {
            case .options: options
            case .hashing(let p):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: p).progressViewStyle(.linear)
                    Text("Getting it ready\u{2026} \(Int(p * 100))%").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Text("Swarm reads every part once to build the link. Big folders take a while.").font(.caption).foregroundStyle(.secondary)
                }
            case .ready(let hash): ready(hash)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(24)
        .frame(width: 500)
        .onDisappear { if case .hashing = job.state { job.stop() } }
    }

    private var summary: String {
        let (files, size) = Self.measure(job.path)
        return "\(files == 1 ? "1 file" : "\(files.formatted()) files"), \(Format.bytes(size))"
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Swarm makes a link that anyone with a torrent app can use to download this from you. They get it straight from your Mac, so Swarm has to stay open and online while they do.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("More options", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trackers (optional, one address per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { job.trackers }, set: { job.trackers = $0 }))
                        .font(.system(.caption, design: .monospaced)).frame(height: 56)
                        .scrollContentBackground(.hidden).padding(6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
                    Toggle("Private torrent (only through the trackers above)", isOn: Binding(get: { job.makePrivate }, set: { job.makePrivate = $0 }))
                        .disabled(job.trackerList.isEmpty)
                        .font(.callout)
                }
                .padding(.top, 6)
            }
            Label("A link is not a lock: anyone who gets it can download this. Don't share what you wouldn't hand to a stranger.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ready(_ hash: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sharing. It's in your list and stays on until you stop it.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy Magnet Link", systemImage: copied ? "checkmark" : "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.magnet(hash) ?? "", forType: .string)
                    copied = true
                }
                Button("Save .torrent File\u{2026}", systemImage: "square.and.arrow.down") { saveTorrent() }
            }
            .buttonStyle(.glass)
            Text("Send the link to whoever should get it. If your Mac sleeps or Swarm is closed they can't download until it's back.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch job.state {
            case .options:
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Sharing") { job.start(store: store) }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            case .hashing:
                Button("Cancel", role: .cancel) { job.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            case .ready:
                Button("Done") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.large)
    }

    private func saveTorrent() {
        guard let data = job.torrentData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.nameFieldStringValue = job.path.lastPathComponent + ".torrent"
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    /// File count and total size of a file or folder.
    static func measure(_ url: URL) -> (Int, Int64) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue { return (1, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
        var n = 0, total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let u = e?.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { n += 1; total += Int64(v?.fileSize ?? 0) }
        }
        return (n, total)
    }
}
