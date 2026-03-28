//
//  StreamProxyServer.swift
//  Noir
//
//  Proxies HLS (and other) streams with Referer/Origin so Infuse/VLC can play them.
//

import Foundation
import Network

/// Local HTTP server that proxies stream URLs with custom headers so external players (Infuse, VLC) can play streams that require Referer/Origin.
final class StreamProxyServer {
    static let shared = StreamProxyServer()
    
    private let queue = DispatchQueue(label: "noir.streamproxy")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var streamURL: String?
    private var headers: [String: String]?
    /// Title used in HLS #EXTINF so Infuse shows correct name instead of wrong/cached metadata.
    private var displayTitle: String?
    /// In-memory HLS playlists (e.g. soft-sub master) — same host as video so AVPlayer resolves variants correctly.
    private var extraPlaylistBodies: [String: Data] = [:]
    private var proxyBase: String { "http://127.0.0.1:\(port)" }
    private lazy var insecureSession: URLSession = {
        URLSession(configuration: .default, delegate: InsecureTrustingDelegate(), delegateQueue: nil)
    }()
    
    private init() {}

    private final class InsecureTrustingDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.performDefaultHandling, nil)
        }
    }

    /// Sanitizes a string for safe URL path usage while keeping it readable.
    /// Keeps only ASCII letters/numbers plus `.`, `_`, `-`. Collapses repeats and trims separators.
    private func sanitizeForPathComponent(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSep = false
        for scalar in s.unicodeScalars {
            if allowed.contains(scalar) {
                let ch = Character(scalar)
                let isSep = (ch == "." || ch == "_" || ch == "-")
                if isSep {
                    if lastWasSep { continue }
                    lastWasSep = true
                } else {
                    lastWasSep = false
                }
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "'" || scalar == "\"" || scalar == ":" || scalar == "/" || scalar == "\\" {
                // drop common troublemakers; keep the filename compact/readable
                continue
            } else {
                // drop everything else (emoji, punctuation, etc.)
                continue
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    }
    
    /// Start the server and register the initial stream URL and headers.
    /// - Parameters:
    ///   - metadataFilename: If set, URL path includes this so Infuse can match TMDB metadata (e.g. "Show.Name.S01E01.{tmdb-37606}.m3u8").
    ///   - displayTitle: Used in HLS #EXTINF for segment title; if nil, uses "Noir Stream".
    /// - Returns: Local URL to give to the external player (e.g. http://127.0.0.1:port/s or .../s/Show.S01E01.{tmdb-xxx}.m3u8).
    func start(streamURL: String, headers: [String: String], metadataFilename: String? = nil, displayTitle: String? = nil) -> String? {
        stop()
        self.streamURL = streamURL
        self.headers = headers
        self.displayTitle = displayTitle

        for p in (0..<100).map({ UInt16(28200 + $0) }) {
            guard let endpoint = NWEndpoint.Port(rawValue: p) else { continue }
            do {
                let listener = try NWListener(using: .tcp, on: endpoint)
                let readySignal = DispatchSemaphore(value: 0)
                final class StartState {
                    var ready = false
                    var failed = false
                    var failureText: String?
                }
                let startState = StartState()

                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        startState.ready = true
                        readySignal.signal()
                    case .failed(let err):
                        startState.failed = true
                        startState.failureText = String(describing: err)
                        Logger.shared.log("Stream proxy listener failed on port \(p): \(err)", type: "Error")
                        self?.listener = nil
                        readySignal.signal()
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] conn in
                    self?.handle(connection: conn)
                }
                listener.start(queue: queue)
                _ = readySignal.wait(timeout: .now() + 1.5)

                if startState.ready && !startState.failed {
                    self.listener = listener
                    self.port = p
                    let pathSegment: String
                    if let name = metadataFilename, !name.isEmpty {
                        // This becomes part of the URL path; keep it readable but remove unsafe characters entirely.
                        let safeName = sanitizeForPathComponent(name)
                        pathSegment = safeName.isEmpty ? "/s" : "/s/\(safeName)"
                    } else {
                        pathSegment = "/s"
                    }
                    let url = "\(proxyBase)\(pathSegment)"
                    Logger.shared.log("Stream proxy started at \(url)", type: "Stream")
                    return url
                }

                listener.cancel()
                if !startState.failed {
                    Logger.shared.log("Stream proxy listener did not become ready on port \(p) within timeout", type: "Error")
                }
            } catch {
                continue
            }
        }

        Logger.shared.log("Stream proxy failed to start on any port in range 28200-28299", type: "Error")
        return nil
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        streamURL = nil
        headers = nil
        displayTitle = nil
        extraPlaylistBodies.removeAll()
    }
    
    /// Registers a multivariant-style master that points at the current `/s/...` stream plus WebVTT subtitle tracks.
    /// Must be called after `start` while the proxy is running. Returns URL to open in AVPlayer (not file://).
    func registerSoftSubHLSMaster(variantURL: URL, subtitleTracks: [(title: String, url: String)]) -> URL? {
        guard !subtitleTracks.isEmpty, port > 0 else { return nil }
        let base = proxyBase
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        var mediaLines: [String] = []
        func inferDisplayName(title: String) -> String {
            let t = title.lowercased()
            // This path is only used for non-proxied usage today; keep naming readable.
            if t.contains("sign") && (t.contains("song") || t.contains("&") || t.contains("s&s")) { return "English — Signs & Songs" }
            if t.contains("full") { return "English — Full Subtitles" }
            if t.contains("cc") || t.contains("closed caption") { return "English — CC" }
            if t.contains("english") || t == "eng" || t == "en" { return "English" }
            return "English — \(title)"
        }
        for (i, track) in subtitleTracks.enumerated() {
            var sourceURL = track.url
            var delaySuffix = ""
            if track.url.hasPrefix("delay:"), let sep = track.url.firstIndex(of: "|") {
                let delayStart = track.url.index(track.url.startIndex, offsetBy: 6)
                let delayValue = String(track.url[delayStart..<sep])
                sourceURL = String(track.url[track.url.index(after: sep)...])
                if let delayEnc = delayValue.addingPercentEncoding(withAllowedCharacters: allowed), !delayEnc.isEmpty {
                    delaySuffix = "&delay=\(delayEnc)"
                }
            }
            guard let enc = sourceURL.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            let subPath = "/__noir_sub_\(i).m3u8"
            let vttLine = "\(base)/proxy?url=\(enc)\(delaySuffix)"
            let subBody = """
            #EXTM3U
            #EXT-X-TARGETDURATION:36000
            #EXT-X-VERSION:3
            #EXTINF:36000.000000,
            \(vttLine)
            #EXT-X-ENDLIST
            """
            extraPlaylistBodies[subPath] = Data(subBody.utf8)
            let display = track.title.replacingOccurrences(of: "\"", with: "'")
            mediaLines.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"noirsubs\",NAME=\"\(display)\",DEFAULT=NO,AUTOSELECT=NO,LANGUAGE=\"en\",URI=\"\(base)\(subPath)\"")
        }
        guard !mediaLines.isEmpty else { return nil }
        let variantLine = variantURL.absoluteString
        let master = """
        #EXTM3U
        #EXT-X-VERSION:6
        \(mediaLines.joined(separator: "\n"))
        #EXT-X-STREAM-INF:BANDWIDTH=10000000,SUBTITLES="noirsubs"
        \(variantLine)
        """
        let masterPath = "/__noir_master.m3u8"
        extraPlaylistBodies[masterPath] = Data(master.utf8)
        Logger.shared.log("Soft-sub HLS master registered at \(base)\(masterPath)", type: "Stream")
        return URL(string: "\(base)\(masterPath)")
    }

    /// Like `registerSoftSubHLSMaster`, but injects subtitles into the existing entry playlist text.
    /// This avoids nested-masters situations where AVPlayer can stall/black-screen while other players still succeed.
    func registerSoftSubHLSMasterFromEntryPlaylist(
        entryPlaylistURL: URL,
        subtitleTracks: [(title: String, url: String)]
    ) async -> URL? {
        guard !subtitleTracks.isEmpty, port > 0 else { return nil }

        let base = proxyBase
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))

        let masterPath = "/__noir_master.m3u8"

        func inferLanguageCode(title: String, url: String) -> String {
            let t = title.lowercased()
            let u = url.lowercased()
            if t.contains("english") || t.contains("eng") || u.contains("/eng") || u.contains("lang=en") { return "en" }
            if t.contains("spanish") || t.contains("español") || t.contains("esp") || u.contains("/spa") || u.contains("lang=es") { return "es" }
            if t.contains("portuguese") || t.contains("português") || t.contains("por") || u.contains("/por") || u.contains("lang=pt") { return "pt" }
            if t.contains("french") || t.contains("français") || t.contains("fra") || u.contains("/fra") || u.contains("lang=fr") { return "fr" }
            if t.contains("german") || t.contains("deutsch") || t.contains("deu") || u.contains("/deu") || u.contains("lang=de") { return "de" }
            if t.contains("italian") || t.contains("ita") || u.contains("/ita") || u.contains("lang=it") { return "it" }
            if t.contains("arabic") || t.contains("ara") || u.contains("/ara") || u.contains("lang=ar") { return "ar" }
            return "und"
        }

        enum NoirSubtitleKind {
            case full
            case signs
            case cc
            case other
        }

        func inferKind(title: String, url: String) -> NoirSubtitleKind {
            let t = title.lowercased()
            let u = url.lowercased()
            if t.contains("sign") && (t.contains("song") || t.contains("&") || t.contains("s&s")) { return .signs }
            if t.contains("full") { return .full }
            if t.contains("cc") || t.contains("closed caption") || u.contains("cc") { return .cc }
            return .other
        }

        func inferCharacteristics(kind: NoirSubtitleKind) -> String? {
            // Helps AVPlayer present distinct options instead of collapsing everything into one "English".
            switch kind {
            case .full:
                return "public.accessibility.transcribes-spoken-dialog"
            case .signs:
                return "public.accessibility.describes-music-and-sound"
            case .cc:
                return "public.accessibility.transcribes-spoken-dialog"
            case .other:
                return nil
            }
        }

        func inferDisplayName(title: String, url: String) -> String {
            let t = title.lowercased()
            if t == "delay" || t.contains("delay") { return "Delay" }
            if t.contains("signs & songs") { return "Signs & Songs" }
            if t.contains("full dialogue") || t.contains("full dialog") { return "Full Dialogue" }
            let lang = inferLanguageCode(title: title, url: url)
            let langLabel: String
            switch lang {
            case "en": langLabel = "English"
            case "es": langLabel = "Spanish"
            case "pt": langLabel = "Portuguese"
            case "fr": langLabel = "French"
            case "de": langLabel = "German"
            case "it": langLabel = "Italian"
            case "ar": langLabel = "Arabic"
            default: langLabel = "Subtitles"
            }
            // Parentheses naming tends to show better in the native menu than private-use language tags.
            if t.contains("sign") && (t.contains("song") || t.contains("&") || t.contains("s&s")) { return "\(langLabel) (Signs & Songs)" }
            if t.contains("full") { return "\(langLabel) (Full Subtitles)" }
            if t.contains("cc") || t.contains("closed caption") { return "\(langLabel) (CC)" }
            if t.contains("english") || t == "eng" || t == "en" { return langLabel }
            return "\(langLabel) (\(title))"
        }

        // Create subtitle playlists
        var mediaLines: [String] = []
        for (i, track) in subtitleTracks.enumerated() {
            var sourceURL = track.url
            var delaySuffix = ""
            if track.url.hasPrefix("delay:"), let sep = track.url.firstIndex(of: "|") {
                let delayStart = track.url.index(track.url.startIndex, offsetBy: 6)
                let delayValue = String(track.url[delayStart..<sep])
                sourceURL = String(track.url[track.url.index(after: sep)...])
                if let delayEnc = delayValue.addingPercentEncoding(withAllowedCharacters: allowed), !delayEnc.isEmpty {
                    delaySuffix = "&delay=\(delayEnc)"
                }
            }
            guard let enc = sourceURL.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            let subPath = "/__noir_sub_\(i).m3u8"
            let vttLine = "\(base)/proxy?url=\(enc)\(delaySuffix)"
            let subBody = """
            #EXTM3U
            #EXT-X-TARGETDURATION:36000
            #EXT-X-VERSION:3
            #EXTINF:36000.000000,
            \(vttLine)
            #EXT-X-ENDLIST
            """
            extraPlaylistBodies[subPath] = Data(subBody.utf8)

            let display = inferDisplayName(title: track.title, url: sourceURL).replacingOccurrences(of: "\"", with: "'")
            // Keep all custom options as explicit English entries in the native menu.
            mediaLines.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"noirsubs\",NAME=\"\(display)\",DEFAULT=NO,AUTOSELECT=NO,LANGUAGE=\"en\",URI=\"\(base)\(subPath)\"")
        }

        guard !mediaLines.isEmpty else { return nil }

        // Fetch the entry playlist text from the proxy URL so it already has rewritten segment URIs.
        var fetchedText: String? = nil
        var lastFetchError: String? = nil
        for attempt in 1...4 {
            do {
                let (data, response) = try await URLSession.shared.data(from: entryPlaylistURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    lastFetchError = "HTTP \(http.statusCode)"
                } else if let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") {
                    fetchedText = text
                    break
                } else {
                    lastFetchError = "invalid m3u8 payload"
                }
            } catch {
                lastFetchError = error.localizedDescription
            }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        guard let text = fetchedText else {
            Logger.shared.log("SoftSub: failed to fetch entry playlist after retries: \(lastFetchError ?? "unknown")", type: "Stream")
            return nil
        }

        let hasVariant = text.range(of: "#EXT-X-STREAM-INF") != nil
        let masterBody: String

            if hasVariant {
                let lines = text.components(separatedBy: .newlines)
                var out: [String] = []
                var inserted = false

                for line in lines {
                    if !inserted, line.hasPrefix("#EXTM3U") {
                        out.append(line)
                        out.append(contentsOf: mediaLines)
                        inserted = true
                        continue
                    }
                    if line.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") {
                        // Drop upstream subtitle declarations; we provide our own stable option group.
                        continue
                    }
                    if line.hasPrefix("#EXT-X-STREAM-INF") {
                        var L = line
                        if let range = L.range(of: #",?SUBTITLES=\"[^\"]*\""#, options: .regularExpression) {
                            L.removeSubrange(range)
                        }
                        L += L.hasSuffix(",") ? "SUBTITLES=\"noirsubs\"" : ",SUBTITLES=\"noirsubs\""
                        out.append(L)
                    } else {
                        out.append(line)
                    }
                }

                if !inserted {
                    out.insert(contentsOf: mediaLines, at: 0)
                    out.insert("#EXTM3U", at: 0)
                }
                masterBody = out.joined(separator: "\n")
            } else {
                masterBody = """
                #EXTM3U
                #EXT-X-VERSION:6
                \(mediaLines.joined(separator: "\n"))
                #EXT-X-STREAM-INF:BANDWIDTH=10000000,SUBTITLES="noirsubs"
                \(entryPlaylistURL.absoluteString)
                """
            }

        extraPlaylistBodies[masterPath] = Data(masterBody.utf8)
        Logger.shared.log("SoftSub: injected master served at \(base)\(masterPath)", type: "Stream")
        return URL(string: "\(base)\(masterPath)")
    }
    
    
    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection: connection, buffer: Data())
    }
    
    private func readRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let d = data, !d.isEmpty { buf.append(d) }
            if error != nil || isComplete {
                self.sendResponse(connection: connection, status: 400, body: nil) { connection.cancel() }
                return
            }
            guard let end = buf.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
                if buf.count > 100_000 { connection.cancel(); return }
                self.readRequest(connection: connection, buffer: buf)
                return
            }
            let headerData = buf.subdata(in: buf.startIndex..<end.lowerBound)
            guard let request = Self.parseRequest(headerData) else {
                self.sendResponse(connection: connection, status: 400, body: nil) { connection.cancel() }
                return
            }
            self.handleRequest(connection: connection, path: request.path, query: request.query) { status, contentType, body in
                self.sendResponse(connection: connection, status: status, contentType: contentType, body: body) {
                    connection.cancel()
                }
            }
        }
    }
    
    private struct ParsedRequest { let path: String; let query: [String: String] }
    
    private static func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        var path = String(parts[1])
        var query: [String: String] = [:]
        if let q = path.firstIndex(of: "?") {
            let qs = String(path[path.index(after: q)...])
            path = String(path[..<q])
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let v = String(kv[1]).removingPercentEncoding {
                    query[String(kv[0])] = v
                }
            }
        }
        return ParsedRequest(path: path, query: query)
    }
    
    private func handleRequest(connection: NWConnection, path: String, query: [String: String], completion: @escaping (Int, String?, Data?) -> Void) {
        if path == "/__noir_ready" {
            completion(200, "text/plain", Data("ok".utf8))
            return
        }
        if let body = extraPlaylistBodies[path] {
            Logger.shared.log("Proxy serving in-memory playlist: \(path)", type: "Stream")
            completion(200, "application/vnd.apple.mpegurl", body)
            return
        }
        let targetURL: String?
        var requestedSubtitleDelay: Double = 0
        var isSegmentRequest = false
        if path == "/s" || path == "/s/" || path.hasPrefix("/s/") {
            Logger.shared.log("Proxy forwarding stream playlist: \(path)", type: "Stream")
            targetURL = streamURL
        } else if (path == "/proxy" || path == "/segment.ts"), let raw = query["url"] {
            isSegmentRequest = (path == "/segment.ts")
            let u = raw.removingPercentEncoding ?? raw
            if let delayRaw = query["delay"], let d = Double(delayRaw) {
                requestedSubtitleDelay = d
            }
            // Truncate noisy URLs but keep host + extension if possible.
            let preview: String
            if let url = URL(string: u), let host = url.host {
                let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
                preview = "\(host)\(ext)"
            } else {
                preview = String(u.prefix(80))
            }
            Logger.shared.log("Proxy fetching: \(preview)", type: "Stream")
            targetURL = u
        } else {
            completion(404, nil, nil)
            return
        }
        guard let urlString = targetURL, let url = URL(string: urlString) else {
            completion(400, nil, nil)
            return
        }
        let isSubtitleLike: Bool = {
            let ext = url.pathExtension.lowercased()
            if ["vtt", "srt", "ass", "ssa", "ttml"].contains(ext) { return true }
            return urlString.lowercased().contains("/subs/") || urlString.lowercased().contains("subtitle")
        }()
        let hdrs = headers ?? [:]
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in hdrs { request.setValue(v, forHTTPHeaderField: k) }
        
        let finish: (Data?, URLResponse?, Error?) -> Void = { [weak self] data, response, error in
            guard let self = self else { return }
            if let err = error {
                let ns = err as NSError
                if isSubtitleLike, ns.domain == NSURLErrorDomain, ns.code == -1202 {
                    // Retry subtitle fetches with a session that accepts the server trust.
                    let retry = self.insecureSession.dataTask(with: request) { data2, resp2, err2 in
                        if let err2 {
                            Logger.shared.log("Proxy subtitle insecure fetch error: \(err2)", type: "Stream")
                            completion(502, nil, nil)
                            return
                        }
                        let code2 = (resp2 as? HTTPURLResponse)?.statusCode ?? 500
                        guard code2 == 200, let body2 = data2 else {
                            Logger.shared.log("Proxy subtitle insecure upstream HTTP \(code2) for \(urlString)", type: "Stream")
                            completion(code2, nil, nil)
                            return
                        }
                        let contentType2 = (resp2 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
                        let normalized2 = self.normalizeSubtitleForAVPlayerIfNeeded(data: body2, targetURL: urlString, contentType: contentType2)
                        let shifted2 = self.shiftSubtitleTimingIfNeeded(data: normalized2, delaySeconds: requestedSubtitleDelay)
                        let replyType2 = isSubtitleLike ? "text/vtt" : (contentType2.isEmpty ? nil : contentType2)
                        completion(200, replyType2, shifted2)
                    }
                    retry.resume()
                    return
                }
                Logger.shared.log("Proxy fetch error: \(err)", type: "Stream")
                completion(502, nil, nil)
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            guard code == 200, let body = data else {
                Logger.shared.log("Proxy upstream HTTP \(code) for \(urlString)", type: "Stream")
                completion(code, nil, nil)
                return
            }
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let isM3u8 = urlString.contains(".m3u8") || contentType.contains("mpegurl") || contentType.contains("m3u8")
            if isM3u8, let rewritten = self.rewriteM3u8(body, baseURL: url), let rewrittenData = rewritten.data(using: .utf8) {
                Logger.shared.log("Proxy rewrote HLS playlist for: \(urlString)", type: "Stream")
                completion(200, "application/vnd.apple.mpegurl", rewrittenData)
            } else {
                let normalized = self.normalizeSubtitleForAVPlayerIfNeeded(data: body, targetURL: urlString, contentType: contentType)
                let shifted = self.shiftSubtitleTimingIfNeeded(data: normalized, delaySeconds: requestedSubtitleDelay)
                let replyType: String?
                if isSubtitleLike {
                    replyType = "text/vtt"
                } else if isSegmentRequest {
                    replyType = self.sniffProxiedSegmentContentType(data: shifted, upstreamContentType: contentType)
                } else {
                    replyType = contentType.isEmpty ? nil : contentType
                }
                completion(200, replyType, shifted)
            }
        }
        URLSession.shared.dataTask(with: request, completionHandler: finish).resume()
    }

    /// Some CDNs label MPEG-TS or fMP4 as `image/gif` / `image/png` to confuse scrapers. AVPlayer trusts `Content-Type` and will not decode video if wrong ([Apple HLS MIME guidance](https://developer.apple.com/documentation/http-live-streaming/deploying-a-basic-http-live-streaming-hls-stream)).
    private func sniffProxiedSegmentContentType(data: Data, upstreamContentType: String) -> String {
        let upstreamLower = upstreamContentType.lowercased()
        guard !data.isEmpty else {
            return upstreamContentType.isEmpty ? "application/octet-stream" : upstreamContentType
        }
        let first = data[data.startIndex]
        if first == 0x47 {
            if upstreamLower.hasPrefix("image/") || upstreamLower.isEmpty {
                Logger.shared.log("Proxy MIME override: upstream=\(upstreamContentType.isEmpty ? "(none)" : upstreamContentType) -> video/MP2T (MPEG-TS sync 0x47)", type: "Stream")
            }
            return "video/MP2T"
        }
        if data.count >= 8 {
            let four = data.subdata(in: data.index(data.startIndex, offsetBy: 4)..<data.index(data.startIndex, offsetBy: 8))
            if four == Data([0x66, 0x74, 0x79, 0x70]) || four == Data([0x73, 0x74, 0x79, 0x70]) {
                if upstreamLower.hasPrefix("image/") || upstreamLower.isEmpty {
                    Logger.shared.log("Proxy MIME override: upstream=\(upstreamContentType.isEmpty ? "(none)" : upstreamContentType) -> video/mp4 (ftyp/styp)", type: "Stream")
                }
                return "video/mp4"
            }
        }
        if upstreamLower.hasPrefix("image/") {
            Logger.shared.log("Proxy MIME: segment upstream=\(upstreamContentType) not TS/fMP4 at start; using application/octet-stream", type: "Stream")
            return "application/octet-stream"
        }
        return upstreamContentType.isEmpty ? "application/octet-stream" : upstreamContentType
    }
    
    /// Rewrite m3u8 so segment URLs go through this proxy with headers, and strip #EXTINF titles so Infuse doesn't show wrong metadata (e.g. "State of Fear") after playback.
    private func rewriteM3u8(_ body: Data, baseURL: URL) -> String? {
        guard let raw = String(data: body, encoding: .utf8) else { return nil }
        let base = baseURL.deletingLastPathComponent()
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        let definitelyNonMediaSegmentExts: Set<String> = [
            // NOTE: Some providers disguise media segments behind non-video extensions.
            // We only use this set to drop *out-of-context* URI lines (i.e. when we are
            // not expecting a segment/playlist URI). If a line is the URI immediately
            // following `#EXTINF`, we must proxy it even if the extension looks wrong.
            "webp", "png", "jpg", "jpeg", "svg",
            "css", "js", "json", "xml", "html", "txt",
            "woff", "woff2", "ttf", "otf", "eot", "ico",
            "gif", "vtt", "srt", "ass", "ssa", "ttml"
        ]

        func proxiedURLString(for rawURL: String) -> String? {
            let resolved: String
            if rawURL.contains("://") {
                resolved = rawURL
            } else if let u = URL(string: rawURL, relativeTo: base) {
                resolved = u.absoluteString
            } else {
                return nil
            }
            let encoded = resolved.addingPercentEncoding(withAllowedCharacters: allowed) ?? resolved
            return "\(proxyBase)/proxy?url=\(encoded)"
        }



        func rewriteAttributeURI(in tagLine: String) -> String? {
            // Rewrites URI="..." inside tags like EXT-X-KEY / EXT-X-MAP / EXT-X-PART.
            guard let uriRange = tagLine.range(of: #"URI=\"[^\"]+\""#, options: .regularExpression) else { return nil }
            let match = String(tagLine[uriRange]) // URI="..."
            guard let q1 = match.firstIndex(of: "\""), let q2 = match.lastIndex(of: "\""), q2 > q1 else { return nil }
            let inner = String(match[match.index(after: q1)..<q2])
            guard let proxied = proxiedURLString(for: inner) else { return nil }
            var rewritten = tagLine
            rewritten.replaceSubrange(uriRange, with: "URI=\"\(proxied)\"")
            return rewritten
        }

        func looksLikeLooseMediaURI(_ s: String) -> Bool {
            let t = s.lowercased()
            if t.contains("://") { return true }
            if t.contains(".m3u8") || t.contains(".ts") || t.contains(".m4s") || t.contains(".mp4") {
                return true
            }
            // Some providers emit extension-less segment paths (opaque tokens) between tags.
            // Accept path-like, whitespace-free lines as URI candidates and rely on extension
            // denylist below to filter obvious non-media assets.
            if t.contains(" ") || t.contains("\t") { return false }
            if t.hasPrefix("{") || t.hasPrefix("[") { return false }
            if t.hasPrefix("data:") { return false }
            if t.hasPrefix("/") || t.hasPrefix("./") || t.hasPrefix("../") { return true }
            if t.count >= 6 && t.count <= 2048 { return true }
            return false
        }

        var expectsURI = false
        var skippedUnexpectedURI = 0

        for line in lines {
            var s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)

            // Replace title in #EXTINF:duration,Title so Infuse shows correct metadata.
            if s.hasPrefix("#EXTINF:") {
                if let comma = s.firstIndex(of: ",") {
                    let title = displayTitle ?? "Noir Stream"
                    s = String(s[..<s.index(after: comma)]) + title
                }
                out.append(s)
                expectsURI = true
                continue
            }

            if s.isEmpty {
                out.append(String(line))
                continue
            }

            if s.hasPrefix("#") {
                if s.contains("URI=\""), let rewritten = rewriteAttributeURI(in: s) {
                    out.append(rewritten)
                } else {
                    out.append(String(line))
                }

                // URI-expected tags where the next non-tag line is a URI.
                if s.hasPrefix("#EXT-X-STREAM-INF") || s.hasPrefix("#EXT-X-BYTERANGE") {
                    expectsURI = true
                }
                continue
            }

            // Prefer strict HLS context, but allow a loose fallback for providers that emit
            // non-tag URI lines without the expected preceding marker tags.
            if !expectsURI {
                guard looksLikeLooseMediaURI(s) else {
                    skippedUnexpectedURI += 1
                    continue
                }
            }

            let segmentURL: String
            if s.contains("://") {
                segmentURL = s
            } else if let resolved = URL(string: s, relativeTo: base) {
                segmentURL = resolved.absoluteString
            } else {
                out.append(String(line))
                expectsURI = false
                continue
            }

            if !expectsURI,
               let segURL = URL(string: segmentURL),
               definitelyNonMediaSegmentExts.contains(segURL.pathExtension.lowercased())
            {
                // Provider occasionally injects asset-like lines into playlists; drop these only when
                // they appear out-of-context (i.e. not as the expected URI following #EXTINF / stream tags).
                skippedUnexpectedURI += 1
                expectsURI = false
                continue
            }

            let encoded = segmentURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? segmentURL
            // Noir runtime expects media segment lines to be TS-like entries.
            out.append("\(proxyBase)/segment.ts?url=\(encoded)")
            expectsURI = false
        }

        let rewritten = out.joined(separator: "\n")
        let proxiedCount = out.filter { $0.contains("/proxy?url=") || $0.contains("/segment.ts?url=") }.count
        let hasDirectHTTPLine = out.contains { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && !t.hasPrefix("#") && t.contains("://")
        }
        let directFlag = hasDirectHTTPLine ? "YES" : "NO"
        Logger.shared.log("Proxy playlist summary: proxiedLines=\(proxiedCount) skippedUnexpectedURI=\(skippedUnexpectedURI) directHTTPNonTag=\(directFlag)", type: "Stream")
        return rewritten
    }

    private func normalizeSubtitleForAVPlayerIfNeeded(data: Data, targetURL: String, contentType: String?) -> Data {
        let lowerURL = targetURL.lowercased()
        let lowerCT = (contentType ?? "").lowercased()
        let looksLikeSubtitle = [".vtt", ".srt", ".ass", ".ssa", ".ttml"].contains { lowerURL.contains($0) }
            || lowerURL.contains("/subs/")
            || lowerURL.contains("subtitle")
            || lowerCT.contains("vtt")
            || lowerCT.contains("subrip")
            || lowerCT.contains("subtitle")
        guard looksLikeSubtitle else { return data }
        guard var text = String(data: data, encoding: .utf8) else { return data }

        if text.hasPrefix("WEBVTT") || text.hasPrefix("#EXTM3U") { return data }

        // Convert basic SRT into WebVTT so AVPlayer renders lines correctly.
        if text.contains("-->") {
            let converted = text
                .components(separatedBy: .newlines)
                .map { line -> String in
                    if line.contains("-->") {
                        return line.replacingOccurrences(of: ",", with: ".")
                    }
                    return line
                }
                .joined(separator: "\n")
            text = "WEBVTT\n\n" + converted
            return text.data(using: .utf8) ?? data
        }

        return data
    }

    private func shiftSubtitleTimingIfNeeded(data: Data, delaySeconds: Double) -> Data {
        guard abs(delaySeconds) > 0.0001 else { return data }
        guard let text = String(data: data, encoding: .utf8) else { return data }

        let shifted = text
            .components(separatedBy: .newlines)
            .map { line -> String in
                guard line.contains("-->") else { return line }
                let parts = line.components(separatedBy: "-->")
                guard parts.count == 2 else { return line }

                let leftRaw = parts[0].trimmingCharacters(in: .whitespaces)
                let rightRaw = parts[1].trimmingCharacters(in: .whitespaces)
                guard let left = parseSubtitleTimestamp(leftRaw), let right = parseSubtitleTimestamp(rightRaw) else { return line }

                let start = max(0, left.seconds + delaySeconds)
                let end = max(start, right.seconds + delaySeconds)
                let startText = formatSubtitleTimestamp(seconds: start, usesComma: left.usesComma)
                let endText = formatSubtitleTimestamp(seconds: end, usesComma: right.usesComma)
                return "\(startText) --> \(endText)"
            }
            .joined(separator: "\n")

        return shifted.data(using: .utf8) ?? data
    }

    private func parseSubtitleTimestamp(_ raw: String) -> (seconds: Double, usesComma: Bool)? {
        let token = raw.trimmingCharacters(in: .whitespaces)
        let usesComma = token.contains(",")
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let comps = normalized.split(separator: ":")

        let h: Double
        let m: Double
        let s: Double

        if comps.count == 3 {
            h = Double(comps[0]) ?? -1
            m = Double(comps[1]) ?? -1
            s = Double(comps[2]) ?? -1
        } else if comps.count == 2 {
            h = 0
            m = Double(comps[0]) ?? -1
            s = Double(comps[1]) ?? -1
        } else {
            return nil
        }

        guard h >= 0, m >= 0, s >= 0 else { return nil }
        return (h * 3600 + m * 60 + s, usesComma)
    }

    private func formatSubtitleTimestamp(seconds: Double, usesComma: Bool) -> String {
        let clamped = max(0, seconds)
        let totalMillis = Int((clamped * 1000.0).rounded())
        let h = totalMillis / 3_600_000
        let m = (totalMillis % 3_600_000) / 60_000
        let s = (totalMillis % 60_000) / 1000
        let ms = totalMillis % 1000
        let sep = usesComma ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, sep, ms)
    }

    private func sendResponse(connection: NWConnection, status: Int, contentType: String? = nil, body: Data?, completion: @escaping () -> Void = {}) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Connection: close\r\n"
        if let ct = contentType { head += "Content-Type: \(ct)\r\n" }
        if let b = body {
            head += "Content-Length: \(b.count)\r\n"
            head += "\r\n"
            let headerData = Data(head.utf8)
            connection.send(content: headerData + b, completion: .contentProcessed { _ in completion() })
        } else {
            head += "Content-Length: 0\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in completion() })
        }
    }
}
