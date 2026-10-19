import XCTest
@testable import Beam

final class RangeParsingTests: XCTestCase {
    let size: UInt64 = 1_000

    func testOpenEndedRangeUsedBySeeking() {
        let range = LocalFileServer.parseRange("bytes=400-", fileSize: size)
        XCTAssertEqual(range?.start, 400)
        XCTAssertEqual(range?.end, 999)
    }

    func testClosedRange() {
        let range = LocalFileServer.parseRange("bytes=10-19", fileSize: size)
        XCTAssertEqual(range?.start, 10)
        XCTAssertEqual(range?.end, 19)
    }

    func testSuffixRange() {
        let range = LocalFileServer.parseRange("bytes=-100", fileSize: size)
        XCTAssertEqual(range?.start, 900)
        XCTAssertEqual(range?.end, 999)
    }

    func testEndPastFileIsClamped() {
        XCTAssertEqual(LocalFileServer.parseRange("bytes=990-5000", fileSize: size)?.end, 999)
    }

    func testInvalidRanges() {
        XCTAssertNil(LocalFileServer.parseRange(nil, fileSize: size))
        XCTAssertNil(LocalFileServer.parseRange("bytes=2000-", fileSize: size))
        XCTAssertNil(LocalFileServer.parseRange("items=0-1", fileSize: size))
    }
}

final class SubtitleTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSRTBecomesWebVTT() throws {
        let srt = try write("a.srt", "\u{FEFF}1\r\n00:01:20,080 --> 00:01:21,832\r\nEver since we...\r\n")
        let vtt = String(decoding: try SubtitleConverter.webVTT(from: srt), as: UTF8.self)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:01:20.080 --> 00:01:21.832"))
        XCTAssertFalse(vtt.contains("\r"))
        XCTAssertFalse(vtt.contains("\u{FEFF}"))
    }

    func testOffsetShiftsCuesAndClampsAtZero() throws {
        let srt = try write("a.srt", "1\n00:00:01,000 --> 00:00:03,500\nHi\n\n2\n01:00:00,000 --> 01:00:02,000\nBye\n")
        let later = String(decoding: try SubtitleConverter.webVTT(from: srt, offset: 2.5), as: UTF8.self)
        XCTAssertTrue(later.contains("00:00:03.500 --> 00:00:06.000"))
        XCTAssertTrue(later.contains("01:00:02.500 --> 01:00:04.500"))
        let earlier = String(decoding: try SubtitleConverter.webVTT(from: srt, offset: -2), as: UTF8.self)
        XCTAssertTrue(earlier.contains("00:00:00.000 --> 00:00:01.500"))
    }

    func testVTTSettingsSurviveOffset() throws {
        let vtt = try write("a.vtt", "WEBVTT\n\n00:00:10.000 --> 00:00:12.000 line:90%\nHi\n")
        let out = String(decoding: try SubtitleConverter.webVTT(from: vtt, offset: 1), as: UTF8.self)
        XCTAssertTrue(out.contains("00:00:11.000 --> 00:00:13.000 line:90%"))
    }

    func testLatin1SubtitlesAreReadable() throws {
        let url = directory.appendingPathComponent("a.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nCafé\n".data(using: .isoLatin1)!.write(to: url)
        let out = String(decoding: try SubtitleConverter.webVTT(from: url), as: UTF8.self)
        XCTAssertTrue(out.contains("Café"))
    }

    func testSidecarPrefersExactName() throws {
        let movie = try write("Movie.mkv", "")
        _ = try write("Movie.en.srt", "")
        let exact = try write("Movie.srt", "")
        XCTAssertEqual(SubtitleConverter.sidecar(for: movie)?.lastPathComponent, exact.lastPathComponent)
    }

    func testSidecarMatchesByTitle() throws {
        let movie = try write("Obsession.2025.2160p.WEB.mkv", "")
        _ = try write("random.srt", "")
        let match = try write("Obsession.2026.720p.ENG.srt", "")
        XCTAssertEqual(SubtitleConverter.sidecar(for: movie)?.lastPathComponent, match.lastPathComponent)
    }

    func testSidecarUsesLoneSubtitle() throws {
        let movie = try write("Film.mp4", "")
        let lone = try write("srt.srt", "")
        XCTAssertEqual(SubtitleConverter.sidecar(for: movie)?.lastPathComponent, lone.lastPathComponent)
    }

    func testNoSidecarWhenAmbiguous() throws {
        let movie = try write("Film.mp4", "")
        _ = try write("a.srt", "")
        _ = try write("b.srt", "")
        XCTAssertNil(SubtitleConverter.sidecar(for: movie))
    }
}

final class PlaybackStateTests: XCTestCase {
    func testPlaybackFinishedState() {
        var state = CastPlaybackState()
        state.playerState = "IDLE"
        state.idleReason = "FINISHED"
        XCTAssertTrue(state.isFinished)
        state.idleReason = "INTERRUPTED"
        XCTAssertFalse(state.isFinished)
    }
}

final class MediaInspectorTests: XCTestCase {
    func testParsesTracksAndSkipsImageSubtitles() {
        let json: [String: Any] = [
            "format": ["duration": "6543.2"],
            "streams": [
                ["index": 0, "codec_type": "video", "codec_name": "hevc", "pix_fmt": "yuv420p10le", "width": 3840],
                ["index": 1, "codec_type": "audio", "codec_name": "aac", "channels": 6,
                 "tags": ["language": "eng"], "disposition": ["default": 1]],
                ["index": 2, "codec_type": "audio", "codec_name": "ac3", "channels": 2,
                 "tags": ["language": "spa", "title": "Commentary"], "disposition": ["default": 0]],
                ["index": 3, "codec_type": "subtitle", "codec_name": "subrip", "tags": ["language": "eng"]],
                ["index": 4, "codec_type": "subtitle", "codec_name": "hdmv_pgs_subtitle", "tags": ["language": "fre"]]
            ]
        ]
        let probe = MediaInspector.parse(json)
        XCTAssertEqual(probe.videoCodec, "hevc")
        XCTAssertEqual(probe.width, 3840)
        XCTAssertEqual(probe.duration ?? 0, 6543.2, accuracy: 0.01)
        XCTAssertEqual(probe.audioTracks.map(\.index), [1, 2])
        XCTAssertTrue(probe.audioTracks[0].isDefault)
        XCTAssertEqual(probe.subtitleTracks.map(\.index), [3], "PGS image subtitles can't be shown on Cast")
    }

    func testTrackLabels() {
        let track = MediaInspector.Track(index: 2, codec: "ac3", language: "spa", title: "Commentary", channels: 6, isDefault: false)
        XCTAssertTrue(track.label.contains("5.1"))
        XCTAssertTrue(track.label.contains("Commentary"))
        let unknown = MediaInspector.Track(index: 1, codec: "aac", language: "und", title: nil, channels: 2, isDefault: true)
        XCTAssertEqual(unknown.label, "Unknown · Stereo")
    }

    func testCacheKeyIsStable() {
        let url = URL(fileURLWithPath: "/Movies/Film.mkv")
        XCTAssertEqual(MediaInspector.cacheKey(for: url), MediaInspector.cacheKey(for: url))
        XCTAssertNotEqual(MediaInspector.cacheKey(for: url), MediaInspector.cacheKey(for: URL(fileURLWithPath: "/Movies/Film2.mkv")))
    }
}

final class SubtitleStyleTests: XCTestCase {
    func testStylePayloads() {
        var style = SubtitleStyle()
        XCTAssertEqual(style.castPayload["fontScale"] as? Double, 1.0)
        XCTAssertEqual(style.castPayload["edgeType"] as? String, "OUTLINE")
        style.size = .huge
        style.color = .yellow
        style.background = .box
        XCTAssertEqual(style.castPayload["fontScale"] as? Double, 1.6)
        XCTAssertEqual(style.castPayload["foregroundColor"] as? String, "#FFE14DFF")
        XCTAssertEqual(style.castPayload["backgroundColor"] as? String, "#000000B3")
    }

    func testStyleRoundTripsThroughDefaults() throws {
        let style = SubtitleStyle(size: .large, color: .yellow, background: .shadow)
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(decoded, style)
    }
}

final class TitleTests: XCTestCase {
    func testCleansReleaseNames() {
        XCTAssertEqual(AppModel.title(for: URL(fileURLWithPath: "/m/Obsession.2025.2160p.4K.WEB.x265.10bit.mkv")), "Obsession (2025)")
        XCTAssertEqual(AppModel.title(for: URL(fileURLWithPath: "/m/The.Bear.S01E01.1080p.WEB.mkv")), "The Bear S01E01")
        XCTAssertEqual(AppModel.title(for: URL(fileURLWithPath: "/m/Home Movie.mp4")), "Home Movie")
    }
}
