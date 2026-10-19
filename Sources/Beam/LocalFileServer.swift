import Foundation
import Darwin
import Network

final class LocalFileServer {
    private let queue = DispatchQueue(label: "beam.http", qos: .userInitiated)
    private var listener: NWListener?
    private var fileURL: URL?
    private var subtitleData: Data?
    private var hasServedInitialGet = false
    /// The connection currently streaming the movie. When the TV seeks it opens a
    /// new ranged request but often leaves the old one open, and two full-speed
    /// streams starve the new one so playback buffers forever.
    private var activeStream: NWConnection?

    /// Random per-session path prefix, so other devices on the network can't
    /// guess the URL and download the movie.
    private var token = ""

    /// Relative to the movie URL, so it inherits the session token.
    static let subtitlePath = "subtitles.vtt"

    func start(fileURL: URL, subtitleData: Data? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        stop()
        self.fileURL = fileURL
        self.subtitleData = subtitleData
        hasServedInitialGet = false
        token = (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
        let token = token
        var didComplete = false
        let completeOnce: (Result<URL, Error>) -> Void = { result in
            guard !didComplete else { return }
            didComplete = true
            completion(result)
        }

        do {
            let listener = try NWListener(using: .tcp)
            listener.service = nil
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    guard let listener, let port = listener.port?.rawValue else {
                        completeOnce(.failure(LocalFileServerError.couldNotStart))
                        return
                    }
                    guard let address = LocalFileServer.preferredIPv4Address() else {
                        completeOnce(.failure(LocalFileServerError.noLocalAddress))
                        return
                    }
                    let allowedPathCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
                    let encodedFileName = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: allowedPathCharacters) ?? "movie"
                    let streamPath = "/\(token)/\(encodedFileName)"
                    guard let url = URL(string: "http://\(address):\(port)\(streamPath)") else {
                        completeOnce(.failure(LocalFileServerError.couldNotStart))
                        return
                    }
                    completeOnce(.success(url))
                case .failed(let error):
                    completeOnce(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            completion(.failure(error))
        }
    }

    func updateSubtitles(_ data: Data) {
        queue.async { self.subtitleData = data }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        fileURL = nil
        subtitleData = nil
        activeStream?.cancel()
        activeStream = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                print("HTTP request failed: \(error)")
                connection.cancel()
                return
            }

            var requestData = buffer
            if let data {
                requestData.append(data)
            }

            let headerTerminator = Data("\r\n\r\n".utf8)
            if let end = requestData.range(of: headerTerminator) {
                let headerData = requestData.subdata(in: 0..<end.upperBound)
                guard let request = String(data: headerData, encoding: .utf8) else {
                    self.sendSimpleResponse(connection, status: "400 Bad Request", body: "Bad Request")
                    return
                }
                self.respond(to: request, on: connection)
            } else if requestData.count >= 32 * 1024 || isComplete {
                self.sendSimpleResponse(connection, status: "400 Bad Request", body: "Incomplete Request")
            } else {
                self.receiveRequest(on: connection, buffer: requestData)
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            sendSimpleResponse(connection, status: "404 Not Found", body: "File not found")
            return
        }

        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendSimpleResponse(connection, status: "400 Bad Request", body: "Bad Request")
            return
        }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            sendSimpleResponse(connection, status: "400 Bad Request", body: "Bad Request")
            return
        }

        let method = String(requestParts[0]).uppercased()
        let path = String(requestParts[1]).split(separator: "?").first.map(String.init) ?? "/"
        let decodedPath = path.removingPercentEncoding ?? path
        let expectedPath = "/\(token)/\(fileURL.lastPathComponent)"
        if path == "/\(token)/\(Self.subtitlePath)" {
            sendSubtitles(connection, method: method)
            return
        }
        guard decodedPath == expectedPath || path == "/health" else {
            sendSimpleResponse(connection, status: "404 Not Found", body: "Not Found")
            return
        }
        if path == "/health" {
            sendSimpleResponse(connection, status: "200 OK", body: "ok")
            return
        }
        guard method == "GET" || method == "HEAD" else {
            sendSimpleResponse(connection, status: "405 Method Not Allowed", body: "Method Not Allowed")
            return
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            sendSimpleResponse(connection, status: "500 Internal Server Error", body: "Could not read file")
            return
        }
        guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            sendSimpleResponse(connection, status: "500 Internal Server Error", body: "Could not read file size")
            return
        }
        let modificationDate = attributes[.modificationDate] as? Date ?? Date()

        let headers = Dictionary(uniqueKeysWithValues: lines.dropFirst().compactMap { line -> (String, String)? in
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            return (pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), pieces[1].trimmingCharacters(in: .whitespacesAndNewlines))
        })

        // Some Cast receivers (e.g. Xstream IPTV boxes) retry indefinitely when the
        // initial response is 206 Partial Content. Serve a progressive 200
        // response, matching its working reference server. Later requests
        // honor byte ranges so forward/backward seeking starts at the right
        // byte offset instead of replaying from the beginning.
        let requestedRange = method == "GET" ? Self.parseRange(headers["range"], fileSize: fileSize) : nil
        let range = hasServedInitialGet ? requestedRange : nil
        if method == "GET" {
            hasServedInitialGet = true
        }
        let start = range?.start ?? 0
        let end = range?.end ?? max(fileSize, 1) - 1
        let length = end >= start ? end - start + 1 : 0
        let status = range == nil ? "200 OK" : "206 Partial Content"
        let contentType = MIMEType.forFileExtension(fileURL.pathExtension)
        var response = "HTTP/1.0 \(status)\r\n"
        response += "Server: Beam/1.0\r\n"
        response += "Date: \(Self.httpDate(Date()))\r\n"
        response += "Last-Modified: \(Self.httpDate(modificationDate))\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(length)\r\n"
        response += "Accept-Ranges: bytes\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Headers: Range\r\n"
        response += "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges\r\n"
        if range != nil {
            response += "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n"
        }
        response += "\r\n"

        guard let headerData = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: headerData, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            if let error {
                print("HTTP header failed: \(error)")
                connection.cancel()
                return
            }
            if method == "HEAD" || length == 0 {
                connection.cancel()
                return
            }
            if self.activeStream !== connection {
                self.activeStream?.cancel()
                self.activeStream = connection
            }
            self.stream(fileURL: fileURL, offset: start, length: length, on: connection)
        })
    }

    static func parseRange(_ value: String?, fileSize: UInt64) -> (start: UInt64, end: UInt64)? {
        guard let value, value.lowercased().hasPrefix("bytes=") else { return nil }
        let rangeText = String(value.dropFirst("bytes=".count)).split(separator: ",").first.map(String.init) ?? ""
        // Keep empty pieces: seeks send open-ended ranges like "bytes=3472883712-".
        let parts = rangeText.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }

        if let start = UInt64(parts[0]), start < fileSize {
            let end = min(UInt64(parts[1]) ?? (fileSize - 1), fileSize - 1)
            return (start, max(start, end))
        }
        if let suffixLength = UInt64(parts[1]), suffixLength > 0 {
            let length = min(suffixLength, fileSize)
            return (fileSize - length, fileSize - 1)
        }
        return nil
    }

    private func stream(fileURL: URL, offset: UInt64, length: UInt64, on connection: NWConnection) {
        do {
            let file = try FileHandle(forReadingFrom: fileURL)
            try file.seek(toOffset: offset)
            streamNext(file: file, remaining: length, on: connection)
        } catch {
            connection.cancel()
        }
    }

    private func streamNext(file: FileHandle, remaining: UInt64, on connection: NWConnection) {
        guard remaining > 0 else {
            try? file.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        do {
            let requested = Int(min(1024 * 1024, remaining))
            let data = try file.read(upToCount: requested) ?? Data()
            guard !data.isEmpty else {
                try? file.close()
                connection.cancel()
                return
            }
            connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else { return }
                if error != nil {
                    try? file.close()
                    connection.cancel()
                    return
                }
                self.streamNext(file: file, remaining: remaining - UInt64(data.count), on: connection)
            })
        } catch {
            try? file.close()
            connection.cancel()
        }
    }

    private func sendSubtitles(_ connection: NWConnection, method: String) {
        guard let subtitleData else {
            sendSimpleResponse(connection, status: "404 Not Found", body: "No subtitles")
            return
        }
        // The Cast receiver fetches text tracks with XHR, so CORS headers are required.
        var response = "HTTP/1.0 200 OK\r\n"
        response += "Server: Beam/1.0\r\n"
        response += "Content-Type: text/vtt; charset=utf-8\r\n"
        response += "Content-Length: \(subtitleData.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Headers: Content-Type, Range\r\n"
        response += "\r\n"
        var data = Data(response.utf8)
        if method != "HEAD" && method != "OPTIONS" {
            data.append(subtitleData)
        }
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendSimpleResponse(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let response = "HTTP/1.0 \(status)\r\nServer: Beam/1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\n\r\n"
        var data = Data(response.utf8)
        data.append(bodyData)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func preferredIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var candidates: [(score: Int, address: String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let interface = item.pointee
            defer { current = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let value = String(cString: host)
            guard value != "127.0.0.1" else { continue }

            let name = String(cString: interface.ifa_name)
            let score: Int
            if name == "en0" || name == "en1" {
                score = 0
            } else if name.hasPrefix("en") {
                score = 1
            } else if name == "bridge0" {
                score = 2
            } else {
                score = 10
            }
            candidates.append((score, value))
        }
        return candidates.sorted { $0.score < $1.score }.first?.address
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

private enum LocalFileServerError: LocalizedError {
    case couldNotStart
    case noLocalAddress

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return "The local video server could not start."
        case .noLocalAddress: return "No local network address was found for the TV to reach."
        }
    }
}
