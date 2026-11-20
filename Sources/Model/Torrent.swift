import Foundation
import AppKit

/// One torrent as the windows show it (a snapshot taken from libtorrent on
/// every refresh).
struct Torrent: Identifiable, Equatable {
    let id: String              // info hash
    var name: String
    var savePath: String
    var status: Status
    var progress: Double        // 0...1 of the chosen files
    var wanted: Int64
    var wantedDone: Int64
    var totalSize: Int64
    var chosenSize: Int64
    var downRate: Int64
    var upRate: Int64
    var uploaded: Int64
    var downloaded: Int64
    var peers: Int
    var seeds: Int
    var swarmPeers: Int
    var swarmSeeds: Int
    var knownPeers: Int
    var connecting: Int
    var trackers: Int
    var trackersAnswered: Int
    var trackersFailed: Int
    var peersFromDHT: Int
    var trackerError: String?
    var hasFileList: Bool
    var sequential: Bool
    var fileCount: Int
    var error: String?
    var added: Date
    var completed: Date?

    enum Status: Equatable {
        case checking, gettingFileList, choosingFiles, queued, downloading, done, sharing, paused, failed

        var title: String {
            switch self {
            case .checking: "Checking files"
            case .gettingFileList: "Getting the file list"
            case .choosingFiles: "Waiting for you to choose files"
            case .queued: "Waiting its turn"
            case .downloading: "Downloading"
            case .done: "Done"
            case .sharing: "Done"
            case .paused: "Paused"
            case .failed: "Problem"
            }
        }

        var isActive: Bool { self == .downloading || self == .gettingFileList || self == .checking }
        var isFinished: Bool { self == .done || self == .sharing }
    }

    init(_ t: TBTorrent) {
        id = t.infoHash
        name = t.name
        savePath = t.savePath
        progress = t.progress
        wanted = t.totalWanted
        wantedDone = t.totalWantedDone
        totalSize = t.totalSize
        chosenSize = t.chosenSize > 0 ? t.chosenSize : t.totalWanted
        downRate = t.downloadRate
        upRate = t.uploadRate
        uploaded = t.totalUploaded
        downloaded = t.totalDownloaded
        peers = Int(t.peers)
        seeds = Int(t.seeds)
        swarmPeers = Int(t.peersInSwarm)
        swarmSeeds = Int(t.seedsInSwarm)
        knownPeers = Int(t.knownPeers)
        connecting = Int(t.connecting)
        trackers = Int(t.trackers)
        trackersAnswered = Int(t.trackersAnswered)
        trackersFailed = Int(t.trackersFailed)
        peersFromDHT = Int(t.peersFromDHT)
        trackerError = t.trackerError
        hasFileList = t.hasMetadata
        sequential = t.sequential
        fileCount = Int(t.fileCount)
        error = t.errorMessage
        added = Date(timeIntervalSince1970: t.addedTime)
        completed = t.completedTime > 0 ? Date(timeIntervalSince1970: t.completedTime) : nil

        switch t.state {
        case .checkingFiles, .checkingResume: status = .checking
        case .gettingInfo: status = .gettingFileList
        case .waitingToStart: status = .choosingFiles
        case .downloading: status = .downloading
        // Finished and not paused = giving its pieces to others (even when
        // some files were skipped); paused and complete = done.
        case .finished, .seeding: status = .sharing
        case .queued: status = .queued
        case .paused: status = t.progress >= 1 && t.totalWanted > 0 ? .done : .paused
        case .error: status = .failed
        @unknown default: status = .downloading
        }
    }

    /// Never blank: the name from the link, else a short form of the hash.
    var displayName: String {
        name.isEmpty ? "Torrent \(id.prefix(8).uppercased())" : name
    }

    /// The downloaded file (single-file torrents) or its folder.
    var contentURL: URL? {
        guard !name.isEmpty else { return nil }
        return URL(fileURLWithPath: savePath).appendingPathComponent(name)
    }

    var contentExists: Bool {
        guard let url = contentURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var isSingleFile: Bool { fileCount == 1 }

    var ratio: Double { downloaded > 0 || wantedDone > 0 ? Double(uploaded) / Double(max(wantedDone, downloaded, 1)) : 0 }

    /// Pause is for downloads only; a finished torrent is never "paused".
    var canPause: Bool { status == .downloading || status == .gettingFileList || status == .checking || status == .queued }
    var canResume: Bool { status == .paused || status == .failed }
    /// Finished and giving pieces to others: offer "Stop Sharing".
    var canStopSharing: Bool { status == .sharing }
    /// Finished and not sharing: offer "Share Again".
    var canShareAgain: Bool { status == .done }
    /// Downloading but no data yet: the start-up phase gets its own wording.
    var isStarting: Bool { status == .downloading && wantedDone == 0 }
    /// Someone is actually taking pieces from us right now.
    /// Only a finished torrent "shares"; a paused or downloading one may
    /// still send a few last bytes, which is not worth a line.
    var isUploading: Bool { status == .sharing && upRate >= 1024 }

    var fileExtension: String? {
        guard isSingleFile else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

/// One file inside a torrent.
struct TorrentFile: Identifiable, Equatable {
    let index: Int
    let path: String
    let size: Int64
    var done: Int64
    var wanted: Bool

    var id: Int { index }
    var name: String { (path as NSString).lastPathComponent }
    /// Folder inside the torrent ("" for files at the top).
    var folder: String {
        let parts = path.split(separator: "/").dropLast()
        // The first part is the torrent's own folder: leave it out.
        return parts.dropFirst().joined(separator: " › ")
    }
    var progress: Double { size > 0 ? Double(done) / Double(size) : 0 }
    var ext: String { (path as NSString).pathExtension.lowercased() }

    init(_ f: TBFile) {
        index = Int(f.index)
        path = f.path
        size = f.size
        done = f.done
        wanted = f.wanted
    }

    var kind: FileKind { FileKind(ext: ext) }
}

enum FileKind: String {
    case video, audio, subtitle, image, document, archive, other

    init(ext: String) {
        switch ext {
        case "mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "wmv", "flv", "mpg", "mpeg": self = .video
        case "mp3", "flac", "m4a", "aac", "wav", "ogg", "opus", "m4b", "alac", "ape": self = .audio
        case "srt", "ass", "ssa", "vtt", "sub", "idx", "sup": self = .subtitle
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff": self = .image
        case "pdf", "epub", "mobi", "txt", "nfo", "doc", "docx", "cbz", "cbr", "azw3": self = .document
        case "zip", "rar", "7z", "tar", "gz", "iso", "dmg", "pkg": self = .archive
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .subtitle: "captions.bubble"
        case .image: "photo"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .other: "doc"
        }
    }

    var plural: String {
        switch self {
        case .video: "Videos"
        case .audio: "Audio"
        case .subtitle: "Subtitles"
        case .image: "Pictures"
        case .document: "Documents"
        case .archive: "Archives"
        case .other: "Other"
        }
    }
}

/// Sidebar filters.
enum Shelf: String, CaseIterable, Identifiable {
    case all, downloading, done, paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Torrents"
        case .downloading: "Downloading"
        case .done: "Done"
        case .paused: "Paused"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .downloading: "arrow.down.circle"
        case .done: "checkmark.circle"
        case .paused: "pause.circle"
        }
    }

    func contains(_ t: Torrent) -> Bool {
        switch self {
        case .all: true
        case .downloading: t.status.isActive || t.status == .choosingFiles || t.status == .queued
        case .done: t.status.isFinished
        case .paused: t.status == .paused || t.status == .failed
        }
    }
}

/// A connected peer, as the peers list shows it.
struct Peer {
    let address: String
    let client: String
    let down: Int64
    let up: Int64
    let progress: Double
    let isSeed: Bool

    init(_ p: TBPeer) {
        address = p.address; client = p.client; down = p.downRate; up = p.upRate
        progress = p.progress; isSeed = p.isSeed
    }

    var rates: String {
        var parts: [String] = []
        if down >= 1024 { parts.append("\u{2193} " + Format.speed(down)) }
        if up >= 1024 { parts.append("\u{2191} " + Format.speed(up)) }
        return parts.isEmpty ? "idle" : parts.joined(separator: "  ")
    }
}
