import SwiftUI

/// Who Swarm is connected to and which parts of the torrent are on disk.
/// Both sample libtorrent only while the section is open, every 2 seconds.
struct PeersPanel: View {
    @Environment(TorrentStore.self) private var store
    let torrent: Torrent
    @State private var showPeers: Bool
    @State private var showPieces: Bool

    init(torrent: Torrent, expanded: Bool = false) {
        self.torrent = torrent
        _showPeers = State(initialValue: expanded)
        _showPieces = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $showPeers) {
                if showPeers { PeerList(torrentID: torrent.id).padding(.top, 6) }
            } label: {
                HStack {
                    Text("Peers").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(torrent.peers)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            DisclosureGroup(isExpanded: $showPieces) {
                if showPieces { PieceMapView(torrentID: torrent.id).padding(.top, 6) }
            } label: {
                Text("Pieces").font(.subheadline.weight(.semibold))
            }
        }
    }
}

private struct PeerList: View {
    @Environment(TorrentStore.self) private var store
    let torrentID: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let peers = store.peers(of: torrentID)
            VStack(spacing: 0) {
                if peers.isEmpty {
                    Text("Nobody is connected right now.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                ForEach(Array(peers.prefix(12).enumerated()), id: \.offset) { i, p in
                    PeerRow(peer: p)
                    if i < min(peers.count, 12) - 1 { Divider() }
                }
                if peers.count > 12 {
                    Text("and \(peers.count - 12) more").font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
        }
    }
}

private struct PeerRow: View {
    let peer: Peer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: peer.isSeed ? "checkmark.seal.fill" : "person.fill")
                    .font(.caption2).foregroundStyle(peer.isSeed ? Color.green : Color.secondary)
                    .help(peer.isSeed ? "Has the whole torrent" : "Still downloading")
                Text(peer.address).font(.system(.caption, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 4)
                Text(peer.rates).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            HStack(spacing: 6) {
                ProgressCapsule(value: peer.progress, tint: peer.isSeed ? .green : .accentColor, height: 3)
                Text(peer.client.isEmpty ? "Unknown app" : peer.client)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// A grid: filled = on disk, grey = still to come, faint = skipped.
private struct PieceMapView: View {
    @Environment(TorrentStore.self) private var store
    let torrentID: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let map = store.pieceMap(of: torrentID)
            VStack(alignment: .leading, spacing: 6) {
                if let map {
                    Canvas { ctx, size in
                        let cols = 40
                        let rows = max(1, Int((Double(map.have.count) / Double(cols)).rounded(.up)))
                        let gap: CGFloat = 1.5
                        let cell = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
                        for (i, h) in map.have.enumerated() {
                            let r = CGRect(x: CGFloat(i % cols) * (cell + gap), y: CGFloat(i / cols) * (cell + gap), width: cell, height: cell)
                            let w = map.wanted[i]
                            let color: Color = w < 0.5 ? .secondary.opacity(0.12)
                                : h >= 0.999 ? .accentColor
                                : h > 0 ? .accentColor.opacity(0.25 + 0.55 * h)
                                : .secondary.opacity(0.3)
                            ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(color))
                        }
                        _ = rows
                    }
                    .frame(height: gridHeight(cells: map.have.count))
                    Text("\(map.pieceCount.formatted()) pieces").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Available once the file list is known.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
        }
    }

    private func gridHeight(cells: Int) -> CGFloat {
        let cols: CGFloat = 40, width: CGFloat = 240, gap: CGFloat = 1.5
        let cell = (width - gap * (cols - 1)) / cols
        let rows = CGFloat(max(1, Int((Double(cells) / 40).rounded(.up))))
        return rows * cell + (rows - 1) * gap
    }
}
