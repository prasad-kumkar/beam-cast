import XCTest
@testable import Beam

final class DLNAParsingTests: XCTestCase {
    let deviceXML = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>[TV] Samsung-bedroom</friendlyName>
        <manufacturer>Samsung Electronics</manufacturer>
        <modelName>UN65NU6900</modelName>
        <UDN>uuid:4f807407-8f33</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
            <controlURL>/upnp/control/RenderingControl1</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>/upnp/control/AVTransport1</controlURL>
          </service>
        </serviceList>
      </device>
    </root>
    """

    func testParsesRendererDescription() throws {
        let location = URL(string: "http://192.168.0.151:9197/dmr")!
        let renderer = try XCTUnwrap(DLNARenderer.parse(description: Data(deviceXML.utf8), location: location))
        XCTAssertEqual(renderer.udn, "uuid:4f807407-8f33")
        XCTAssertEqual(renderer.displayName, "Samsung-bedroom")
        XCTAssertTrue(renderer.isSamsung)
        XCTAssertEqual(renderer.avTransportURL.absoluteString, "http://192.168.0.151:9197/upnp/control/AVTransport1")
        XCTAssertEqual(renderer.renderingControlURL?.absoluteString, "http://192.168.0.151:9197/upnp/control/RenderingControl1")
        XCTAssertNil(renderer.connectionManagerURL)
    }

    func testIgnoresNonRenderers() {
        let server = deviceXML.replacingOccurrences(of: "MediaRenderer", with: "MediaServer")
        XCTAssertNil(DLNARenderer.parse(description: Data(server.utf8), location: URL(string: "http://10.0.0.2/")!))
    }

    func testSearchResponse() {
        let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.0.151:9197/dmr\r\n"
            + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:abc::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        XCTAssertEqual(DLNADiscovery.parseSearchResponse(reply)?.location.absoluteString, "http://192.168.0.151:9197/dmr")
        XCTAssertNil(DLNADiscovery.parseSearchResponse(reply.replacingOccurrences(of: "MediaRenderer", with: "dial")))
    }

    func testMIMETypesFollowTheTV() {
        var renderer = DLNARenderer(udn: "u", name: "TV", manufacturer: nil, modelName: nil,
                                    avTransportURL: URL(string: "http://tv/")!, renderingControlURL: nil, connectionManagerURL: nil)
        XCTAssertEqual(renderer.mimeType(forFileExtension: "mkv"), "video/x-matroska")
        renderer.sinkMIMETypes = DLNARenderer.mimeTypes(fromProtocolInfo: "http-get:*:video/mp4:*,http-get:*:video/x-mkv:DLNA.ORG_PN=X")
        XCTAssertEqual(renderer.sinkMIMETypes, ["video/mp4", "video/x-mkv"])
        XCTAssertEqual(renderer.mimeType(forFileExtension: "mkv"), "video/x-mkv")
        XCTAssertEqual(renderer.mimeType(forFileExtension: "MP4"), "video/mp4")
    }

    func testTimes() {
        XCTAssertEqual(UPnP.seconds(from: "1:02:03.456")!, 3723.456, accuracy: 0.001)
        XCTAssertEqual(UPnP.seconds(from: "00:00:10"), 10)
        XCTAssertNil(UPnP.seconds(from: "NOT_IMPLEMENTED"))
        XCTAssertNil(UPnP.seconds(from: nil))
        XCTAssertEqual(UPnP.timeString(3723.9), "1:02:03")
        XCTAssertEqual(UPnP.timeString(-4), "0:00:00")
    }

    func testEnvelopeEscapesArguments() {
        let body = UPnP.envelope(service: UPnP.avTransport, action: "SetAVTransportURI",
                                 arguments: [("CurrentURI", "http://a/b?x=1&y=<2>")])
        XCTAssertTrue(body.contains("<CurrentURI>http://a/b?x=1&amp;y=&lt;2&gt;</CurrentURI>"))
        XCTAssertTrue(body.contains("<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
    }

    func testSubtitleURLs() {
        let vtt = URL(string: "http://10.0.0.5:5000/tok/subtitles.vtt?v=3")!
        XCTAssertEqual(DLNAClient.srtURL(from: vtt).absoluteString, "http://10.0.0.5:5000/tok/subtitles.srt?v=3")
        let movie = URL(string: "http://10.0.0.5:5000/tok/Movie%20One.mp4")!
        XCTAssertEqual(DLNAClient.withoutCaptions(movie).absoluteString, "http://10.0.0.5:5000/tok/Movie%20One.mp4?captions=0")
    }

    func testWebVTTBecomesSRT() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.500 align:start\nHello\nthere\n\n01:00.000 --> 01:02.000\nBye\n"
        let srt = String(decoding: SubtitleConverter.srt(fromWebVTT: Data(vtt.utf8)), as: UTF8.self)
        XCTAssertEqual(srt, "1\n00:00:01,000 --> 00:00:02,500\nHello\nthere\n\n2\n00:01:00,000 --> 00:01:02,000\nBye\n")
    }
}

/// Plays a clip on a real DLNA TV. Run with:
/// BEAM_DLNA_CLIP=/path/clip.mp4 swift test --filter DLNALiveTests
/// (optionally BEAM_DLNA_TV=<name>). The clip should be about 30 s long.
final class DLNALiveTests: XCTestCase {
    func testPlaysOnRealTV() throws {
        guard let clipPath = ProcessInfo.processInfo.environment["BEAM_DLNA_CLIP"] else {
            throw XCTSkip("Set BEAM_DLNA_CLIP to run against a real TV")
        }
        let wanted = ProcessInfo.processInfo.environment["BEAM_DLNA_TV"]

        // Discover
        let discovery = DLNADiscovery()
        let found = expectation(description: "found a TV")
        var renderer: DLNARenderer?
        discovery.onDevicesChanged = { list in
            if renderer == nil, let match = list.first(where: { wanted == nil || $0.displayName == wanted }) {
                renderer = match
                found.fulfill()
            }
        }
        discovery.start()
        wait(for: [found], timeout: 15)
        discovery.stop()
        let tv = try XCTUnwrap(renderer)
        print("TV: \(tv.displayName) \(tv.modelName ?? "") sink types: \(tv.sinkMIMETypes.count)")

        // Serve and cast, starting 3 s in to exercise resume
        let server = LocalFileServer()
        let served = expectation(description: "server")
        var mediaURL: URL?
        server.start(fileURL: URL(fileURLWithPath: clipPath), progressiveFirstResponse: false) { result in
            mediaURL = try? result.get()
            served.fulfill()
        }
        wait(for: [served], timeout: 5)
        let url = try XCTUnwrap(mediaURL)

        let client = DLNAClient(renderer: tv)
        let lock = NSLock()
        var states: [CastPlaybackState] = []
        var finishedCount = 0
        var failure: Error?
        let ready = expectation(description: "ready")
        client.onReady = { ready.fulfill() }
        client.onFailure = { lock.lock(); failure = $0; lock.unlock() }
        client.onPlaybackState = { state in
            lock.lock()
            if ProcessInfo.processInfo.environment["BEAM_DLNA_VERBOSE"] != nil || states.last?.playerState != state.playerState {
                print(String(format: "  %.1f s: %@ %@", state.currentTime, state.playerState, state.idleReason ?? ""))
            }
            states.append(state)
            if state.isFinished { finishedCount += 1 }
            lock.unlock()
        }
        func latest() -> CastPlaybackState { lock.lock(); defer { lock.unlock() }; return states.last ?? CastPlaybackState() }
        func waitUntil(_ timeout: TimeInterval, _ label: String, _ condition: (CastPlaybackState) -> Bool) {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if condition(latest()) { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
            XCTFail("Timed out waiting for \(label); last state \(latest())")
        }

        client.cast(mediaURL: url, fileName: "Beam DLNA test", subtitleURL: nil, subtitlesEnabled: false,
                    subtitleStyle: SubtitleStyle(), startTime: 3)
        wait(for: [ready], timeout: 25)
        waitUntil(8, "resume seek to ~3 s") { $0.currentTime >= 3 && $0.playerState == "PLAYING" }
        print("Playing at \(latest().currentTime) of \(latest().duration ?? -1)")

        client.pause()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        waitUntil(5, "paused") { $0.playerState == "PAUSED" }
        let pausedAt = latest().currentTime
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(latest().currentTime, pausedAt, accuracy: 0.6, "position should hold while paused")

        client.play()
        waitUntil(5, "playing again") { $0.playerState == "PLAYING" && $0.currentTime > pausedAt + 0.5 }

        let originalVolume = latest().volume
        client.setVolume(max(0, originalVolume - 0.02))
        client.setVolume(originalVolume)

        client.seek(to: 20)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        waitUntil(6, "seek to 20 s") { $0.currentTime >= 19 && $0.currentTime < 26 }
        print("After seek: \(latest().currentTime)")

        waitUntil(25, "natural end") { $0.isFinished }
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        lock.lock()
        XCTAssertEqual(finishedCount, 1, "finished should be reported once")
        XCTAssertNil(failure)
        lock.unlock()

        client.stopApplicationSync()
        client.disconnect()
        server.stop()
    }
}
