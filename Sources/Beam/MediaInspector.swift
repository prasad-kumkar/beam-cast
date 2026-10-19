import Foundation

/// Uses a locally installed ffmpeg (Homebrew), when present, to read a movie's
/// format and tracks, grab a poster frame, pull out embedded subtitles and
/// build audio-track variants. Everything it writes goes to ~/Library/Caches/Beam.
enum MediaInspector {
    struct Track: Identifiable, Hashable {
        /// ffmpeg stream index within the file.
        let index: Int
        let codec: String
        let language: String?
        let title: String?
        let channels: Int?
        let isDefault: Bool

        var id: Int { index }

        /// e.g. "English · 5.1 · Director's Commentary"
        var label: String {
            var parts: [String] = [languageName ?? "Unknown"]
            if let channels {
                parts.append(channels == 6 ? "5.1" : channels == 8 ? "7.1" : channels == 2 ? "Stereo" : channels == 1 ? "Mono" : "\(channels) ch")
            }
            if let title, !title.isEmpty, title.lowercased() != languageName?.lowercased() {
                parts.append(title)
            }
            return parts.joined(separator: " · ")
        }

        var languageName: String? {
            guard let language, language != "und" else { return nil }
            return Locale.current.localizedString(forLanguageCode: language) ?? language
        }
    }

    struct Probe {
        var videoCodec: String?
        var pixelFormat: String?
        var width: Int?
        var duration: Double?
        var audioTracks: [Track] = []
        var subtitleTracks: [Track] = []
    }

    static var ffmpegURL: URL? { tool("ffmpeg") }
    static var ffprobeURL: URL? { tool("ffprobe") }

    private static func tool(_ name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var cacheDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beam", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stable short key for a file path (Swift's hashValue changes every launch).
    static func cacheKey(for url: URL) -> String {
        String(url.path.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 16)
    }

    static func probe(_ url: URL) -> Probe? {
        guard let ffprobe = ffprobeURL else { return nil }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-show_entries",
                             "format=duration:stream=index,codec_type,codec_name,pix_fmt,width,channels:stream_tags=language,title:stream_disposition=default",
                             "-of", "json", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> Probe {
        var probe = Probe()
        probe.duration = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init)
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            guard let index = stream["index"] as? Int else { continue }
            let codec = stream["codec_name"] as? String ?? ""
            let tags = stream["tags"] as? [String: Any]
            let track = Track(
                index: index,
                codec: codec,
                language: tags?["language"] as? String,
                title: tags?["title"] as? String,
                channels: stream["channels"] as? Int,
                isDefault: ((stream["disposition"] as? [String: Any])?["default"] as? Int) == 1
            )
            switch stream["codec_type"] as? String {
            case "video" where probe.videoCodec == nil:
                probe.videoCodec = codec
                probe.pixelFormat = stream["pix_fmt"] as? String
                probe.width = stream["width"] as? Int
            case "audio":
                probe.audioTracks.append(track)
            case "subtitle":
                // Only text formats can become WebVTT; image subtitles (PGS, VobSub) are skipped.
                if ["subrip", "ass", "ssa", "webvtt", "mov_text", "text"].contains(codec) {
                    probe.subtitleTracks.append(track)
                }
            default:
                break
            }
        }
        return probe
    }

    /// Extracts one embedded subtitle track as SRT into the cache.
    static func extractSubtitle(from movie: URL, track: Track) -> URL? {
        let output = cacheDirectory.appendingPathComponent("\(cacheKey(for: movie))-s\(track.index).srt")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        return run(["-i", movie.path, "-map", "0:\(track.index)", output.path]) ? output : nil
    }

    /// Converts an external ASS/SSA subtitle file to SRT so it can become WebVTT.
    static func convertSubtitleToSRT(_ subtitle: URL) -> URL? {
        let output = cacheDirectory.appendingPathComponent("\(cacheKey(for: subtitle)).srt")
        return run(["-i", subtitle.path, output.path]) ? output : nil
    }

    /// Cast receivers play a file's default audio track, so picking another one
    /// means repackaging the video with only that track. Video is copied, not
    /// re-encoded, so this takes seconds. Cached per file and track.
    static func audioVariant(of movie: URL, track: Track, videoCodec: String?) -> URL? {
        let ext = movie.pathExtension.lowercased() == "mp4" ? "mp4" : "mkv"
        let output = cacheDirectory.appendingPathComponent("\(cacheKey(for: movie))-a\(track.index).\(ext)")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let partial = output.deletingPathExtension().appendingPathExtension("partial.\(ext)")
        var arguments = ["-i", movie.path, "-map", "0:v:0", "-map", "0:\(track.index)", "-c", "copy"]
        if ext == "mp4", videoCodec == "hevc" {
            arguments += ["-tag:v", "hvc1"]
        }
        arguments += ["-movflags", "+faststart", partial.path]
        guard run(arguments) else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        try? FileManager.default.moveItem(at: partial, to: output)
        return output
    }

    /// Grabs a frame ~10% into the movie for the poster, cached per file.
    static func thumbnail(for movie: URL, duration: Double?) -> URL? {
        let output = cacheDirectory.appendingPathComponent("\(cacheKey(for: movie)).jpg")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let arguments = ["-ss", String(Int((duration ?? 600) * 0.1)), "-i", movie.path,
                         "-frames:v", "1", "-vf", "scale=960:-2", output.path]
        return run(arguments) ? output : nil
    }

    /// Deletes cached audio variants, which can be several GB each.
    static func clearVideoCache() {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["mp4", "mkv"].contains(file.pathExtension.lowercased()) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func run(_ arguments: [String]) -> Bool {
        guard let ffmpeg = ffmpegURL else { return false }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-v", "error", "-y"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
