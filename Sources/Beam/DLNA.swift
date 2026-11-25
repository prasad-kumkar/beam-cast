import Darwin
import Foundation

// MARK: - Renderer description

/// A UPnP/DLNA MediaRenderer, such as a Samsung, LG or Panasonic smart TV.
struct DLNARenderer: Equatable {
    let udn: String
    let name: String
    let manufacturer: String?
    let modelName: String?
    let avTransportURL: URL
    let renderingControlURL: URL?
    let connectionManagerURL: URL?
    /// MIME types from ConnectionManager's sink list; empty when the TV didn't say.
    var sinkMIMETypes: [String] = []

    var isSamsung: Bool {
        manufacturer?.lowercased().contains("samsung") == true
    }

    /// "[TV] Samsung-bedroom" → "Samsung-bedroom"
    var displayName: String {
        var trimmed = name
        if trimmed.hasPrefix("[TV]") {
            trimmed = String(trimmed.dropFirst(4))
        }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    /// Picks the MIME type the TV lists for this file type, since TVs disagree
    /// on names (Samsung wants video/x-mkv, others video/x-matroska).
    func mimeType(forFileExtension ext: String) -> String {
        let candidates: [String]
        switch ext.lowercased() {
        case "mkv": candidates = ["video/x-matroska", "video/x-mkv", "video/mkv"]
        case "avi": candidates = ["video/x-msvideo", "video/avi", "video/x-avi"]
        case "m4v": candidates = ["video/x-m4v", "video/mp4"]
        case "ts": candidates = ["video/vnd.dlna.mpeg-tts", "video/mp2t", "video/mpeg"]
        default: candidates = [MIMEType.forFileExtension(ext)]
        }
        return candidates.first(where: sinkMIMETypes.contains) ?? candidates[0]
    }

    /// Parses a device description (the XML at an SSDP LOCATION).
    static func parse(description data: Data, location: URL) -> DLNARenderer? {
        let collector = DescriptionCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        guard collector.deviceTypes.contains(where: { $0.contains(":MediaRenderer:") }),
              let udn = collector.first["UDN"] else { return nil }

        let base = collector.first["URLBase"].flatMap(URL.init(string:)) ?? location
        func control(_ kind: String) -> URL? {
            collector.services.first(where: { $0.type.contains(":service:\(kind):") })
                .flatMap { URL(string: $0.controlURL, relativeTo: base)?.absoluteURL }
        }
        guard let avTransport = control("AVTransport") else { return nil }
        return DLNARenderer(
            udn: udn,
            name: collector.first["friendlyName"] ?? location.host ?? "TV",
            manufacturer: collector.first["manufacturer"],
            modelName: collector.first["modelName"],
            avTransportURL: avTransport,
            renderingControlURL: control("RenderingControl"),
            connectionManagerURL: control("ConnectionManager")
        )
    }

    /// "http-get:*:video/mp4:DLNA…,http-get:*:audio/mpeg:*" → ["video/mp4", "audio/mpeg"]
    static func mimeTypes(fromProtocolInfo sink: String) -> [String] {
        var seen = Set<String>()
        return sink.split(separator: ",").compactMap { entry -> String? in
            let parts = entry.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            let mime = String(parts[2]).lowercased()
            return seen.insert(mime).inserted ? mime : nil
        }
    }
}

private final class DescriptionCollector: NSObject, XMLParserDelegate {
    var first: [String: String] = [:]
    var deviceTypes: [String] = []
    var services: [(type: String, controlURL: String)] = []
    private var text = ""
    private var serviceType: String?
    private var controlURL: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        if localName(elementName) == "service" {
            serviceType = nil
            controlURL = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "serviceType": serviceType = value
        case "controlURL": controlURL = value
        case "service":
            if let serviceType, let controlURL {
                services.append((serviceType, controlURL))
            }
        case "deviceType": deviceTypes.append(value)
        default:
            if !value.isEmpty, first[name] == nil {
                first[name] = value
            }
        }
        text = ""
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

// MARK: - SOAP

enum UPnP {
    static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    static let renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"
    static let connectionManager = "urn:schemas-upnp-org:service:ConnectionManager:1"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    struct Fault: LocalizedError {
        let code: String?
        let message: String
        var errorDescription: String? { message }
    }

    /// Sends one SOAP action and returns the response's leaf elements by name.
    static func call(_ controlURL: URL, service: String, action: String, arguments: [(String, String)],
                     completion: @escaping (Result<[String: String], Error>) -> Void) {
        // AVTransport and RenderingControl actions all take InstanceID first; TVs reject them without it.
        let arguments = service == connectionManager ? arguments : [("InstanceID", "0")] + arguments
        let body = envelope(service: service, action: action, arguments: arguments)
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let values = data.map(parseLeaves) ?? [:]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 300 || values["faultstring"] != nil {
                let message = values["errorDescription"] ?? values["faultstring"] ?? "HTTP \(status)"
                completion(.failure(Fault(code: values["errorCode"], message: "\(action) failed: \(message)")))
            } else {
                completion(.success(values))
            }
        }.resume()
    }

    static func envelope(service: String, action: String, arguments: [(String, String)]) -> String {
        let args = arguments.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service)">\(args)</u:\(action)></s:Body></s:Envelope>
        """
    }

    static func xmlEscape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    static func parseLeaves(_ data: Data) -> [String: String] {
        let collector = LeafCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.values
    }

    /// "1:02:03.456" → 3723.456; nil for "NOT_IMPLEMENTED" and other junk.
    static func seconds(from time: String?) -> Double? {
        guard let time, !time.isEmpty else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count == 3 || parts.count == 2 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// 3723.4 → "1:02:03"
    static func timeString(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
    }
}

private final class LeafCollector: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if values[name] == nil, !value.isEmpty {
            values[name] = value
        }
        text = ""
    }
}

// MARK: - Discovery (SSDP)

final class DLNADiscovery {
    var onDevicesChanged: (([DLNARenderer]) -> Void)?

    private let queue = DispatchQueue(label: "beam.dlna.discovery")
    private let socketQueue = DispatchQueue(label: "beam.dlna.ssdp")
    private var generation = 0
    private var renderers: [String: DLNARenderer] = [:]
    private var lastSeen: [String: Date] = [:]
    private var pendingLocations = Set<String>()
    private var knownLocations: [String: String] = [:] // location → UDN
    private var rejectedLocations = Set<String>()

    static let searchTarget = "urn:schemas-upnp-org:device:MediaRenderer:1"
    private static let searchInterval: TimeInterval = 20
    /// A TV that skips a couple of searches (Wi-Fi hiccup) stays in the menu.
    private static let forgetAfter: TimeInterval = 75

    func start() {
        queue.async {
            self.generation += 1
            let generation = self.generation
            self.search(generation: generation)
        }
    }

    func restart() {
        queue.async {
            self.rejectedLocations.removeAll()
        }
        start()
    }

    func stop() {
        queue.async { self.generation += 1 }
    }

    private func search(generation: Int) {
        guard generation == self.generation else { return }
        socketQueue.async { [weak self] in
            let responses = Self.mSearch(duration: 3)
            self?.queue.async { self?.handle(responses, generation: generation) }
        }
        queue.asyncAfter(deadline: .now() + Self.searchInterval) { [weak self] in
            self?.search(generation: generation)
        }
    }

    private func handle(_ responses: [(location: URL, usn: String?)], generation: Int) {
        guard generation == self.generation else { return }
        let now = Date()
        for response in responses {
            let key = response.location.absoluteString
            if let udn = knownLocations[key] {
                lastSeen[udn] = now
            } else if !pendingLocations.contains(key) && !rejectedLocations.contains(key) {
                pendingLocations.insert(key)
                describe(response.location)
            }
        }
        let expired = lastSeen.filter { now.timeIntervalSince($0.value) > Self.forgetAfter }.map(\.key)
        if !expired.isEmpty {
            for udn in expired {
                lastSeen[udn] = nil
                renderers[udn] = nil
            }
            knownLocations = knownLocations.filter { !expired.contains($0.value) }
            publish()
        }
    }

    private func describe(_ location: URL) {
        UPnP.session.dataTask(with: location) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data, var renderer = DLNARenderer.parse(description: data, location: location) else {
                self.queue.async {
                    self.pendingLocations.remove(location.absoluteString)
                    self.rejectedLocations.insert(location.absoluteString)
                }
                return
            }
            let finish: (DLNARenderer?) -> Void = { renderer in
                self.queue.async {
                    self.pendingLocations.remove(location.absoluteString)
                    guard let renderer else {
                        self.rejectedLocations.insert(location.absoluteString)
                        return
                    }
                    self.knownLocations[location.absoluteString] = renderer.udn
                    self.lastSeen[renderer.udn] = Date()
                    if self.renderers[renderer.udn] != renderer {
                        self.renderers[renderer.udn] = renderer
                        self.publish()
                    }
                }
            }
            guard let connectionManager = renderer.connectionManagerURL else {
                finish(renderer)
                return
            }
            // Speakers (Sonos, AV receivers) are MediaRenderers too; only keep ones that take video.
            UPnP.call(connectionManager, service: UPnP.connectionManager, action: "GetProtocolInfo", arguments: []) { result in
                if case .success(let values) = result, let sink = values["Sink"] {
                    renderer.sinkMIMETypes = DLNARenderer.mimeTypes(fromProtocolInfo: sink)
                    if !renderer.sinkMIMETypes.isEmpty && !renderer.sinkMIMETypes.contains(where: { $0.hasPrefix("video/") }) {
                        finish(nil)
                        return
                    }
                }
                finish(renderer)
            }
        }.resume()
    }

    private func publish() {
        let list = renderers.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        DispatchQueue.main.async { self.onDevicesChanged?(list) }
    }

    /// Sends M-SEARCH from the interface the file server uses and collects the
    /// unicast replies. Plain BSD sockets: replies come back to our own port,
    /// so no multicast group membership (or entitlement) is needed.
    static func mSearch(duration: TimeInterval) -> [(location: URL, usn: String?)] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        if let address = LocalFileServer.preferredIPv4Address() {
            inet_pton(AF_INET, address, &local.sin_addr)
            var interfaceAddress = local.sin_addr
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &interfaceAddress, socklen_t(MemoryLayout<in_addr>.size))
        }
        _ = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)

        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(searchTarget)\r\nUSER-AGENT: macOS UPnP/1.1 Beam/1.0\r\n\r\n"
        let bytes = Array(message.utf8)
        func send() {
            _ = withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var results: [(URL, String?)] = []
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let start = Date()
        var sends = 0
        while Date().timeIntervalSince(start) < duration {
            // UDP is lossy; repeat the search a few times early on.
            if sends < 3 && Date().timeIntervalSince(start) >= Double(sends) * 0.6 {
                send()
                sends += 1
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            guard let response = parseSearchResponse(text), seen.insert(response.location.absoluteString).inserted else { continue }
            results.append(response)
        }
        return results
    }

    static func parseSearchResponse(_ text: String) -> (location: URL, usn: String?)? {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1] }
        }
        guard let st = headers["st"] ?? headers["nt"], st.contains(":MediaRenderer:"),
              let location = headers["location"].flatMap(URL.init(string:)),
              location.scheme == "http" else { return nil }
        return (location, headers["usn"])
    }
}

// MARK: - Playback control

/// Plays a movie on a DLNA TV: the TV fetches it from LocalFileServer and Beam
/// drives AVTransport / RenderingControl over SOAP, polling for position.
final class DLNAClient: TVClient {
    var onStatus: ((String) -> Void)?
    var onPlaybackState: ((CastPlaybackState) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private let renderer: DLNARenderer
    private let queue = DispatchQueue(label: "beam.dlna", qos: .userInitiated)
    private var mediaURL: URL?
    private var title = "Movie"
    private var subtitleURL: URL?
    private var subtitlesEnabled = true
    private var state = CastPlaybackState()
    private var disconnected = false
    private var didStart = false
    private var didFinish = false
    private var loadStartedAt = Date()
    /// Suppresses "finished" while we reload or seek, when TVs briefly report STOPPED.
    private var transitionUntil = Date.distantPast
    private var lastPlayingPosition: Double = 0
    private var stoppedPolls = 0
    private var pollCount = 0
    private var pollWork: DispatchWorkItem?
    private var pendingStart: Double = 0
    private var pendingVolume: Double?
    private var volumeWork: DispatchWorkItem?
    private var loadGeneration = 0

    init(renderer: DLNARenderer) {
        self.renderer = renderer
        state.supportedMediaCommands = 2 // seek
    }

    func cast(mediaURL: URL, fileName: String, subtitleURL: URL?, subtitlesEnabled: Bool,
              subtitleStyle: SubtitleStyle, startTime: Double) {
        queue.async {
            self.mediaURL = mediaURL
            self.title = fileName
            self.subtitleURL = subtitleURL
            self.subtitlesEnabled = subtitlesEnabled
            self.disconnected = false
            self.onStatus?("Connecting to \(self.renderer.displayName)…")
            self.load(startTime: startTime, announce: true)
            self.schedulePoll()
        }
    }

    // MARK: Loading

    private func load(startTime: Double, announce: Bool) {
        guard let mediaURL else { return }
        loadGeneration += 1
        let generation = loadGeneration
        didStart = false
        didFinish = false
        stoppedPolls = 0
        loadStartedAt = Date()
        transitionUntil = Date().addingTimeInterval(8)
        pendingStart = startTime > 1 ? startTime : 0

        let captions = subtitlesEnabled ? subtitleURL.map(Self.srtURL(from:)) : nil
        let url = captions == nil && subtitleURL != nil ? Self.withoutCaptions(mediaURL) : mediaURL
        let metadata = didl(for: url, captions: captions)
        if announce { onStatus?("Waiting for the TV to start the movie…") }

        setURI(url, metadata: metadata) { [weak self] result in
            guard let self, generation == self.loadGeneration, !self.disconnected else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success:
                self.soap(UPnP.avTransport, "Play", [("Speed", "1")]) { _ in }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, generation == self.loadGeneration, !self.didStart, !self.disconnected else { return }
                    self.fail(DLNAError.mediaNotSupported)
                }
                self.queue.asyncAfter(deadline: .now() + 25, execute: timeout)
            }
        }
    }

    /// Tries rich metadata first (needed by LG and Sony, carries Samsung's
    /// subtitle link) and falls back to none, which every TV accepts.
    private func setURI(_ url: URL, metadata: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let attempt: (String, @escaping (Result<[String: String], Error>) -> Void) -> Void = { metadata, done in
            self.soap(UPnP.avTransport, "SetAVTransportURI",
                      [("CurrentURI", url.absoluteString), ("CurrentURIMetaData", metadata)], completion: done)
        }
        attempt(metadata) { result in
            switch result {
            case .success: completion(.success(()))
            case .failure(let error as UPnP.Fault):
                attempt("") { retry in
                    if case .failure = retry {
                        completion(.failure(DLNAError.loadFailed(error.message)))
                    } else {
                        completion(.success(()))
                    }
                }
            case .failure(let error):
                completion(.failure(DLNAError.connectionFailed(error.localizedDescription)))
            }
        }
    }

    func didl(for url: URL, captions: URL?) -> String {
        let mime = renderer.mimeType(forFileExtension: Self.fileExtension(of: url))
        let protocolInfo = "http-get:*:\(mime):DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        var item = "<dc:title>\(UPnP.xmlEscape(title))</dc:title>"
        item += "<upnp:class>object.item.videoItem.movie</upnp:class>"
        item += "<res protocolInfo=\"\(protocolInfo)\">\(UPnP.xmlEscape(url.absoluteString))</res>"
        if let captions {
            let link = UPnP.xmlEscape(captions.absoluteString)
            item += "<res protocolInfo=\"http-get:*:text/srt:*\">\(link)</res>"
            item += "<sec:CaptionInfoEx sec:type=\"srt\">\(link)</sec:CaptionInfoEx>"
        }
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:sec=\"http://www.sec.co.kr/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\">\(item)</item></DIDL-Lite>"
    }

    private static func fileExtension(of url: URL) -> String {
        url.pathExtension
    }

    /// ".../token/subtitles.vtt?v=2" → ".../token/subtitles.srt?v=2"
    static func srtURL(from vttURL: URL) -> URL {
        guard var components = URLComponents(url: vttURL, resolvingAgainstBaseURL: true) else { return vttURL }
        if components.path.hasSuffix(".vtt") {
            components.path = String(components.path.dropLast(4)) + ".srt"
        }
        return components.url ?? vttURL
    }

    /// Tells LocalFileServer not to advertise Samsung's caption header for this load.
    static func withoutCaptions(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "captions", value: "0")]
        return components.url ?? url
    }

    // MARK: Polling

    private func schedulePoll() {
        pollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.poll() }
        pollWork = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func poll() {
        guard !disconnected, !didFinish else { return }
        pollCount += 1
        let generation = loadGeneration
        soap(UPnP.avTransport, "GetTransportInfo", []) { [weak self] result in
            guard let self, generation == self.loadGeneration, !self.disconnected else { return }
            guard case .success(let transport) = result else {
                self.schedulePoll()
                return
            }
            self.soap(UPnP.avTransport, "GetPositionInfo", []) { [weak self] result in
                guard let self, generation == self.loadGeneration, !self.disconnected else { return }
                let position = (try? result.get()) ?? [:]
                self.apply(transportState: transport["CurrentTransportState"] ?? "", position: position)
                if self.pollCount % 5 == 1 { self.refreshVolume() }
                self.schedulePoll()
            }
        }
    }

    private func apply(transportState: String, position: [String: String]) {
        if let duration = UPnP.seconds(from: position["TrackDuration"]), duration > 0 {
            state.duration = duration
        }
        let relTime = UPnP.seconds(from: position["RelTime"])
        let inTransition = Date() < transitionUntil

        switch transportState {
        case "PLAYING":
            state.playerState = "PLAYING"
            stoppedPolls = 0
            if let relTime { state.currentTime = relTime; lastPlayingPosition = relTime }
            if !didStart {
                didStart = true
                onReady?()
                if pendingStart > 0 {
                    let target = pendingStart
                    pendingStart = 0
                    seekOnQueue(to: target)
                }
            }
        case "PAUSED_PLAYBACK", "PAUSED_RECORDING":
            state.playerState = "PAUSED"
            stoppedPolls = 0
            if let relTime { state.currentTime = relTime; lastPlayingPosition = relTime }
        case "TRANSITIONING":
            state.playerState = "BUFFERING"
        case "STOPPED", "NO_MEDIA_PRESENT":
            stoppedPolls += 1
            if didStart && !inTransition && stoppedPolls >= 2 {
                state.playerState = "IDLE"
                state.currentTime = lastPlayingPosition
                if let duration = state.duration, lastPlayingPosition >= duration - 15 {
                    state.idleReason = "FINISHED"
                    didFinish = true
                } else {
                    state.idleReason = "CANCELLED"
                }
            } else if !didStart && Date().timeIntervalSince(loadStartedAt) > 12 && stoppedPolls >= 6 {
                // The TV accepted the URL but gave up (usually an unsupported codec).
                fail(DLNAError.mediaNotSupported)
                return
            }
        default:
            break
        }
        if state.playerState != "IDLE" { state.idleReason = nil }
        onPlaybackState?(state)
    }

    private func refreshVolume() {
        guard renderer.renderingControlURL != nil, pendingVolume == nil else { return }
        soap(UPnP.renderingControl, "GetVolume", [("Channel", "Master")]) { [weak self] result in
            guard let self, self.pendingVolume == nil,
                  case .success(let values) = result, let level = values["CurrentVolume"].flatMap(Double.init) else { return }
            self.state.volume = level / 100
        }
        soap(UPnP.renderingControl, "GetMute", [("Channel", "Master")]) { [weak self] result in
            guard let self, case .success(let values) = result, let muted = values["CurrentMute"] else { return }
            self.state.isMuted = muted == "1" || muted.lowercased() == "true"
        }
    }

    // MARK: Transport

    func play() {
        queue.async {
            guard !self.didFinish else { return }
            self.state.playerState = "PLAYING"
            self.onPlaybackState?(self.state)
            self.transportCommand("Play", [("Speed", "1")])
        }
    }

    func pause() {
        queue.async {
            guard !self.didFinish else { return }
            self.state.playerState = "PAUSED"
            self.onPlaybackState?(self.state)
            self.transportCommand("Pause", [])
        }
    }

    /// Samsung answers 701 "Transition not available" for a second or two after
    /// a load or seek; retry instead of dropping the button press.
    private func transportCommand(_ action: String, _ arguments: [(String, String)], attempt: Int = 0) {
        let generation = loadGeneration
        soap(UPnP.avTransport, action, arguments) { [weak self] result in
            guard let self, generation == self.loadGeneration, !self.disconnected,
                  case .failure(let error as UPnP.Fault) = result, error.code == "701", attempt < 4 else { return }
            self.queue.asyncAfter(deadline: .now() + 0.8) {
                self.transportCommand(action, arguments, attempt: attempt + 1)
            }
        }
    }

    func seek(to time: Double) {
        queue.async { self.seekOnQueue(to: time) }
    }

    func seek(by offset: Double) {
        queue.async { self.seekOnQueue(to: self.state.currentTime + offset) }
    }

    private func seekOnQueue(to time: Double) {
        guard !didFinish else { return }
        var target = max(0, time)
        if let duration = state.duration { target = min(target, max(0, duration - 1)) }
        transitionUntil = Date().addingTimeInterval(6)
        state.currentTime = target
        lastPlayingPosition = target
        onPlaybackState?(state)
        transportCommand("Seek", [("Unit", "REL_TIME"), ("Target", UPnP.timeString(target))])
    }

    /// Volume sliders fire many times a second; send only the latest value.
    func setVolume(_ level: Double) {
        queue.async {
            self.state.volume = max(0, min(1, level))
            self.pendingVolume = self.state.volume
            guard self.volumeWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.volumeWork = nil
                guard let level = self.pendingVolume, let _ = self.renderer.renderingControlURL else { return }
                self.soap(UPnP.renderingControl, "SetVolume",
                          [("Channel", "Master"), ("DesiredVolume", String(Int((level * 100).rounded())))]) { [weak self] _ in
                    guard let self else { return }
                    if self.pendingVolume == level { self.pendingVolume = nil }
                }
            }
            self.volumeWork = work
            self.queue.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async {
            self.state.isMuted = muted
            self.soap(UPnP.renderingControl, "SetMute", [("Channel", "Master"), ("DesiredMute", muted ? "1" : "0")]) { _ in }
        }
    }

    // MARK: Subtitles (Samsung only: the TV fetches an .srt named in the metadata)

    func reloadSubtitles(url: URL) {
        queue.async {
            self.subtitleURL = url
            self.subtitlesEnabled = true
            self.reloadAtCurrentPosition()
        }
    }

    func setSubtitlesEnabled(_ enabled: Bool) {
        queue.async {
            guard enabled != self.subtitlesEnabled else { return }
            self.subtitlesEnabled = enabled
            guard self.subtitleURL != nil, self.didStart else { return }
            self.reloadAtCurrentPosition()
        }
    }

    func setSubtitleStyle(_ style: SubtitleStyle) {
        // DLNA has no way to style captions; the TV's own caption settings apply.
    }

    private func reloadAtCurrentPosition() {
        guard mediaURL != nil else { return }
        let position = state.currentTime
        soap(UPnP.avTransport, "Stop", []) { [weak self] _ in
            guard let self else { return }
            self.load(startTime: position, announce: false)
        }
    }

    // MARK: Stopping

    func stopApplication() {
        // Independent of `disconnect()`, which AppModel calls right after this.
        UPnP.call(renderer.avTransportURL, service: UPnP.avTransport, action: "Stop", arguments: []) { _ in }
    }

    /// Used when the app quits: block briefly so the Stop request leaves the Mac.
    func stopApplicationSync() {
        let done = DispatchSemaphore(value: 0)
        UPnP.call(renderer.avTransportURL, service: UPnP.avTransport, action: "Stop", arguments: []) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 1.5)
    }

    func disconnect() {
        queue.async {
            self.disconnected = true
            self.loadGeneration += 1
            self.pollWork?.cancel()
            self.pollWork = nil
            self.volumeWork?.cancel()
            self.volumeWork = nil
        }
    }

    // MARK: Helpers

    private func soap(_ service: String, _ action: String, _ arguments: [(String, String)],
                      completion: @escaping (Result<[String: String], Error>) -> Void) {
        let controlURL = service == UPnP.renderingControl ? renderer.renderingControlURL : renderer.avTransportURL
        guard let controlURL else { return }
        UPnP.call(controlURL, service: service, action: action, arguments: arguments) { [weak self] result in
            if case .failure(let error) = result, !action.hasPrefix("Get") {
                print("DLNA: \(error.localizedDescription)")
            }
            self?.queue.async { completion(result) }
        }
    }

    private func fail(_ error: Error) {
        guard !disconnected else { return }
        disconnected = true
        pollWork?.cancel()
        onFailure?(error)
    }
}

enum DLNAError: LocalizedError {
    case connectionFailed(String)
    case loadFailed(String)
    case mediaNotSupported

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return "Could not reach the TV: \(message)"
        case .loadFailed(let message): return "The TV refused this movie (\(message)). Try an MP4/H.264 version."
        case .mediaNotSupported: return "The TV could not start this file. Try an MP4 (H.264) version of the movie."
        }
    }
}
