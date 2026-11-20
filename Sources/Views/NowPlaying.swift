import SwiftUI
import AVKit
import AppKit
import MediaPlayer
import CoreImage
import Observation

/// What is playing from a torrent that is still downloading. One at a time,
/// shown in the main window (like Music), never in a window of its own.
@MainActor
@Observable
final class PlayerModel {
    let torrentID: String
    let fileIndex: Int
    let title: String
    let subtitle: String
    let isVideo: Bool
    let player = AVPlayer()
    private(set) var map: [Double] = []         // how complete each slice of the file is
    private(set) var current = 0.0              // seconds
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    private(set) var hasPlayed = false          // got going at least once
    private(set) var buffering = true
    private(set) var failure: String?
    private(set) var percentDone = 0.0
    /// Read from the file itself once its index has arrived.
    private(set) var artwork: NSImage?
    private(set) var bookTitle: String?
    private(set) var author: String?
    private(set) var chapters: [Chapter] = []
    private(set) var tint: Color?
    private var asset: AVURLAsset?
    private var metadataStarted = false

    // Subtitles: files in the torrent (.srt/.vtt) and tracks inside the video.
    struct SubtitleOption: Identifiable, Equatable {
        enum Source: Equatable { case embedded(Int), file(Int) }
        let id: String
        let title: String
        let language: String?
        let source: Source
    }
    private(set) var subtitleOptions: [SubtitleOption] = []
    private(set) var subtitleChoice: String?       // an option's id; nil = off
    private(set) var subtitleText: String?         // the line showing right now
    private(set) var subtitleStatus: String?       // "Loading subtitles…"
    private var subtitleTrack: SubtitleTrack?
    private var pendingSubtitleFile: Int?
    private var subtitleFiles: [Int: TorrentFile] = [:]
    private var embeddedGroup: AVMediaSelectionGroup?
    private var embeddedOptions: [AVMediaSelectionOption] = []
    private var timeObserver: Any?
    private static let languageKey = "subtitleLanguage"   // "" = chose off

    struct Chapter: Equatable, Identifiable {
        let id: Int
        let title: String
        let start: Double
    }
    var speed: Float = 1 { didSet { if isPlaying { player.rate = speed } } }
    private var stream: TorrentStream?
    private var timer: Timer?
    private let store: TorrentStore
    private var remoteTokens: [(MPRemoteCommand, Any)] = []

    init?(store: TorrentStore, torrent: Torrent, file: TorrentFile) {
        self.store = store
        torrentID = torrent.id
        fileIndex = file.index
        title = file.name
        subtitle = file.kind == .video ? "Video" : "Audiobook"
        isVideo = file.kind == .video
        guard let s = TorrentStream(session: store.session, hash: torrent.id, file: file.index) else { return nil }
        stream = s
        let asset = s.makeAsset()
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 20
        player.replaceCurrentItem(with: item)
        // The file must be downloading before anything can play.
        store.session.prioritizeRange(8 << 20, from: 0, inFile: Int32(file.index), ofTorrent: torrent.id)
        player.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        setUpRemoteControls()
        try? FileManager.default.removeItem(at: Self.logURL)
        if isVideo { findSubtitleFiles(for: file, in: torrent) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.showSubtitle(at: t.seconds) }
        }
    }

    /// The book's own title, else the file name without ".m4b".
    var displayTitle: String { bookTitle ?? (title as NSString).deletingPathExtension }

    var currentChapter: Chapter? { chapters.last { $0.start <= current + 0.5 } }

    func jump(to chapter: Chapter) { seek(to: chapter.start) }

    func nextChapter() { if let n = chapters.first(where: { $0.start > current + 1 }) { jump(to: n) } }

    func previousChapter() {
        // Like a CD player: first go to the start of this chapter, then the one before.
        guard let c = currentChapter else { return seek(to: 0) }
        if current - c.start > 3 { jump(to: c) }
        else if let p = chapters.last(where: { $0.start < c.start }) { jump(to: p) }
        else { seek(to: 0) }
    }

    // MARK: Subtitles

    /// Subtitle files that belong to this video: the same episode when the names say so,
    /// else the ones beside it. They are small, so they are fetched at once.
    private func findSubtitleFiles(for video: TorrentFile, in torrent: Torrent) {
        let all = store.files(of: torrent.id)
        let key = SmartPicks.parse(video).episode
        let topFolder = video.path.split(separator: "/").first.map(String.init) ?? ""
        var options: [SubtitleOption] = []
        for f in all where f.kind == .subtitle && ["srt", "vtt"].contains(f.ext) {
            let info = SmartPicks.parse(f)
            if let key, let e = info.episode, e != key { continue }
            if key == nil, (f.path.split(separator: "/").first.map(String.init) ?? "") != topFolder { continue }
            subtitleFiles[f.index] = f
            let lang = info.language
            let name = lang.map(SmartPicks.displayName(forLanguage:)) ?? (f.name as NSString).deletingPathExtension
            options.append(SubtitleOption(id: "file\(f.index)", title: name, language: lang, source: .file(f.index)))
        }
        // Two files in the same language: tell them apart by file name.
        let counts = Dictionary(grouping: options, by: \.title).mapValues(\.count)
        subtitleOptions = options.map { o in
            guard counts[o.title, default: 0] > 1, case .file(let i) = o.source, let f = subtitleFiles[i] else { return o }
            return SubtitleOption(id: o.id, title: "\(o.title) \u{2014} \(f.name)", language: o.language, source: o.source)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        applyRememberedSubtitle()
    }

    private func loadEmbeddedSubtitles(_ asset: AVURLAsset) async {
        guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
        embeddedGroup = group
        // AVFoundation adds "Forced only" copies of each track; they are not something to pick.
        embeddedOptions = group.options.filter { ($0.mediaType == .subtitle || $0.mediaType == .closedCaption) && !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        let named = embeddedOptions.enumerated().map { i, o in
            SubtitleOption(id: "embedded\(i)", title: o.displayName, language: o.locale?.language.languageCode?.identifier, source: .embedded(i))
        }
        subtitleOptions = named + subtitleOptions
        applyRememberedSubtitle()
    }

    /// Picks the language chosen last time, if this video has it. Never turns subtitles on unasked.
    private func applyRememberedSubtitle() {
        guard subtitleChoice == nil, let lang = UserDefaults.standard.string(forKey: Self.languageKey), !lang.isEmpty,
              let o = subtitleOptions.first(where: { $0.language == lang }) else { return }
        selectSubtitle(o.id, remember: false)
    }

    func selectSubtitle(_ id: String?, remember: Bool = true) {
        subtitleChoice = id
        subtitleTrack = nil; subtitleText = nil; subtitleStatus = nil; pendingSubtitleFile = nil
        if let item = player.currentItem, let group = embeddedGroup { item.select(nil, in: group) }
        let option = subtitleOptions.first { $0.id == id }
        if remember { UserDefaults.standard.set(option?.language ?? "", forKey: Self.languageKey) }
        switch option?.source {
        case .embedded(let i):
            if let item = player.currentItem, let group = embeddedGroup, i < embeddedOptions.count { item.select(embeddedOptions[i], in: group) }
        case .file(let idx):
            guard let f = subtitleFiles[idx] else { return }
            store.session.prioritizeRange(f.size, from: 0, inFile: Int32(idx), ofTorrent: torrentID)
            pendingSubtitleFile = idx
            subtitleStatus = "Loading subtitles\u{2026}"
            loadPendingSubtitleFile()
        case nil: break
        }
    }

    /// Reads the file once it is whole on disk.
    private func loadPendingSubtitleFile() {
        guard let idx = pendingSubtitleFile, let f = subtitleFiles[idx] else { return }
        guard store.session.contiguousBytes(inFile: Int32(idx), inTorrent: torrentID, from: 0) >= f.size,
              let path = store.session.diskPath(forFile: Int32(idx), inTorrent: torrentID),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        pendingSubtitleFile = nil
        if let t = SubtitleTrack.parse(data: data) { subtitleTrack = t; subtitleStatus = nil }
        else { subtitleStatus = "Couldn't read this subtitle file" }
    }

    private func showSubtitle(at time: Double) {
        let line = subtitleTrack?.text(at: time)
        if line != subtitleText { subtitleText = line }
    }

    // MARK: Metadata

    private func loadMetadata() async {
        guard let asset else { return }
        if isVideo { await loadEmbeddedSubtitles(asset) }
        if let common = try? await asset.load(.commonMetadata) {
            func text(_ id: AVMetadataIdentifier) async -> String? {
                guard let i = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: id).first else { return nil }
                let v = try? await i.load(.stringValue)
                return (v?.isEmpty ?? true) ? nil : v
            }
            var book = await text(.commonIdentifierAlbumName)
            if book == nil { book = await text(.commonIdentifierTitle) }
            bookTitle = book
            var by = await text(.commonIdentifierArtist)
            if by == nil { by = await text(.commonIdentifierCreator) }
            author = by
            if let art = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await art.load(.dataValue), let img = NSImage(data: data) {
                artwork = img
                tint = img.averageColor.map { Color(nsColor: $0) }
            }
        }
        // Audiobooks usually label their chapters with an "undetermined" language, which the
        // preferred-language lookup skips: ask for whichever language the file has.
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        let best = locales.first { Locale.preferredLanguages.first?.hasPrefix($0.identifier) == true } ?? locales.first
        if let best, let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: best, containingItemsWithCommonKeys: [.commonKeyTitle]) {
            var list: [Chapter] = []
            for (i, g) in groups.enumerated() {
                let name = try? await g.items.first(where: { $0.commonKey == .commonKeyTitle })?.load(.stringValue)
                list.append(Chapter(id: i, title: name ?? "Chapter \(i + 1)", start: g.timeRange.start.seconds))
            }
            chapters = list.sorted { $0.start < $1.start }
        }
    }

    var remaining: Double { max(0, duration - current) }
    var progress: Double { duration > 0 ? min(1, current / duration) : 0 }

    /// One plain line about what is happening.
    var status: (text: String, warning: Bool) {
        if let failure { return (failure, true) }
        if buffering && !hasPlayed { return ("Getting the start of the file\u{2026}", false) }
        if buffering { return ("Waiting for the next part to download\u{2026}", false) }
        return (percentDone >= 0.999 ? "Fully downloaded" : "\(Int(percentDone * 100))% downloaded", false)
    }

    private func tick() {
        let m = store.session.availabilityMap(ofFile: Int32(fileIndex), inTorrent: torrentID, buckets: 120).map(\.doubleValue)
        if m != map { map = m }
        percentDone = m.isEmpty ? 0 : m.reduce(0, +) / Double(m.count)
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
            if item.status == .failed {
                failure = "This file can't be played before it has finished downloading."
            }
        }
        let t = player.currentTime().seconds
        if t.isFinite { current = t }
        isPlaying = player.timeControlStatus == .playing
        buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && failure == nil
        if isPlaying { hasPlayed = true }
        loadPendingSubtitleFile()
        if hasPlayed && !metadataStarted { metadataStarted = true; Task { await loadMetadata() } }
        updateNowPlayingInfo()
        log("t=\(Int(current)) playing=\(isPlaying) buffering=\(buffering) status=\(player.timeControlStatus.rawValue) rate=\(player.rate) downloaded=\(Int(percentDone * 100))% \(status.text)")
    }

    /// A short trail of what the player did, for finding out why it stalled:
    /// ~/Library/Application Support/Swarm/player.log (cleared at each start).
    private static let logURL = Prefs.stateFolder.appendingPathComponent("player.log")
    private var lastLog = Date.distantPast
    private func log(_ line: String) {
        guard Date().timeIntervalSince(lastLog) >= 2 else { return }
        lastLog = Date()
        let text = Date().formatted(date: .omitted, time: .standard) + " " + line + "\n"
        if let h = try? FileHandle(forWritingTo: Self.logURL) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: Self.logURL, atomically: true, encoding: .utf8) }
    }

    // MARK: Controls

    func togglePlay() {
        if player.timeControlStatus == .paused {
            player.rate = speed
        } else {
            player.pause()
        }
        tick()
    }

    func skip(_ seconds: Double) { seek(to: current + seconds) }

    func seek(to seconds: Double) {
        let top = duration > 0 ? duration : seconds
        let t = min(max(0, seconds), top)
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        timer?.invalidate(); timer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        stream?.stop(); stream = nil
        let c = MPRemoteCommandCenter.shared()
        for (cmd, token) in remoteTokens { cmd.removeTarget(token) }
        remoteTokens = []
        for cmd in [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.skipForwardCommand, c.skipBackwardCommand, c.changePlaybackPositionCommand] {
            cmd.isEnabled = false
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Media keys and Control Center

    private func setUpRemoteControls() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.preferredIntervals = [15]
        func add(_ cmd: MPRemoteCommand, _ body: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void) {
            cmd.isEnabled = true
            let token = cmd.addTarget { [weak self] event in
                Task { @MainActor in if let self { body(self, event) } }
                return .success
            }
            remoteTokens.append((cmd, token))
        }
        add(c.playCommand) { m, _ in if !m.isPlaying { m.togglePlay() } }
        add(c.pauseCommand) { m, _ in if m.isPlaying { m.togglePlay() } }
        add(c.togglePlayPauseCommand) { m, _ in m.togglePlay() }
        add(c.skipForwardCommand) { m, _ in m.skip(30) }
        add(c.skipBackwardCommand) { m, _ in m.skip(-15) }
        add(c.changePlaybackPositionCommand) { m, e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { m.seek(to: e.positionTime) }
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapter?.title ?? displayTitle,
            MPMediaItemPropertyAlbumTitle: displayTitle,
            MPMediaItemPropertyArtist: author ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: current,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0,
        ]
        if let art = artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - The bar

/// Floating glass player at the bottom of the list, in the style of Music's
/// mini player. Video shows above the controls.
struct NowPlayingBar: View {
    @Environment(AppModel.self) private var app
    let model: PlayerModel

    var body: some View {
        VStack(spacing: 12) {
            if model.isVideo {
                VideoSurface(player: model.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        if let line = model.subtitleText {
                            Text(line)
                                .font(.system(size: 15, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .shadow(color: .black, radius: 2).shadow(color: .black.opacity(0.8), radius: 4)
                                .padding(.horizontal, 12).padding(.bottom, 10)
                                .transition(.opacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            header
            VStack(spacing: 5) {
                Scrubber(map: model.map, value: model.progress, duration: model.duration) { model.seek(to: $0 * model.duration) }
                timeRow
            }
            transport
        }
        .padding(16)
        .glassEffect(.regular.tint(model.tint?.opacity(0.28)), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .animation(.smooth(duration: 0.6), value: model.tint == nil)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: 540)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing \(model.title)")
    }

    // Cover (or a tile), the book, its author, the chapter; speed, chapters and close.
    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2).truncationMode(.tail)
                Text(model.author ?? model.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let c = model.currentChapter {
                    Text(c.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.top, 2)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if !model.chapters.isEmpty { chapterMenu }
                if !model.subtitleOptions.isEmpty { subtitleMenu }
                speedMenu
                Button { app.stopPlayer() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .help("Stop playing")
            }
        }
    }

    private var cover: some View {
        ZStack {
            if let art = model.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.accentColor.gradient)
                Image(systemName: model.isVideo ? "film.fill" : "waveform")
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: model.isPlaying && !model.isVideo)
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(.smooth(duration: 0.4), value: model.artwork == nil)
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(model.chapters) { c in
                Button {
                    model.jump(to: c)
                } label: {
                    if c == model.currentChapter { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                }
            }
        } label: {
            Image(systemName: "list.bullet").font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).fixedSize()
        .help("Chapters")
    }

    // Elapsed, what is going on, remaining.
    private var timeRow: some View {
        HStack {
            Text(clock(model.current)).frame(width: 70, alignment: .leading)
            Spacer(minLength: 0)
            let s = model.status
            HStack(spacing: 6) {
                if model.buffering { ProgressView().controlSize(.mini) }
                Text(s.text)
                    .foregroundStyle(s.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .contentTransition(.opacity)
            Spacer(minLength: 0)
            Text(model.duration > 0 ? "\u{2212}" + clock(model.remaining) : "").frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
    }

    private var transport: some View {
        HStack(spacing: 26) {
            if !model.chapters.isEmpty {
                Button { model.previousChapter() } label: { Image(systemName: "backward.end.fill").font(.system(size: 17)) }
                    .help("Previous chapter")
            }
            Button { model.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 24, weight: .regular))
            }
            .help("Back 15 seconds")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying || model.buffering && model.hasPlayed ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.extraLarge)
            .help(model.isPlaying ? "Pause" : "Play")
            Button { model.skip(30) } label: {
                Image(systemName: "goforward.30").font(.system(size: 24, weight: .regular))
            }
            .help("Forward 30 seconds")
            if !model.chapters.isEmpty {
                Button { model.nextChapter() } label: { Image(systemName: "forward.end.fill").font(.system(size: 17)) }
                    .help("Next chapter")
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                model.selectSubtitle(nil)
            } label: {
                if model.subtitleChoice == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            Divider()
            ForEach(model.subtitleOptions) { o in
                Button {
                    model.selectSubtitle(o.id)
                } label: {
                    if o.id == model.subtitleChoice { Label(o.title, systemImage: "checkmark") } else { Text(o.title) }
                }
            }
        } label: {
            Image(systemName: model.subtitleChoice == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).fixedSize()
        .help(model.subtitleStatus ?? "Subtitles")
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { model.speed }, set: { model.speed = $0 })) {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { Text($0 == 1 ? "Normal" : "\($0.formatted())\u{00D7}").tag($0) }
            }
        } label: {
            Text(model.speed == 1 ? "1\u{00D7}" : "\(model.speed.formatted())\u{00D7}")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.glass).controlSize(.regular).fixedSize()
        .help("Playback speed")
    }

    private func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        let (h, m, sec) = (t / 3600, t % 3600 / 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// A scrubber that also shows which parts of the file are already on disk.
struct Scrubber: View {
    let map: [Double]
    let value: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { g in
            let shown = dragging ?? value
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let h: CGFloat = 5, y = (size.height - h) / 2
                    let track = Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: h), cornerRadius: h / 2)
                    ctx.fill(track, with: .color(.secondary.opacity(0.22)))
                    ctx.clipToLayer { c in c.fill(track, with: .color(.black)) }
                    if !map.isEmpty {
                        let w = size.width / CGFloat(map.count)
                        for (i, v) in map.enumerated() where v > 0 {
                            ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: y, width: w + 0.5, height: h)),
                                     with: .color(.secondary.opacity(0.28 + 0.4 * v)))
                        }
                    }
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width * CGFloat(shown), height: h)), with: .color(.accentColor))
                }
                Circle().fill(.white).shadow(radius: 1.5, y: 0.5)
                    .frame(width: dragging == nil ? 10 : 14, height: dragging == nil ? 10 : 14)
                    .offset(x: g.size.width * CGFloat(shown) - (dragging == nil ? 5 : 7))
                    .animation(.smooth(duration: 0.15), value: dragging == nil)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = min(1, max(0, $0.location.x / max(1, g.size.width))) }
                .onEnded { _ in if let d = dragging { onSeek(d) }; dragging = nil })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            onSeek(min(1, max(0, value + (dir == .increment ? 0.02 : -0.02))))
        }
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

extension NSImage {
    /// The picture's average colour, for tinting the player to match the cover.
    var averageColor: NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}
