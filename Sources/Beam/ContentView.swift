import SwiftUI

/// Cinematic, dark UI in the spirit of the Apple TV app and Infuse: the movie's
/// poster frame becomes a blurred backdrop, controls sit on glass, and the
/// screen switches from a library hero to an expanded "Now Playing" controller
/// (as the Google Cast sender checklist recommends) while casting.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            Backdrop(image: model.thumbnail)

            VStack(spacing: 0) {
                TopBar(model: model)
                Group {
                    if model.isCasting {
                        NowPlayingView(model: model)
                    } else if model.selectedFile == nil {
                        EmptyStateView(model: model, isDropTargeted: isDropTargeted)
                    } else {
                        LibraryHeroView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                StatusLine(model: model)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.isCasting)
        .animation(.easeInOut(duration: 0.3), value: model.selectedFile)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            // Collect every dropped file first so a dropped season is queued in order.
            let group = DispatchGroup()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let url { urls.append(url) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { model.open(urls) }
            return !providers.isEmpty
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

// MARK: - Brand

enum Brand {
    /// The single accent colour, used sparingly.
    static let accent = Color(red: 0.45, green: 0.42, blue: 1.0)
    static let night = Color(red: 0.07, green: 0.07, blue: 0.09)
}

/// The app mark drawn in SwiftUI: play shape with cast waves.
struct BeamMark: View {
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: size * 0.04) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.8, weight: .black))
            Image(systemName: "wave.3.right")
                .font(.system(size: size * 0.62, weight: .bold))
        }
        .foregroundStyle(Brand.accent)
    }
}

struct BrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Capsule().fill(Brand.accent.opacity(configuration.isPressed ? 0.85 : 1)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Round glass transport button for the Now Playing controls.
struct CircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 52
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.38, weight: .semibold))
            .foregroundStyle(prominent ? Brand.night : .white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.white.opacity(0.1))))
            .overlay(Circle().strokeBorder(.white.opacity(prominent ? 0 : 0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(prominent ? 0.35 : 0), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A glass capsule that wraps a Menu so it matches the other controls.
private struct GlassMenu<Content: View, Label: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label

    var body: some View {
        Menu { content } label: { label }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - Backdrop

private struct Backdrop: View {
    var image: NSImage?

    var body: some View {
        ZStack {
            Brand.night
            if let image {
                // Overlay on a flexible view so the fill image can't widen the layout.
                Color.clear
                    .overlay(
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 90)
                            .saturation(1.4)
                            .opacity(0.55)
                    )
                    .clipped()
                    .transition(.opacity)
            }
            Color.black.opacity(0.55)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: image)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            BeamMark(size: 18)
            Text("Beam")
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
            GlassMenu {
                if model.devices.isEmpty {
                    Text("Searching for TVs…")
                } else {
                    ForEach(model.devices) { device in
                        Button {
                            model.selectDevice(device)
                        } label: {
                            if model.selectedDeviceID == device.id {
                                Label(device.displayName, systemImage: "checkmark")
                            } else {
                                Text(device.displayName)
                            }
                        }
                    }
                }
                Divider()
                Button("Search Again") { model.refreshDevices() }
            } label: {
                Label(model.selectedDevice?.displayName ?? "Looking for TVs…",
                      systemImage: model.isCasting ? "tv.fill" : "tv")
                    .font(.system(size: 13, weight: .medium))
            }
            .disabled(model.isCasting || model.isBusy)
            .help("Choose the TV to cast to")
        }
        // Leave room for the window's traffic lights (the title bar is hidden).
        .padding(.leading, 84)
        .padding(.trailing, 18)
        .frame(height: 52)
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    @ObservedObject var model: AppModel
    var isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            BeamMark(size: 54)
                .frame(width: 120, height: 120)
                .background(Circle().fill(.white.opacity(0.05)))
                .scaleEffect(isDropTargeted ? 1.08 : 1)

            VStack(spacing: 6) {
                Text(isDropTargeted ? "Release to load" : "Drop a movie to beam it")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Drop one movie or a whole season. Subtitles are found automatically.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Button {
                model.chooseMovie()
            } label: {
                Label("Choose Movie", systemImage: "plus")
            }
            .buttonStyle(BrandButtonStyle())
            .keyboardShortcut("o")
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(isDropTargeted ? Brand.accent : .white.opacity(0.12),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 7]))
                .background(RoundedRectangle(cornerRadius: 24).fill(.white.opacity(isDropTargeted ? 0.06 : 0.02)))
                .padding(24)
        )
        .animation(.spring(response: 0.3), value: isDropTargeted)
    }
}

// MARK: - Library hero

private struct LibraryHeroView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            HStack(alignment: .center, spacing: 36) {
                Poster(image: model.thumbnail)
                    .frame(width: 400, height: 225)

                VStack(alignment: .leading, spacing: 14) {
                    Text(model.hasResumePosition ? "CONTINUE WATCHING" : "READY TO BEAM")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Brand.accent)

                    Text(model.displayTitle)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

                    if let badges = model.videoBadges, !badges.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(badges, id: \.self) { badge in
                                Text(badge)
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        AudioMenu(model: model)
                        SubtitleMenu(model: model)
                    }

                    HStack(spacing: 10) {
                        Button {
                            model.castSelectedMovie()
                        } label: {
                            Label(model.isBusy ? "Connecting…" : (model.hasResumePosition ? "Resume" : "Play on TV"),
                                  systemImage: "play.fill")
                        }
                        .buttonStyle(BrandButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selectedDevice == nil || model.isBusy)

                        if model.hasResumePosition && !model.isBusy {
                            Button("Start Over") { model.startOver() }
                                .buttonStyle(GlassButtonStyle())
                        }

                        Button {
                            model.chooseMovie()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(GlassButtonStyle())
                        .keyboardShortcut("o")
                        .help("Choose movies — pick several to queue them (⌘O)")
                        .disabled(model.isBusy)
                    }
                    .padding(.top, 4)

                    Text(model.selectedFileName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 12)

            if model.queue.count > 1 {
                UpNextList(model: model)
            }
        }
    }
}

// MARK: - Now Playing

private struct NowPlayingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            Poster(image: model.thumbnail)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 460)

            VStack(spacing: 6) {
                Text(model.displayTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(Brand.accent).frame(width: 6, height: 6)
                    Text(stateText)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            }

            scrubber

            HStack(spacing: 26) {
                if model.queue.count > 1 {
                    Button { model.playPrevious() } label: { Image(systemName: "backward.end.fill") }
                        .buttonStyle(CircleButtonStyle(diameter: 38))
                        .help("Previous / restart")
                }
                Button { model.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                    .buttonStyle(CircleButtonStyle(diameter: 46))
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Back 10 seconds (←)")
                    .disabled(!model.playback.supportsSeeking)
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(CircleButtonStyle(diameter: 66, prominent: true))
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / Pause (Space)")
                Button { model.seek(by: 10) } label: { Image(systemName: "goforward.10") }
                    .buttonStyle(CircleButtonStyle(diameter: 46))
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Forward 10 seconds (→)")
                    .disabled(!model.playback.supportsSeeking)
                if model.queue.count > 1 {
                    Button { model.playNext() } label: { Image(systemName: "forward.end.fill") }
                        .buttonStyle(CircleButtonStyle(diameter: 38))
                        .help("Next in Up Next")
                        .disabled(!model.hasNext)
                }
            }

            if let next = model.upNext.first, model.queue.count > 1 {
                Text("Up next: \(AppModel.title(for: next))")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                AudioMenu(model: model)
                SubtitleMenu(model: model)
                if model.queue.count > 1 {
                    PlaybackModeButtons(model: model)
                }
                Spacer()
                volume
                Button {
                    model.stopCasting()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(GlassButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
                .help("Stop casting (Esc)")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .frame(maxWidth: 720)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
    }

    private var stateText: String {
        let tv = model.selectedDevice?.displayName ?? "TV"
        switch model.playback.playerState {
        case "BUFFERING": return "Buffering on \(tv)…"
        case "PAUSED": return "Paused on \(tv)"
        default: return "Playing on \(tv)"
        }
    }

    private var scrubber: some View {
        let duration = max(model.playback.duration ?? 0, 1)
        return VStack(spacing: 6) {
            Slider(
                value: Binding(get: { model.scrubberTime }, set: { model.scrubberTime = $0 }),
                in: 0...duration,
                onEditingChanged: { editing in
                    editing ? model.beginScrubbing() : model.endScrubbing()
                }
            )
            .tint(Brand.accent)
            .controlSize(.small)
            .disabled(model.playback.duration == nil || !model.playback.supportsSeeking)
            HStack {
                Text(timeString(model.scrubberTime))
                Spacer()
                Text("-" + timeString(duration - model.scrubberTime))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: 560)
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleMute()
            } label: {
                Image(systemName: model.playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(model.playback.isMuted ? "Unmute (M)" : "Mute (M)")
            .keyboardShortcut("m", modifiers: [])
            Slider(value: Binding(get: { model.playback.volume }, set: { model.setVolume($0) }), in: 0...1)
                .tint(.white)
                .controlSize(.small)
                .frame(width: 110)
                .help("TV volume (↑ ↓)")
            // Invisible buttons that carry the ↑/↓ volume shortcuts.
            Button("") { model.setVolume(min(1, model.playback.volume + 0.05)) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .frame(width: 0).opacity(0)
            Button("") { model.setVolume(max(0, model.playback.volume - 0.05)) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .frame(width: 0).opacity(0)
        }
    }
}

// MARK: - Shared pieces

private struct Poster: View {
    var image: NSImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.05)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                BeamMark(size: 34).opacity(0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
    }
}

/// Subtitle on/off, embedded tracks, files, timing and style in one menu.
private struct SubtitleMenu: View {
    @ObservedObject var model: AppModel
    @State private var showTiming = false

    var body: some View {
        HStack(spacing: 0) {
            GlassMenu {
                if model.isCasting && model.selectedSubtitle != nil {
                    Button(model.subtitlesEnabled ? "Hide Subtitles" : "Show Subtitles") { model.toggleSubtitles() }
                    Divider()
                }
                if !model.subtitleTracks.isEmpty {
                    Section("In This Movie") {
                        ForEach(model.subtitleTracks) { track in
                            Button {
                                model.selectEmbeddedSubtitle(track)
                            } label: {
                                if model.selectedEmbeddedSubtitle == track.index && model.selectedSubtitle != nil {
                                    Label(track.label, systemImage: "checkmark")
                                } else {
                                    Text(track.label)
                                }
                            }
                        }
                    }
                }
                Section {
                    if let file = model.selectedSubtitle, model.selectedEmbeddedSubtitle == nil {
                        Label(file.lastPathComponent, systemImage: "checkmark")
                    }
                    Button("Choose Subtitle File…") { model.chooseSubtitle() }
                    if model.selectedSubtitle != nil {
                        Button("Adjust Timing…") { showTiming = true }
                        Button("Turn Off Subtitles") { model.clearSubtitle() }
                    }
                }
                Menu("Style") {
                    Picker("Size", selection: $model.subtitleStyle.size) {
                        ForEach(SubtitleStyle.Size.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                    }
                    Picker("Color", selection: $model.subtitleStyle.color) {
                        ForEach(SubtitleStyle.Color.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                    }
                    Picker("Background", selection: $model.subtitleStyle.background) {
                        ForEach(SubtitleStyle.Background.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                    }
                }
            } label: {
                Label(label, systemImage: model.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill")
                    .font(.system(size: 13, weight: .medium))
            }
            .popover(isPresented: $showTiming, arrowEdge: .bottom) { timing }

            if model.isCasting && model.selectedSubtitle != nil {
                Button("") { model.toggleSubtitles() }
                    .keyboardShortcut("c", modifiers: [])
                    .frame(width: 0).opacity(0)
            }
        }
    }

    private var label: String {
        guard model.selectedSubtitle != nil else { return "Subtitles Off" }
        if model.isCasting && !model.subtitlesEnabled { return "Subtitles Off" }
        let name = model.subtitleTracks.first(where: { $0.index == model.selectedEmbeddedSubtitle })?.languageName ?? "Subtitles"
        return model.subtitleOffset == 0 ? name : String(format: "%@ %+.1fs", name, model.subtitleOffset)
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subtitle Timing")
                .font(.headline)
            Text(model.subtitleOffset == 0 ? "In sync with the movie"
                 : String(format: "Shown %.1f s %@", abs(model.subtitleOffset), model.subtitleOffset > 0 ? "later" : "earlier"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("−5s") { model.adjustSubtitleOffset(by: -5) }
                Button("−0.5s") { model.adjustSubtitleOffset(by: -0.5) }
                Button("Reset") { model.adjustSubtitleOffset(by: -model.subtitleOffset) }
                    .disabled(model.subtitleOffset == 0)
                Button("+0.5s") { model.adjustSubtitleOffset(by: 0.5) }
                Button("+5s") { model.adjustSubtitleOffset(by: 5) }
            }
            Text("Subtitles too early? Use +. Too late? Use −.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }
}

/// Audio track picker; only shown when the movie has more than one track.
private struct AudioMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.audioTracks.count > 1 {
            GlassMenu {
                ForEach(model.audioTracks) { track in
                    Button {
                        model.selectAudioTrack(track)
                    } label: {
                        if model.currentAudioTrack?.index == track.index {
                            Label(track.label, systemImage: "checkmark")
                        } else {
                            Text(track.label)
                        }
                    }
                }
            } label: {
                Label(model.currentAudioTrack?.languageName ?? "Audio", systemImage: "waveform")
                    .font(.system(size: 13, weight: .medium))
            }
            .disabled(model.isBusy)
            .help("Audio track")
        }
    }
}

private struct PlaybackModeButtons: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(model.shuffle ? Brand.accent : .white.opacity(0.7))
            }
            .help(model.shuffle ? "Shuffle on" : "Shuffle off")
            Button {
                let modes = RepeatMode.allCases
                model.repeatMode = modes[(modes.firstIndex(of: model.repeatMode)! + 1) % modes.count]
            } label: {
                Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(model.repeatMode == .off ? .white.opacity(0.7) : Brand.accent)
            }
            .help(["off": "Repeat off", "all": "Repeat all", "one": "Repeat this movie"][model.repeatMode.rawValue]!)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 8)
    }
}

/// The queue below the hero: click to play, × to remove, drag to reorder.
private struct UpNextList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("UP NEXT")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                PlaybackModeButtons(model: model)
                Button("Clear") { model.clearUpNext() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            List {
                ForEach(Array(model.queue.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 18)
                        Text(AppModel.title(for: url))
                            .font(.system(size: 13, weight: url == model.selectedFile ? .semibold : .regular))
                            .foregroundStyle(url == model.selectedFile ? Brand.accent : .white.opacity(0.85))
                            .lineLimit(1)
                        Spacer()
                        if url != model.selectedFile {
                            Button {
                                model.removeFromQueue(url)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from Up Next")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.play(url) }
                    .listRowBackground(Color.clear)
                }
                .onMove { model.moveInQueue(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(model.queue.count) * 28 + 8, 150))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }
}

private struct StatusLine: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(model.isCasting ? Color.green : (model.devices.isEmpty ? Color.orange : .white.opacity(0.35)))
                    .frame(width: 6, height: 6)
            }
            Text(model.statusMessage)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private func timeString(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remaining = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
        : String(format: "%d:%02d", minutes, remaining)
}
