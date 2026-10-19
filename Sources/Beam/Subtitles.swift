import Foundation

enum SubtitleConverter {
    static let supportedExtensions = ["srt", "vtt"]

    /// Reads an .srt or .vtt file and returns WebVTT data, which is the only
    /// text track format the Default Media Receiver renders.
    /// `offset` shifts every cue: positive delays subtitles, negative shows them earlier.
    static func webVTT(from url: URL, offset: Double = 0) throws -> Data {
        let raw = try Data(contentsOf: url)
        guard let text = decode(raw) else {
            throw SubtitleError.unreadable
        }
        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if url.pathExtension.lowercased() == "vtt" || normalized.hasPrefix("WEBVTT") {
            return Data(shift(normalized, by: offset).utf8)
        }
        return Data(shift(srtToVTT(normalized), by: offset).utf8)
    }

    /// Finds a subtitle file next to the movie with the same base name,
    /// e.g. "Movie.mp4" → "Movie.srt", "Movie.en.srt" or "Movie.vtt".
    static func sidecar(for movieURL: URL) -> URL? {
        let directory = movieURL.deletingLastPathComponent()
        let baseName = movieURL.deletingPathExtension().lastPathComponent
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        let subtitles = contents.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        let candidates = subtitles.filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(baseName) }
        // Release names differ between movie and subtitle downloads, so fall back
        // to matching the title ("Obsession.2025.2160p…" → "obsession").
        let title = baseName.split(whereSeparator: { ".-_ [(".contains($0) }).first.map { $0.lowercased() } ?? baseName
        let titleMatches = subtitles.filter { $0.lastPathComponent.lowercased().hasPrefix(title) }
        // A lone subtitle file in the movie's folder (e.g. "srt.srt") is almost
        // certainly meant for that movie, even when its name doesn't match.
        return candidates.first { $0.deletingPathExtension().lastPathComponent == baseName }
            ?? candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
            ?? titleMatches.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
            ?? (subtitles.count == 1 ? subtitles.first : nil)
    }

    private static func shift(_ vtt: String, by offset: Double) -> String {
        guard offset != 0 else { return vtt }
        let lines = vtt.components(separatedBy: "\n").map { line -> String in
            guard line.contains("-->") else { return line }
            let parts = line.components(separatedBy: "-->")
            guard parts.count == 2 else { return line }
            let startField = parts[0].trimmingCharacters(in: .whitespaces)
            let endFields = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard let start = seconds(startField), let endField = endFields.first, let end = seconds(String(endField)) else {
                return line
            }
            let settings = endFields.count > 1 ? " " + endFields[1] : ""
            return "\(timestamp(max(0, start + offset))) --> \(timestamp(max(0, end + offset)))\(settings)"
        }
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":").map { Double($0) }
        guard !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private static func timestamp(_ value: Double) -> String {
        let millis = Int((value * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", millis / 3_600_000, (millis / 60_000) % 60, (millis / 1000) % 60, millis % 1000)
    }

    private static func decode(_ data: Data) -> String? {
        for encoding: String.Encoding in [.utf8, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private static func srtToVTT(_ srt: String) -> String {
        var output = "WEBVTT\n\n"
        for line in srt.components(separatedBy: "\n") {
            if line.contains("-->") {
                // SRT uses "00:00:01,000"; WebVTT needs "00:00:01.000".
                output += line.replacingOccurrences(of: ",", with: ".") + "\n"
            } else {
                output += line + "\n"
            }
        }
        return output
    }
}

enum SubtitleError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "The subtitle file could not be read. Use a UTF-8 .srt or .vtt file."
    }
}

/// How subtitles look on the TV; sent to the receiver as a Cast `textTrackStyle`.
struct SubtitleStyle: Codable, Equatable {
    enum Size: String, Codable, CaseIterable { case small, medium, large, huge }
    enum Color: String, Codable, CaseIterable { case white, yellow }
    enum Background: String, Codable, CaseIterable { case outline, shadow, box }

    var size: Size = .medium
    var color: Color = .white
    var background: Background = .outline

    var castPayload: [String: Any] {
        var style: [String: Any] = [
            "fontScale": [Size.small: 0.8, .medium: 1.0, .large: 1.3, .huge: 1.6][size]!,
            "foregroundColor": color == .white ? "#FFFFFFFF" : "#FFE14DFF",
            "fontFamily": "Droid Sans",
            "fontGenericFamily": "SANS_SERIF"
        ]
        switch background {
        case .outline:
            style["edgeType"] = "OUTLINE"
            style["edgeColor"] = "#000000FF"
            style["backgroundColor"] = "#00000000"
        case .shadow:
            style["edgeType"] = "DROP_SHADOW"
            style["edgeColor"] = "#000000CC"
            style["backgroundColor"] = "#00000000"
        case .box:
            style["edgeType"] = "NONE"
            style["backgroundColor"] = "#000000B3"
        }
        return style
    }
}
