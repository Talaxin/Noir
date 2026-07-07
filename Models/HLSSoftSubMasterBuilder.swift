//
//  HLSSoftSubMasterBuilder.swift
//  Noir
//
//  Injects WebVTT softsubs into HLS so AVPlayerViewController’s built-in subtitle menu works.
//

import Foundation

enum HLSSoftSubMasterBuilder {
    /// Writes a local multivariant master + per-track WebVTT playlists. Subtitles default off (DEFAULT=NO).
    /// - Parameters:
    ///   - entryPlaylistURL: Top-level playlist URL (e.g. stream proxy root).
    ///   - subtitleTracks: Display name + raw subtitle file URL.
    ///   - proxyBase: If set (e.g. `http://127.0.0.1:28200`), VTT lines use `/proxy?url=` so Referer headers apply.
    static func makeLocalMasterURL(
        entryPlaylistURL: URL,
        entryRequestHeaders: [String: String],
        subtitleTracks: [(title: String, url: String)],
        proxyBase: String?
    ) async -> URL? {
        guard !subtitleTracks.isEmpty else { return nil }
        var req = URLRequest(url: entryPlaylistURL)
        for (k, v) in entryRequestHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(URLSession.randomUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            Logger.shared.log("HLSSoftSub: failed to fetch playlist: \(error.localizedDescription)", type: "Stream")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else {
            Logger.shared.log("HLSSoftSub: not a valid HLS playlist", type: "Stream")
            return nil
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noir_softsub_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        for (i, track) in subtitleTracks.enumerated() {
            let vttURL: String
            if let base = proxyBase, let enc = track.url.addingPercentEncoding(withAllowedCharacters: allowed) {
                let sep = base.hasSuffix("/") ? "" : "/"
                vttURL = "\(base)\(sep)proxy?url=\(enc)"
            } else {
                vttURL = track.url
            }
            let subPlaylist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:36000
            #EXT-X-VERSION:3
            #EXTINF:36000.0,
            \(vttURL)
            #EXT-X-ENDLIST
            """
            let subPath = dir.appendingPathComponent("noir_sub_\(i).m3u8")
            try? subPlaylist.write(to: subPath, atomically: true, encoding: .utf8)
        }
        let mediaLines = subtitleTracks.enumerated().map { i, t -> String in
            let name = t.title.replacingOccurrences(of: "\"", with: "'")
            return "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"noirsubs\",NAME=\"\(name)\",DEFAULT=NO,AUTOSELECT=NO,LANGUAGE=\"und\",URI=\"noir_sub_\(i).m3u8\""
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
                if line.hasPrefix("#EXT-X-STREAM-INF") {
                    var L = line
                    if !L.contains("SUBTITLES=") {
                        L += L.hasSuffix(",") ? "SUBTITLES=\"noirsubs\"" : ",SUBTITLES=\"noirsubs\""
                    }
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
            let entry = entryPlaylistURL.absoluteString
            masterBody = """
            #EXTM3U
            #EXT-X-VERSION:6
            \(mediaLines.joined(separator: "\n"))
            #EXT-X-STREAM-INF:BANDWIDTH=10000000,SUBTITLES="noirsubs"
            \(entry)
            """
        }
        let masterURL = dir.appendingPathComponent("master.m3u8")
        do {
            try masterBody.write(to: masterURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        Logger.shared.log("HLSSoftSub: local master with \(subtitleTracks.count) subtitle track(s)", type: "Stream")
        return masterURL
    }
}
