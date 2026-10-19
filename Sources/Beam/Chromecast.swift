import Foundation
import Network
import Security

struct CastPlaybackState: Equatable {
    var playerState = "UNKNOWN"
    var currentTime: Double = 0
    var duration: Double?
    var mediaSessionID: Int?
    var supportedMediaCommands = 0
    var idleReason: String?
    var volume: Double = 1
    var isMuted = false

    var isFinished: Bool {
        playerState == "IDLE" && idleReason == "FINISHED"
    }

    var isPlaying: Bool {
        playerState == "PLAYING" || playerState == "BUFFERING"
    }

    var supportsSeeking: Bool {
        supportedMediaCommands & 2 != 0
    }
}

final class ChromecastDiscovery {
    var onDevicesChanged: (([ChromecastDevice]) -> Void)?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "beam.discovery")

    func start() {
        stop()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: "_googlecast._tcp", domain: "local."),
            using: parameters
        )
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("Cast discovery failed: \(error)")
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap { result -> ChromecastDevice? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                let cleanedName = name.hasSuffix("._googlecast._tcp.local.")
                    ? String(name.dropLast("._googlecast._tcp.local.".count))
                    : name
                return ChromecastDevice(id: cleanedName, name: cleanedName, endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                self?.onDevicesChanged?(devices)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func restart() {
        start()
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

final class CastV2Client {
    var onStatus: ((String) -> Void)?
    var onPlaybackState: ((CastPlaybackState) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "beam.cast", qos: .userInitiated)
    private var connection: NWConnection?
    private var requestID = 1
    private var transportID: String?
    private var didLaunchReceiver = false
    private var didOpenMediaChannel = false
    private var didSendLoad = false
    private var didStartPlayback = false
    private var mediaSessionID: Int?
    private var latestPlaybackState = CastPlaybackState()
    private var playbackStartTimeout: DispatchWorkItem?
    private var pendingSeek: Double?
    private var pendingSeekDelta: Double?
    private var pendingMediaCommand: String?
    private var playbackPollWork: DispatchWorkItem?
    private var mediaURL: URL?
    private var fileName: String?
    private var subtitleURL: URL?
    private var subtitlesEnabled = true
    private var startTime: Double = 0
    private var subtitleStyle = SubtitleStyle()
    private var disconnected = false

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    func cast(mediaURL: URL, fileName: String, subtitleURL: URL? = nil, subtitlesEnabled: Bool = true,
              subtitleStyle: SubtitleStyle = SubtitleStyle(), startTime: Double = 0) {
        self.startTime = startTime
        self.subtitleStyle = subtitleStyle
        self.mediaURL = mediaURL
        self.fileName = fileName
        self.subtitleURL = subtitleURL
        self.subtitlesEnabled = subtitlesEnabled
        disconnected = false
        onStatus?("Connecting to the TV…")

        let connection = NWConnection(to: endpoint, using: makeParameters())
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStatus?("Connected — starting the Cast receiver…")
                self.startReceiving()
                self.sendConnect(destination: "receiver-0")
                self.sendJSON(
                    namespace: CastNamespace.receiver,
                    destination: "receiver-0",
                    payload: [
                        "type": "GET_STATUS",
                        "requestId": self.nextRequestID()
                    ]
                )
            case .failed(let error):
                self.fail(CastError.connectionFailed(error.localizedDescription))
            case .cancelled:
                if !self.disconnected {
                    self.fail(CastError.connectionClosed)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stopApplication() {
        queue.async { self.stopApplicationOnQueue() }
    }

    /// Used when the app quits, where an async hop would never run.
    func stopApplicationSync() {
        queue.sync { self.stopApplicationOnQueue() }
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func stopApplicationOnQueue() {
        guard let transportID else { return }
        sendJSON(
            namespace: CastNamespace.receiver,
            destination: transportID,
            payload: [
                "type": "STOP",
                "requestId": nextRequestID()
            ]
        )
    }

    func disconnect() {
        queue.async { self.disconnectOnQueue() }
    }

    private func disconnectOnQueue() {
        disconnected = true
        connection?.cancel()
        connection = nil
        transportID = nil
        didOpenMediaChannel = false
        didSendLoad = false
        didStartPlayback = false
        mediaSessionID = nil
        latestPlaybackState = CastPlaybackState()
        pendingSeek = nil
        pendingSeekDelta = nil
        pendingMediaCommand = nil
        playbackPollWork?.cancel()
        playbackPollWork = nil
        playbackStartTimeout?.cancel()
        playbackStartTimeout = nil
    }

    private func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, false)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func startReceiving() {
        receiveFrame()
    }

    private func receiveFrame() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(CastError.connectionFailed(error.localizedDescription))
                return
            }
            guard let header, header.count == 4 else {
                if isComplete { self.fail(CastError.connectionClosed) }
                return
            }

            let bytes = [UInt8](header)
            let length = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            guard length > 0, length < 4_000_000 else {
                self.fail(CastError.invalidFrame)
                return
            }
            self.connection?.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payload, _, _, error in
                guard let self else { return }
                if let error {
                    self.fail(CastError.connectionFailed(error.localizedDescription))
                    return
                }
                if let payload, let message = CastMessage(data: payload) {
                    self.handle(message)
                }
                self.receiveFrame()
            }
        }
    }

    private func handle(_ message: CastMessage) {
        guard let payload = message.payloadUTF8,
              let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              let json = object as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch message.namespace {
        case CastNamespace.heartbeat:
            if type == "PING" {
                sendJSON(namespace: CastNamespace.heartbeat, destination: message.sourceID, payload: ["type": "PONG"])
            }

        case CastNamespace.receiver:
            if type == "RECEIVER_STATUS" {
                if let volume = (json["status"] as? [String: Any])?["volume"] as? [String: Any] {
                    latestPlaybackState.volume = (volume["level"] as? NSNumber)?.doubleValue ?? latestPlaybackState.volume
                    latestPlaybackState.isMuted = (volume["muted"] as? Bool) ?? latestPlaybackState.isMuted
                    onPlaybackState?(latestPlaybackState)
                }
                let applications = (json["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
                if let app = applications.first(where: { ($0["appId"] as? String) == CastConstants.defaultMediaReceiverAppID }),
                   let foundTransportID = app["transportId"] as? String {
                    transportID = foundTransportID
                    if !didOpenMediaChannel {
                        connectToReceiverAndPlay()
                    }
                } else if !didLaunchReceiver {
                    didLaunchReceiver = true
                    onStatus?("Starting the TV’s media receiver…")
                    sendJSON(
                        namespace: CastNamespace.receiver,
                        destination: "receiver-0",
                        payload: [
                            "type": "LAUNCH",
                            "appId": CastConstants.defaultMediaReceiverAppID,
                            "requestId": nextRequestID()
                        ]
                    )
                }
            }

        case CastNamespace.media:
            if type == "LOAD_FAILED" {
                let code = json["errorCode"].map { String(describing: $0) } ?? "unknown error"
                fail(CastError.mediaLoadFailed(code))
            } else if type == "MEDIA_STATUS" {
                let firstStatus = (json["status"] as? [[String: Any]])?.first
                guard let firstStatus else { return }
                let playerState = firstStatus["playerState"] as? String
                let idleReason = firstStatus["idleReason"] as? String
                let sessionID = (firstStatus["mediaSessionId"] as? NSNumber)?.intValue
                if let sessionID {
                    mediaSessionID = sessionID
                }
                let media = (firstStatus["media"] as? [String: Any])
                    ?? ((firstStatus["extendedStatus"] as? [String: Any])?["media"] as? [String: Any])
                let duration = (media?["duration"] as? NSNumber)?.doubleValue ?? latestPlaybackState.duration
                let currentTime = (firstStatus["currentTime"] as? NSNumber)?.doubleValue ?? latestPlaybackState.currentTime
                let supportedCommands = (firstStatus["supportedMediaCommands"] as? NSNumber)?.intValue
                    ?? latestPlaybackState.supportedMediaCommands
                latestPlaybackState.playerState = playerState ?? latestPlaybackState.playerState
                latestPlaybackState.currentTime = currentTime
                latestPlaybackState.duration = duration
                latestPlaybackState.mediaSessionID = sessionID ?? mediaSessionID
                latestPlaybackState.supportedMediaCommands = supportedCommands
                latestPlaybackState.idleReason = playerState == "IDLE" ? idleReason : nil
                onPlaybackState?(latestPlaybackState)

                if mediaSessionID != nil {
                    if let pendingSeekDelta {
                        self.pendingSeekDelta = nil
                        let target = max(0, currentTime + pendingSeekDelta)
                        queue.async { [weak self] in
                            self?.seekOnQueue(to: target)
                        }
                    } else if let pendingSeek {
                        self.pendingSeek = nil
                        queue.async { [weak self] in
                            self?.seekOnQueue(to: pendingSeek)
                        }
                    } else if let pendingMediaCommand {
                        self.pendingMediaCommand = nil
                        queue.async { [weak self] in
                            self?.sendMediaCommand(type: pendingMediaCommand)
                        }
                    }
                }

                if didSendLoad, !didStartPlayback {
                    if playerState == "IDLE", let idleReason, idleReason == "ERROR" {
                        fail(CastError.mediaLoadFailed("the receiver reported a media error"))
                    } else if playerState == "BUFFERING" || playerState == "PLAYING" {
                        didStartPlayback = true
                        playbackStartTimeout?.cancel()
                        playbackStartTimeout = nil
                        onReady?()
                    }
                }
            }

        default:
            break
        }
    }

    private func connectToReceiverAndPlay() {
        guard let transportID else { return }
        didOpenMediaChannel = true
        sendConnect(destination: transportID)
        // Open the media channel just like the Cast sender reference clients do
        // before issuing LOAD. This also gives the receiver a chance to return
        // its current media status instead of racing the channel setup.
        sendJSON(
            namespace: CastNamespace.media,
            destination: transportID,
            payload: [
                "type": "GET_STATUS",
                "requestId": nextRequestID()
            ]
        )
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.loadMedia(startTime: self.startTime)
        }
    }

    /// Re-sends LOAD at the current position so the receiver fetches a new subtitle file.
    func reloadSubtitles(url: URL) {
        queue.async { self.reloadSubtitlesOnQueue(url: url) }
    }

    private func reloadSubtitlesOnQueue(url: URL) {
        subtitleURL = url
        subtitlesEnabled = true
        loadMedia(startTime: latestPlaybackState.currentTime, announce: false)
    }

    private func loadMedia(startTime: Double = 0, announce: Bool = true) {
        guard let transportID, let mediaURL else {
            fail(CastError.missingMedia)
            return
        }
        if announce {
            onStatus?("Waiting for the TV to start the movie…")
        }

        let title = fileName ?? "Movie"
        let contentType = MIMEType.forFileExtension(mediaURL.pathExtension)
        let metadata: [String: Any] = [
            "metadataType": 0,
            "title": title
        ]
        var media: [String: Any] = [
            "contentId": mediaURL.absoluteString,
            "streamType": "BUFFERED",
            "contentType": contentType,
            "metadata": metadata
        ]
        var loadPayload: [String: Any] = [
            "type": "LOAD",
            "autoplay": true,
            "currentTime": startTime,
            "customData": [String: Any](),
            "sessionId": transportID,
            "requestId": nextRequestID()
        ]
        if let subtitleURL {
            media["tracks"] = [[
                "trackId": CastConstants.subtitleTrackID,
                "type": "TEXT",
                "subtype": "SUBTITLES",
                "trackContentId": subtitleURL.absoluteString,
                "trackContentType": "text/vtt",
                "name": "Subtitles",
                "language": "en"
            ]]
            media["textTrackStyle"] = subtitleStyle.castPayload
            loadPayload["activeTrackIds"] = subtitlesEnabled ? [CastConstants.subtitleTrackID] : [Int]()
        }
        loadPayload["media"] = media
        didSendLoad = true
        sendJSON(namespace: CastNamespace.media, destination: transportID, payload: loadPayload)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.didStartPlayback, !self.disconnected else { return }
            self.fail(CastError.mediaNotSupported)
        }
        playbackStartTimeout = timeout
        queue.asyncAfter(deadline: .now() + 25, execute: timeout)
        startPlaybackPolling()
    }

    func play() {
        queue.async { self.sendMediaCommand(type: "PLAY") }
    }

    func pause() {
        queue.async { self.sendMediaCommand(type: "PAUSE") }
    }

    func setVolume(_ level: Double) {
        queue.async {
            self.sendReceiverVolume(["level": max(0, min(1, level))])
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async {
            self.sendReceiverVolume(["muted": muted])
        }
    }

    private func sendReceiverVolume(_ volume: [String: Any]) {
        sendJSON(
            namespace: CastNamespace.receiver,
            destination: "receiver-0",
            payload: [
                "type": "SET_VOLUME",
                "volume": volume,
                "requestId": nextRequestID()
            ]
        )
    }

    func seek(to time: Double) {
        queue.async { self.seekOnQueue(to: time) }
    }

    private func seekOnQueue(to time: Double) {
        guard let transportID else { return }
        guard mediaSessionID != nil else {
            pendingSeek = max(0, time)
            requestPlaybackStatus()
            return
        }
        var payload: [String: Any] = [
            "type": "SEEK",
            "currentTime": max(0, time),
            "sessionId": transportID,
            "requestId": nextRequestID()
        ]
        if let mediaSessionID {
            payload["mediaSessionId"] = mediaSessionID
        }
        sendJSON(namespace: CastNamespace.media, destination: transportID, payload: payload)
    }

    func setSubtitlesEnabled(_ enabled: Bool) {
        queue.async { self.setSubtitlesEnabledOnQueue(enabled) }
    }

    private func setSubtitlesEnabledOnQueue(_ enabled: Bool) {
        subtitlesEnabled = enabled
        guard let transportID, let mediaSessionID, subtitleURL != nil else { return }
        sendJSON(
            namespace: CastNamespace.media,
            destination: transportID,
            payload: [
                "type": "EDIT_TRACKS_INFO",
                "activeTrackIds": enabled ? [CastConstants.subtitleTrackID] : [Int](),
                "mediaSessionId": mediaSessionID,
                "sessionId": transportID,
                "requestId": nextRequestID()
            ]
        )
    }

    func setSubtitleStyle(_ style: SubtitleStyle) {
        queue.async {
            self.subtitleStyle = style
            guard let transportID = self.transportID, let mediaSessionID = self.mediaSessionID else { return }
            self.sendJSON(
                namespace: CastNamespace.media,
                destination: transportID,
                payload: [
                    "type": "EDIT_TRACKS_INFO",
                    "textTrackStyle": style.castPayload,
                    "mediaSessionId": mediaSessionID,
                    "sessionId": transportID,
                    "requestId": self.nextRequestID()
                ]
            )
        }
    }

    func seek(by offset: Double) {
        queue.async {
            guard self.transportID != nil else { return }
            self.pendingSeekDelta = offset
            self.requestPlaybackStatus()
        }
    }

    private func sendMediaCommand(type: String) {
        guard let transportID else { return }
        guard mediaSessionID != nil else {
            pendingMediaCommand = type
            requestPlaybackStatus()
            return
        }
        var payload: [String: Any] = [
            "type": type,
            "sessionId": transportID,
            "requestId": nextRequestID()
        ]
        if let mediaSessionID {
            payload["mediaSessionId"] = mediaSessionID
        }
        sendJSON(namespace: CastNamespace.media, destination: transportID, payload: payload)
    }

    private func requestPlaybackStatus() {
        guard let transportID else { return }
        sendJSON(
            namespace: CastNamespace.media,
            destination: transportID,
            payload: [
                "type": "GET_STATUS",
                "requestId": nextRequestID()
            ]
        )
    }

    private func startPlaybackPolling() {
        playbackPollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.disconnected else { return }
            self.requestPlaybackStatus()
            self.startPlaybackPolling()
        }
        playbackPollWork = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func sendConnect(destination: String) {
        sendJSON(
            namespace: CastNamespace.connection,
            destination: destination,
            payload: [
                "type": "CONNECT",
                "origin": [String: Any](),
                "userAgent": "PyChromecast",
                "senderInfo": [
                    "sdkType": 2,
                    "version": "15.605.1.3",
                    "browserVersion": "44.0.2403.30",
                    "platform": 4,
                    "systemVersion": "Macintosh; Intel Mac OS X",
                    "connectionType": 1
                ]
            ]
        )
    }

    private func sendJSON(namespace: String, destination: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            fail(CastError.invalidPayload)
            return
        }
        let message = CastMessage(
            sourceID: "sender-0",
            destinationID: destination,
            namespace: namespace,
            payloadUTF8: String(decoding: data, as: UTF8.self)
        )
        let encoded = message.encoded()
        var frame = Data()
        let length = UInt32(encoded.count)
        frame.append(UInt8((length >> 24) & 0xff))
        frame.append(UInt8((length >> 16) & 0xff))
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8(length & 0xff))
        frame.append(encoded)
        connection?.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.fail(CastError.connectionFailed(error.localizedDescription))
            }
        })
    }

    private func nextRequestID() -> Int {
        defer { requestID += 1 }
        return requestID
    }

    private func fail(_ error: CastError) {
        guard !disconnected else { return }
        disconnected = true
        connection?.cancel()
        onFailure?(error)
    }
}

private enum CastNamespace {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let media = "urn:x-cast:com.google.cast.media"
}

private enum CastConstants {
    static let defaultMediaReceiverAppID = "CC1AD845"
    static let subtitleTrackID = 1
}

enum MIMEType {
    static func forFileExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp4": return "video/mp4"
        case "m4v": return "video/x-m4v"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "mpeg", "mpg": return "video/mpeg"
        default: return "application/octet-stream"
        }
    }
}

private enum CastError: LocalizedError {
    case connectionFailed(String)
    case connectionClosed
    case invalidFrame
    case invalidPayload
    case missingMedia
    case mediaLoadFailed(String)
    case mediaNotSupported

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return "The TV connection failed: \(message)"
        case .connectionClosed: return "The TV closed the Cast connection."
        case .invalidFrame: return "The TV sent an invalid Cast message."
        case .invalidPayload: return "The Cast command could not be encoded."
        case .missingMedia: return "The movie URL is no longer available."
        case .mediaLoadFailed(let code): return "The TV could not play this file (\(code)). Try an MP4/H.264 video."
        case .mediaNotSupported: return "The TV could not start this file. Try an MP4 version of the movie."
        }
    }
}

private struct CastMessage {
    let sourceID: String
    let destinationID: String
    let namespace: String
    let payloadUTF8: String?

    init(sourceID: String, destinationID: String, namespace: String, payloadUTF8: String) {
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.namespace = namespace
        self.payloadUTF8 = payloadUTF8
    }

    init?(data: Data) {
        var cursor = 0
        var sourceID: String?
        var destinationID: String?
        var namespace: String?
        var payloadUTF8: String?

        while cursor < data.count {
            guard let key = readVarint(data, cursor: &cursor) else { return nil }
            let field = Int(key >> 3)
            let wireType = Int(key & 0x7)
            guard wireType == 2 else {
                guard skipField(data, cursor: &cursor, wireType: wireType) else { return nil }
                continue
            }
            guard let bytes = readLengthDelimited(data, cursor: &cursor) else { return nil }
            let string = String(data: bytes, encoding: .utf8)
            switch field {
            case 2: sourceID = string
            case 3: destinationID = string
            case 4: namespace = string
            case 6: payloadUTF8 = string
            default: break
            }
        }

        guard let sourceID, let destinationID, let namespace else { return nil }
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.namespace = namespace
        self.payloadUTF8 = payloadUTF8
    }

    func encoded() -> Data {
        var data = Data()
        // CastMessage.protocol_version is a required field in the Cast V2
        // protobuf, even though its only valid value is the default 0.
        appendVarint(0, field: 1, to: &data)
        appendString(sourceID, field: 2, to: &data)
        appendString(destinationID, field: 3, to: &data)
        appendString(namespace, field: 4, to: &data)
        appendVarint(0, field: 5, to: &data)
        if let payloadUTF8 {
            appendString(payloadUTF8, field: 6, to: &data)
        }
        return data
    }

    private func appendString(_ value: String, field: Int, to data: inout Data) {
        let bytes = Array(value.utf8)
        appendVarint(UInt64((field << 3) | 2), to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private func appendVarint(_ value: UInt64, field: Int, to data: inout Data) {
        appendVarint(UInt64(field << 3), to: &data)
        appendVarint(value, to: &data)
    }

    private func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }
}

private func readVarint(_ data: Data, cursor: inout Int) -> UInt64? {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    while cursor < data.count && shift <= 63 {
        let byte = UInt64(data[cursor])
        cursor += 1
        value |= (byte & 0x7f) << shift
        if byte & 0x80 == 0 { return value }
        shift += 7
    }
    return nil
}

private func readLengthDelimited(_ data: Data, cursor: inout Int) -> Data? {
    guard let length = readVarint(data, cursor: &cursor) else { return nil }
    let end = cursor + Int(length)
    guard end <= data.count else { return nil }
    defer { cursor = end }
    return data[cursor..<end]
}

private func skipField(_ data: Data, cursor: inout Int, wireType: Int) -> Bool {
    switch wireType {
    case 0:
        return readVarint(data, cursor: &cursor) != nil
    case 1:
        guard cursor + 8 <= data.count else { return false }
        cursor += 8
        return true
    case 2:
        return readLengthDelimited(data, cursor: &cursor) != nil
    case 5:
        guard cursor + 4 <= data.count else { return false }
        cursor += 4
        return true
    default:
        return false
    }
}
