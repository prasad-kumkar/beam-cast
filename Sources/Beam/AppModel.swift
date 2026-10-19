import AppKit
import Foundation
import MediaPlayer
import Network
import SwiftUI
import UniformTypeIdentifiers

struct ChromecastDevice: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    /// Drops the long receiver ID some devices append, e.g. "XstreamIPTV1-VT-d5f6…" → "XstreamIPTV1-VT".
    var displayName: String {
        let parts = name.split(separator: "-")
        if let last = parts.last, last.count >= 24, last.allSatisfy(\.isHexDigit) {
            return parts.dropLast().joined(separator: "-")
        }
        return name
    }
}

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

final class AppModel: ObservableObject {
    // Devices
    @Published var devices: [ChromecastDevice] = []
    @Published var selectedDeviceID: String?

    // Playlist: `selectedFile` is the current item of `queue`.
    @Published var queue: [URL] = []
    @Published var selectedFile: URL?
    @Published var repeatMode: RepeatMode {
        didSet { defaults.set(repeatMode.rawValue, forKey: "repeatMode") }
    }
    @Published var shuffle: Bool {
        didSet { defaults.set(shuffle, forKey: "shuffle") }
    }

    // Tracks
    @Published var audioTracks: [MediaInspector.Track] = []
    /// ffmpeg stream index of the chosen audio track; nil plays the file's default.
    @Published var selectedAudioTrack: Int?
    @Published var subtitleTracks: [MediaInspector.Track] = []
    /// Which embedded subtitle track is loaded, if the subtitles came from the movie.
    @Published var selectedEmbeddedSubtitle: Int?
    @Published var selectedSubtitle: URL?
    @Published var subtitlesEnabled = true
    @Published var subtitleOffset: Double = 0
    @Published var subtitleStyle: SubtitleStyle {
        didSet {
            defaults.set(try? JSONEncoder().encode(subtitleStyle), forKey: "subtitleStyle")
            client?.setSubtitleStyle(subtitleStyle)
        }
    }

    // Playback
    @Published var thumbnail: NSImage?
    @Published var statusMessage = "Looking for Cast-enabled TVs…"
    @Published var isBusy = false
    @Published var isCasting = false
    @Published var errorMessage: String?
    @Published var playback = CastPlaybackState()
    @Published var scrubberTime: Double = 0
    var isScrubbing = false

    private var probe: MediaInspector.Probe?
    private var subtitleRevision = 0
    private var autoCastPending = false
    private var sleepActivity: NSObjectProtocol?
    private var lastSavedPosition: Double = 0
    private var currentMediaURL: URL?
    private let defaults = UserDefaults.standard

    private let discovery = ChromecastDiscovery()
    private var server: LocalFileServer?
    private var client: CastV2Client?

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mkv", "mov", "webm", "avi", "mpg", "mpeg", "ts"]
    static let convertibleSubtitleExtensions: Set<String> = ["ass", "ssa"]

    init() {
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "") ?? .off
        shuffle = UserDefaults.standard.bool(forKey: "shuffle")
        subtitleStyle = UserDefaults.standard.data(forKey: "subtitleStyle")
            .flatMap { try? JSONDecoder().decode(SubtitleStyle.self, from: $0) } ?? SubtitleStyle()

        discovery.onDevicesChanged = { [weak self] devices in
            DispatchQueue.main.async {
                guard let self else { return }
                self.devices = devices
                let remembered = self.defaults.string(forKey: "lastDeviceID")
                if !self.isCasting && !self.isBusy,
                   self.selectedDeviceID == nil || !devices.contains(where: { $0.id == self.selectedDeviceID }) {
                    self.selectedDeviceID = devices.first(where: { $0.id == remembered })?.id ?? devices.first?.id
                }
                if self.autoCastPending, self.selectedDevice != nil, self.probe != nil || MediaInspector.ffprobeURL == nil {
                    self.autoCastPending = false
                    self.castSelectedMovie()
                    return
                }
                if devices.isEmpty && !self.isCasting {
                    self.statusMessage = "No Cast TVs found yet"
                } else if !devices.isEmpty && !self.isCasting && !self.isBusy {
                    self.statusMessage = "Select a TV and choose a movie"
                }
            }
        }
        applyLaunchArguments()
        discovery.start()
        setUpRemoteCommands()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Stop the TV app too, otherwise it sits on a dead stream after we quit.
            self?.client?.stopApplicationSync()
        }
    }

    deinit {
        discovery.stop()
        server?.stop()
        client?.disconnect()
    }

    /// Supports `-movie <path> [-subtitles <path>] [-autocast YES]`, which
    /// UserDefaults picks up from the command line.
    private func applyLaunchArguments() {
        guard let moviePath = defaults.string(forKey: "movie") else { return }
        let movie = URL(fileURLWithPath: moviePath)
        guard FileManager.default.fileExists(atPath: movie.path) else { return }
        queue = [movie]
        select(movie: movie, subtitle: defaults.string(forKey: "subtitles").map { URL(fileURLWithPath: $0) })
        autoCastPending = defaults.bool(forKey: "autocast")
        statusMessage = "Movie selected — looking for your TV…"
    }

    // MARK: Devices

    var selectedDevice: ChromecastDevice? {
        devices.first(where: { $0.id == selectedDeviceID })
    }

    func selectDevice(_ device: ChromecastDevice) {
        selectedDeviceID = device.id
        defaults.set(device.id, forKey: "lastDeviceID")
        errorMessage = nil
        if !isCasting && !isBusy {
            statusMessage = "Ready to cast to \(device.displayName)"
        }
    }

    func refreshDevices() {
        errorMessage = nil
        statusMessage = "Looking for Cast-enabled TVs…"
        discovery.restart()
    }

    // MARK: Opening files

    func chooseMovie() {
        let panel = NSOpenPanel()
        panel.title = "Choose movies to cast"
        panel.message = "Choose one movie, or several to play in order"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.movie, .video]

        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    /// Handles files dropped on the window, opened from Finder or picked in the panel.
    func open(_ urls: [URL]) {
        for url in urls where isSubtitleFile(url) {
            useSubtitleFile(url)
        }
        let movies = urls.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !movies.isEmpty else { return }
        if selectedFile == nil || (!isCasting && !isBusy && queue.count <= 1) {
            queue = movies
            select(movie: movies[0], subtitle: nil)
        } else {
            queue += movies.filter { !queue.contains($0) }
            statusMessage = "Added \(movies.count == 1 ? movies[0].lastPathComponent : "\(movies.count) movies") to Up Next"
        }
    }

    func open(_ url: URL) {
        open([url])
    }

    private func isSubtitleFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return SubtitleConverter.supportedExtensions.contains(ext) || Self.convertibleSubtitleExtensions.contains(ext)
    }

    var selectedFileName: String {
        selectedFile?.lastPathComponent ?? "No movie selected"
    }

    var displayTitle: String {
        selectedFile.map(Self.title(for:)) ?? "No movie selected"
    }

    /// "Obsession.2025.2160p.WEB.x265…" → "Obsession (2025)"
    static func title(for file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        let words = name.split(whereSeparator: { ".-_ []()".contains($0) }).map(String.init)
        var title: [String] = []
        for word in words {
            if word.count == 4, let year = Int(word), (1900...2100).contains(year) {
                return title.isEmpty ? name : "\(title.joined(separator: " ")) (\(year))"
            }
            if ["2160p", "1080p", "720p", "4k", "web", "webrip", "web-dl", "bluray", "hdtv", "x264", "x265", "tv"]
                .contains(word.lowercased()) { break }
            title.append(word)
        }
        return title.isEmpty ? name : title.joined(separator: " ")
    }

    var videoBadges: [String]? {
        guard let probe else { return nil }
        var parts: [String] = []
        if let width = probe.width { parts.append(width > 1920 ? "4K" : width >= 1920 ? "1080p" : width >= 1280 ? "720p" : "SD") }
        if let codec = probe.videoCodec { parts.append(codec == "hevc" ? "HEVC" : codec.uppercased()) }
        if probe.pixelFormat?.contains("10") == true { parts.append("10-bit") }
        if let duration = probe.duration {
            let minutes = Int(duration / 60)
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : minutes > 0 ? "\(minutes)m" : "\(Int(duration))s")
        }
        return parts
    }

    private func select(movie url: URL, subtitle: URL?) {
        selectedFile = url
        selectedSubtitle = subtitle ?? SubtitleConverter.sidecar(for: url)
        selectedEmbeddedSubtitle = nil
        subtitleOffset = 0
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrack = nil
        thumbnail = nil
        probe = nil
        inspect(url)
        playback = CastPlaybackState()
        scrubberTime = 0
        errorMessage = nil
        statusMessage = selectedDevice == nil
            ? "Movie selected — choose a TV"
            : "Ready to cast to \(selectedDevice!.displayName)"
    }

    /// Reads tracks and a poster in the background, then applies language preferences.
    private func inspect(_ movie: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let probe = MediaInspector.probe(movie)
            let poster = probe.flatMap { MediaInspector.thumbnail(for: movie, duration: $0.duration) }
                .flatMap { NSImage(contentsOf: $0) }
            DispatchQueue.main.async {
                guard let self, self.selectedFile == movie else { return }
                self.probe = probe ?? MediaInspector.Probe()
                self.thumbnail = poster
                self.audioTracks = probe?.audioTracks ?? []
                self.subtitleTracks = probe?.subtitleTracks ?? []
                self.applyPreferredAudio()
                if self.selectedSubtitle == nil {
                    self.applyPreferredEmbeddedSubtitle()
                }
                if self.autoCastPending, self.selectedDevice != nil {
                    self.autoCastPending = false
                    self.castSelectedMovie()
                }
            }
        }
    }

    // MARK: Audio tracks

    private var defaultAudioTrack: MediaInspector.Track? {
        audioTracks.first(where: \.isDefault) ?? audioTracks.first
    }

    var currentAudioTrack: MediaInspector.Track? {
        audioTracks.first(where: { $0.index == selectedAudioTrack }) ?? defaultAudioTrack
    }

    private func applyPreferredAudio() {
        guard audioTracks.count > 1,
              let preferred = defaults.string(forKey: "preferredAudioLanguage"),
              defaultAudioTrack?.language != preferred,
              let match = audioTracks.first(where: { $0.language == preferred }) else { return }
        selectedAudioTrack = match.index
    }

    func selectAudioTrack(_ track: MediaInspector.Track) {
        guard track.index != currentAudioTrack?.index else { return }
        selectedAudioTrack = track.index == defaultAudioTrack?.index ? nil : track.index
        if let language = track.language {
            defaults.set(language, forKey: "preferredAudioLanguage")
        }
        if isCasting {
            castSelectedMovie(startAt: playback.currentTime)
        }
    }

    // MARK: Subtitles

    private func applyPreferredEmbeddedSubtitle() {
        let preferred = defaults.string(forKey: "preferredSubtitleLanguage") ?? "eng"
        guard let track = subtitleTracks.first(where: { $0.language == preferred && $0.title?.lowercased().contains("sdh") != true })
            ?? subtitleTracks.first(where: { $0.language == preferred })
            ?? subtitleTracks.first else { return }
        selectEmbeddedSubtitle(track, remember: false)
    }

    func selectEmbeddedSubtitle(_ track: MediaInspector.Track, remember: Bool = true) {
        guard let movie = selectedFile else { return }
        if remember, let language = track.language {
            defaults.set(language, forKey: "preferredSubtitleLanguage")
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let extracted = MediaInspector.extractSubtitle(from: movie, track: track)
            DispatchQueue.main.async {
                guard let self, self.selectedFile == movie else { return }
                guard let extracted else {
                    self.errorMessage = "That subtitle track could not be read."
                    return
                }
                self.selectedEmbeddedSubtitle = track.index
                self.setSubtitle(extracted)
            }
        }
    }

    func chooseSubtitle() {
        let panel = NSOpenPanel()
        panel.title = "Choose a subtitle file"
        panel.prompt = "Choose Subtitles"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedFile?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = (SubtitleConverter.supportedExtensions + Array(Self.convertibleSubtitleExtensions))
            .compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        useSubtitleFile(url)
    }

    private func useSubtitleFile(_ url: URL) {
        selectedEmbeddedSubtitle = nil
        guard Self.convertibleSubtitleExtensions.contains(url.pathExtension.lowercased()) else {
            setSubtitle(url)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let converted = MediaInspector.convertSubtitleToSRT(url)
            DispatchQueue.main.async {
                guard let self else { return }
                if let converted {
                    self.setSubtitle(converted)
                } else {
                    self.errorMessage = MediaInspector.ffmpegURL == nil
                        ? "ASS/SSA subtitles need ffmpeg. Install it with: brew install ffmpeg"
                        : "That subtitle file could not be read."
                }
            }
        }
    }

    private func setSubtitle(_ url: URL) {
        selectedSubtitle = url
        subtitlesEnabled = true
        subtitleOffset = 0
        if isCasting {
            reloadSubtitlesOnTV()
        }
    }

    func clearSubtitle() {
        selectedSubtitle = nil
        selectedEmbeddedSubtitle = nil
        if isCasting {
            subtitlesEnabled = false
            client?.setSubtitlesEnabled(false)
        }
    }

    func adjustSubtitleOffset(by delta: Double) {
        subtitleOffset = (subtitleOffset + delta * 10).rounded() / 10
        if isCasting {
            reloadSubtitlesOnTV()
        }
    }

    /// Serves the current subtitle file again and reloads it on the TV at the current position.
    private func reloadSubtitlesOnTV() {
        guard let subtitle = selectedSubtitle, let mediaURL = currentMediaURL else { return }
        do {
            let data = try SubtitleConverter.webVTT(from: subtitle, offset: subtitleOffset)
            server?.updateSubtitles(data)
            subtitleRevision += 1
            // A new query string stops the receiver from reusing its cached copy.
            if let url = URL(string: "\(LocalFileServer.subtitlePath)?v=\(subtitleRevision)", relativeTo: mediaURL)?.absoluteURL {
                subtitlesEnabled = true
                client?.reloadSubtitles(url: url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSubtitles() {
        guard selectedSubtitle != nil else { return }
        subtitlesEnabled.toggle()
        client?.setSubtitlesEnabled(subtitlesEnabled)
    }

    // MARK: Playlist

    var currentIndex: Int? {
        selectedFile.flatMap { queue.firstIndex(of: $0) }
    }

    var upNext: [URL] {
        guard let index = currentIndex else { return queue }
        return Array(queue[(index + 1)...])
    }

    private func nextIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        let current = currentIndex ?? -1
        if shuffle, queue.count > 1 {
            return (0..<queue.count).filter { $0 != current }.randomElement()
        }
        if current + 1 < queue.count { return current + 1 }
        return repeatMode == .all ? 0 : nil
    }

    var hasNext: Bool { nextIndex() != nil }

    var hasPrevious: Bool { (currentIndex ?? 0) > 0 }

    func playNext() {
        guard let index = nextIndex() else { return }
        play(queue[index])
    }

    /// Restarts the current movie if it's past the first few seconds, like most players.
    func playPrevious() {
        if isCasting, playback.currentTime > 5 || !hasPrevious {
            seek(to: 0)
        } else if let index = currentIndex, index > 0 {
            play(queue[index - 1])
        }
    }

    func play(_ url: URL) {
        let wasCasting = isCasting || isBusy
        select(movie: url, subtitle: nil)
        if wasCasting {
            autoCastPending = true
        }
    }

    func removeFromQueue(_ url: URL) {
        guard url != selectedFile else { return }
        queue.removeAll { $0 == url }
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }

    func clearUpNext() {
        queue = selectedFile.map { [$0] } ?? []
    }

    private func handleFinished(_ file: URL) {
        forgetPosition(for: file)
        if repeatMode == .one {
            castSelectedMovie(startAt: 0)
        } else if let index = nextIndex() {
            statusMessage = "Up next: \(Self.title(for: queue[index]))"
            play(queue[index])
        } else {
            stopCasting()
            statusMessage = "Finished playing \(Self.title(for: file))"
        }
    }

    // MARK: Casting

    /// Starts casting the current movie. `startAt` overrides the saved resume position.
    func castSelectedMovie(startAt: Double? = nil) {
        guard let device = selectedDevice else {
            errorMessage = "Select a TV first."
            return
        }
        guard let file = selectedFile else {
            errorMessage = "Choose a movie first."
            return
        }

        var subtitleData: Data?
        if let subtitle = selectedSubtitle {
            do {
                subtitleData = try SubtitleConverter.webVTT(from: subtitle, offset: subtitleOffset)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        errorMessage = nil
        isBusy = true
        let startTime = startAt ?? resumePosition(for: file)

        // A non-default audio track needs a repackaged copy, since receivers play the default track.
        if let trackIndex = selectedAudioTrack, let track = audioTracks.first(where: { $0.index == trackIndex }) {
            statusMessage = "Preparing \(track.languageName ?? "audio") track…"
            let videoCodec = probe?.videoCodec
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let variant = MediaInspector.audioVariant(of: file, track: track, videoCodec: videoCodec)
                DispatchQueue.main.async {
                    guard let self, self.selectedFile == file else { return }
                    guard let variant else {
                        self.isBusy = false
                        self.errorMessage = "Could not switch the audio track."
                        return
                    }
                    self.startCast(file: file, castURL: variant, device: device, subtitleData: subtitleData, startTime: startTime)
                }
            }
        } else {
            startCast(file: file, castURL: file, device: device, subtitleData: subtitleData, startTime: startTime)
        }
    }

    private func startCast(file: URL, castURL: URL, device: ChromecastDevice, subtitleData: Data?, startTime: Double) {
        isCasting = false
        playback = CastPlaybackState()
        scrubberTime = startTime
        statusMessage = "Preparing \(Self.title(for: file)) for \(device.displayName)…"

        client?.disconnect()
        client = nil
        server?.stop()
        server = LocalFileServer()
        server?.start(fileURL: castURL, subtitleData: subtitleData) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.isBusy = false
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "Could not start the local video server"
                case .success(let mediaURL):
                    self.connect(to: device, mediaURL: mediaURL, file: file, hasSubtitles: subtitleData != nil, startTime: startTime)
                }
            }
        }
    }

    private func connect(to device: ChromecastDevice, mediaURL: URL, file: URL, hasSubtitles: Bool, startTime: Double) {
        currentMediaURL = mediaURL
        statusMessage = "Connecting to \(device.displayName)…"
        let client = CastV2Client(endpoint: device.endpoint)
        self.client = client
        // Callbacks from a previous cast must not touch the current one.
        client.onStatus = { [weak self, weak client] message in
            DispatchQueue.main.async {
                guard let self, self.client === client else { return }
                self.statusMessage = message
            }
        }
        client.onPlaybackState = { [weak self, weak client] state in
            DispatchQueue.main.async {
                guard let self, self.client === client else { return }
                self.playback = state
                if !self.isScrubbing {
                    self.scrubberTime = state.currentTime
                }
                self.savePosition(state, for: file)
                self.updateNowPlaying()
                if state.isFinished && self.isCasting {
                    self.handleFinished(file)
                }
            }
        }
        client.onReady = { [weak self, weak client] in
            DispatchQueue.main.async {
                guard let self, self.client === client else { return }
                self.isBusy = false
                self.isCasting = true
                self.preventSleep(true)
                self.statusMessage = "Playing \(Self.title(for: file)) on \(device.displayName)"
                self.updateNowPlaying()
            }
        }
        client.onFailure = { [weak self, weak client] error in
            DispatchQueue.main.async {
                guard let self, self.client === client else { return }
                self.tearDown()
                self.errorMessage = error.localizedDescription
                self.statusMessage = "Casting stopped"
            }
        }
        let subtitleURL = hasSubtitles
            ? URL(string: LocalFileServer.subtitlePath, relativeTo: mediaURL)?.absoluteURL
            : nil
        client.cast(
            mediaURL: mediaURL,
            fileName: Self.title(for: file),
            subtitleURL: subtitleURL,
            subtitlesEnabled: subtitlesEnabled,
            subtitleStyle: subtitleStyle,
            startTime: startTime
        )
    }

    // MARK: Transport

    func beginScrubbing() {
        isScrubbing = true
    }

    func endScrubbing() {
        isScrubbing = false
        seek(to: scrubberTime)
    }

    func togglePlayback() {
        guard isCasting else { return }
        playback.isPlaying ? client?.pause() : client?.play()
    }

    func seek(by seconds: Double) {
        client?.seek(by: seconds)
    }

    func seek(to time: Double) {
        let maxTime = playback.duration ?? .greatestFiniteMagnitude
        let target = max(0, min(time, maxTime))
        scrubberTime = target
        client?.seek(to: target)
    }

    func setVolume(_ level: Double) {
        playback.volume = level
        client?.setVolume(level)
    }

    func toggleMute() {
        playback.isMuted.toggle()
        client?.setMuted(playback.isMuted)
    }

    func stopCasting() {
        client?.stopApplication()
        tearDown()
        statusMessage = selectedDevice.map { "Ready to cast to \($0.displayName)" } ?? "Select a TV and choose a movie"
    }

    private func tearDown() {
        client?.disconnect()
        client = nil
        server?.stop()
        server = nil
        currentMediaURL = nil
        isBusy = false
        isCasting = false
        playback = CastPlaybackState()
        scrubberTime = 0
        preventSleep(false)
        updateNowPlaying()
    }

    /// The stream dies if the Mac sleeps, so keep it awake while casting.
    private func preventSleep(_ prevent: Bool) {
        if prevent, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Streaming a movie to the TV")
        } else if !prevent, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    // MARK: Media keys and Control Center

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.isCasting else { return .noActionableNowPlayingItem }
            self.togglePlayback()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.isCasting else { return .noActionableNowPlayingItem }
            self.client?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isCasting else { return .noActionableNowPlayingItem }
            self.client?.pause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasNext else { return .noSuchContent }
            self.playNext()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.isCasting else { return .noActionableNowPlayingItem }
            self.playPrevious()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.seek(by: 10)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seek(by: -10)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard isCasting, let file = selectedFile else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: Self.title(for: file),
            MPMediaItemPropertyArtist: "Beam · \(selectedDevice?.displayName ?? "TV")",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playback.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playback.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if let duration = playback.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let thumbnail {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: thumbnail.size) { _ in thumbnail }
        }
        center.nowPlayingInfo = info
        center.playbackState = playback.playerState == "PAUSED" ? .paused : .playing
    }

    // MARK: Resume where you left off

    private func positionKey(for file: URL) -> String {
        "position:" + file.path
    }

    private func resumePosition(for file: URL) -> Double {
        let saved = defaults.double(forKey: positionKey(for: file))
        return saved > 30 ? saved - 5 : 0
    }

    private func savePosition(_ state: CastPlaybackState, for file: URL) {
        guard state.isPlaying, abs(state.currentTime - lastSavedPosition) >= 10 else { return }
        lastSavedPosition = state.currentTime
        if let duration = state.duration, state.currentTime > duration - 180 {
            forgetPosition(for: file)
        } else {
            defaults.set(state.currentTime, forKey: positionKey(for: file))
        }
    }

    private func forgetPosition(for file: URL) {
        defaults.removeObject(forKey: positionKey(for: file))
    }

    var hasResumePosition: Bool {
        selectedFile.map { resumePosition(for: $0) > 0 } ?? false
    }

    func startOver() {
        if let file = selectedFile { forgetPosition(for: file) }
        objectWillChange.send()
    }
}
