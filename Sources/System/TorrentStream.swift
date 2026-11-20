import AVFoundation
import Foundation

/// Lets AVPlayer read a video straight out of a torrent that is still
/// downloading. AVPlayer asks for byte ranges (the start, the end for MP4
/// metadata, wherever the person seeks); each request is answered from the
/// pieces already on disk, and the missing pieces are moved to the front of
/// the download queue until they arrive.
final class TorrentStream: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "swarm-stream"

    /// Formats AVFoundation can play from byte ranges: MP4/MOV video and
    /// M4A/M4B/MP3 audio (audiobooks). MKV, AVI and WebM cannot be played early
    /// (or at all) by the system player.
    static func contentType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "mp4", "m4v": "public.mpeg-4"
        case "mov": "com.apple.quicktime-movie"
        case "m4a", "m4b": "com.apple.m4a-audio"
        case "mp3": "public.mp3"
        default: nil
        }
    }

    let infoHash: String
    let file: Int
    let size: Int64
    private let session: TBSession
    private let path: String
    private let type: String
    private let lock = NSLock()
    private var stopped = false
    private var cancelled = Set<ObjectIdentifier>()
    private let work = DispatchQueue(label: "swarm.stream.work", qos: .userInitiated, attributes: .concurrent)
    private let callbacks = DispatchQueue(label: "swarm.stream.callbacks")
    /// How far ahead of the reader pieces are asked for.
    /// Audio needs little; video needs more.
    private var window: Int64 { type.contains("audio") || type == "public.mp3" ? 6 << 20 : 16 << 20 }

    /// nil when the file or its format cannot be streamed.
    init?(session: TBSession, hash: String, file: Int) {
        guard let path = onMain({ session.diskPath(forFile: Int32(file), inTorrent: hash) }),
              let type = TorrentStream.contentType(forExtension: (path as NSString).pathExtension) else { return nil }
        let size = onMain { session.size(ofFile: Int32(file), inTorrent: hash) }
        guard size > 0 else { return nil }
        self.session = session; self.infoHash = hash; self.file = file
        self.path = path; self.type = type; self.size = size
        super.init()
    }

    var url: URL { URL(string: "\(Self.scheme)://\(infoHash)/\(file)")! }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: callbacks)
        return asset
    }

    /// Ends every read and puts the download order back to normal.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        onMain { session.clearPlaybackDeadlines(forTorrent: infoHash) }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard req.request.url?.scheme == Self.scheme else { return false }
        work.async { [self] in serve(req) }
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel req: AVAssetResourceLoadingRequest) {
        lock.lock(); cancelled.insert(ObjectIdentifier(req)); lock.unlock()
    }

    private func isCancelled(_ req: AVAssetResourceLoadingRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped || req.isCancelled || cancelled.contains(ObjectIdentifier(req))
    }

    // MARK: Serving

    static let logging = ProcessInfo.processInfo.environment["SWARM_STREAM_LOG"] == "1"
    private func trace(_ s: @autoclosure () -> String) { if Self.logging { print(String(format: "[stream %.1f]", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)), s()); fflush(stdout) } }

    private func serve(_ req: AVAssetResourceLoadingRequest) {
        if let d = req.dataRequest {
            trace("request offset=\(d.requestedOffset) length=\(d.requestedLength) toEnd=\(d.requestsAllDataToEndOfResource) info=\(req.contentInformationRequest != nil)")
        } else { trace("request (info only)") }
        if let info = req.contentInformationRequest {
            info.contentType = type
            info.contentLength = size
            info.isByteRangeAccessSupported = true
        }
        guard let data = req.dataRequest else { req.finishLoading(); return }
        var pos = data.currentOffset
        var delivered: Int64 = 0
        let end = data.requestsAllDataToEndOfResource ? size : min(size, data.requestedOffset + Int64(data.requestedLength))
        // The file appears with the first piece. A slow swarm only means waiting:
        // giving up here would make AVPlayer fail for good.
        var handle: FileHandle?
        defer { try? handle?.close() }
        while pos < end {
            if isCancelled(req) { return }
            let ahead = onMain { session.contiguousBytes(inFile: Int32(file), inTorrent: infoHash, from: pos) }
            // Start small and widen as data flows: AVPlayer often reads the start and the
            // index at the end at the same time, and the index must not queue behind a
            // long stretch of audio.
            let reach = min(window, (1 << 20) + delivered)
            if ahead < reach && ahead < end - pos {
                onMain { session.prioritizeRange(reach, from: pos + ahead, inFile: Int32(file), ofTorrent: infoHash) }
            }
            if ahead <= 0 { trace("waiting at \(pos), have \(ahead)"); Thread.sleep(forTimeInterval: 0.25); continue }
            if handle == nil { handle = FileHandle(forReadingAtPath: path) }
            guard let h = handle else { Thread.sleep(forTimeInterval: 0.25); continue }
            let n = Int(min(ahead, end - pos, 1 << 20))
            do {
                try h.seek(toOffset: UInt64(pos))
                guard let chunk = try h.read(upToCount: n), !chunk.isEmpty else { Thread.sleep(forTimeInterval: 0.25); continue }
                data.respond(with: chunk)
                pos += Int64(chunk.count)
                delivered += Int64(chunk.count)
            } catch {
                req.finishLoading(with: error); return
            }
        }
        if !isCancelled(req) { req.finishLoading() }
    }
}

/// Runs on the main thread (libtorrent's session is only touched there),
/// without deadlocking when already on it.
func onMain<T>(_ body: () -> T) -> T {
    Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
}
