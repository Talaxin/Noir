//
//  JSLoader-Streams.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import JavaScriptCore

extension JSController {
    struct ParsedStreamPayload {
        let streams: [String]?
        let subtitles: [String]?
        let sources: [[String: Any]]?
    }

    static func parseStreamJSONString(_ jsonString: String) -> ParsedStreamPayload? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                return ParsedStreamPayload(
                    streams: Self.parseStreamURLList(from: json),
                    subtitles: Self.parseSubtitleList(from: json),
                    sources: Self.parseStreamSources(from: json)
                )
            }
            if let streamsArray = try JSONSerialization.jsonObject(with: data, options: []) as? [String] {
                return ParsedStreamPayload(streams: streamsArray, subtitles: nil, sources: nil)
            }
        } catch {
            Logger.shared.log("JSON parsing error: \(error.localizedDescription)", type: "Error")
        }
        return ParsedStreamPayload(streams: [jsonString], subtitles: nil, sources: nil)
    }

    private static func parseStreamSources(from json: [String: Any]) -> [[String: Any]]? {
        if let streamSources = json["streams"] as? [[String: Any]] {
            Logger.shared.log("Found \(streamSources.count) streams and headers", type: "Stream")
            return streamSources
        }
        if let streamSource = json["stream"] as? [String: Any] {
            Logger.shared.log("Found single stream with headers", type: "Stream")
            return [streamSource]
        }
        return nil
    }

    private static func parseStreamURLList(from json: [String: Any]) -> [String]? {
        if json["streams"] is [[String: Any]] { return nil }
        if let streamsArray = json["streams"] as? [String] {
            Logger.shared.log("Found \(streamsArray.count) streams", type: "Stream")
            return streamsArray
        }
        if let streamUrl = json["stream"] as? String {
            Logger.shared.log("Found single stream", type: "Stream")
            return [streamUrl]
        }
        return nil
    }

    private static func parseSubtitleList(from json: [String: Any]) -> [String]? {
        if let subsArray = json["subtitles"] as? [String] {
            Logger.shared.log("Found \(subsArray.count) subtitle entries (flat list)", type: "Stream")
            return subsArray
        }
        if let subsObjects = json["subtitles"] as? [[String: Any]] {
            var flat: [String] = []
            for o in subsObjects {
                let url = (o["file"] as? String) ?? (o["url"] as? String) ?? (o["src"] as? String)
                let label = (o["label"] as? String) ?? (o["lang"] as? String) ?? "Subtitles"
                if let url = url, !url.isEmpty {
                    flat.append(label)
                    flat.append(url)
                }
            }
            Logger.shared.log("Found \(subsObjects.count) subtitle objects → \(flat.count / 2) tracks", type: "Stream")
            return flat.isEmpty ? nil : flat
        }
        if let subtitleUrl = json["subtitles"] as? String, !subtitleUrl.isEmpty {
            Logger.shared.log("Found single subtitle track", type: "Stream")
            return [subtitleUrl]
        }
        return nil
    }

    /// - Parameter onProgress: Optional handler for modules that emit partial results via `noirOnStreamsProgress` (e.g. Checkmate).
    func fetchStreamUrlJS(
        episodeUrl: String,
        softsub: Bool = false,
        module: Service,
        preferredCategory: String? = nil,
        onProgress: (([String]?, [String]?, [[String: Any]]?) -> Void)? = nil,
        completion: @escaping ((streams: [String]?, subtitles: [String]?, sources: [[String: Any]]?)) -> Void
    ) {
        if let exception = context.exception {
            Logger.shared.log("JavaScript exception: \(exception)", type: "Error")
            completion((nil, nil, nil))
            return
        }

        guard let extractStreamUrlFunction = context.objectForKeyedSubscript("extractStreamUrl") else {
            Logger.shared.log("No JavaScript function extractStreamUrl found", type: "Error")
            completion((nil, nil, nil))
            return
        }

        streamProgressHandler = onProgress

        var args: [Any] = [episodeUrl]
        if let cat = preferredCategory, !cat.isEmpty {
            args.append(cat)
        }
        let promiseValue = extractStreamUrlFunction.call(withArguments: args)
        guard let promise = promiseValue else {
            streamProgressHandler = nil
            Logger.shared.log("extractStreamUrl did not return a Promise", type: "Error")
            completion((nil, nil, nil))
            return
        }

        let finish: (JSValue) -> Void = { [weak self] result in
            guard let self else { return }
            defer { self.streamProgressHandler = nil }

            if result.isNull || result.isUndefined {
                Logger.shared.log("Received null or undefined result from JavaScript", type: "Error")
                DispatchQueue.main.async { completion((nil, nil, nil)) }
                return
            }

            if let resultString = result.toString(), resultString == "[object Promise]" {
                Logger.shared.log("Received Promise object instead of resolved value, waiting for proper resolution", type: "Stream")
                return
            }

            guard let jsonString = result.toString(), let parsed = Self.parseStreamJSONString(jsonString) else {
                Logger.shared.log("Failed to convert JSValue to string", type: "Error")
                DispatchQueue.main.async { completion((nil, nil, nil)) }
                return
            }

            Logger.shared.log("Starting stream with \(parsed.streams?.count ?? 0) sources and \(parsed.subtitles?.count ?? 0) subtitles", type: "Stream")
            DispatchQueue.main.async {
                completion((parsed.streams, parsed.subtitles, parsed.sources))
            }
        }

        let thenBlock: @convention(block) (JSValue) -> Void = { result in
            finish(result)
        }

        let catchBlock: @convention(block) (JSValue) -> Void = { [weak self] error in
            self?.streamProgressHandler = nil
            let errorMessage = error.toString() ?? "Unknown JavaScript error"
            Logger.shared.log("Promise rejected: \(errorMessage)", type: "Error")
            DispatchQueue.main.async {
                completion((nil, nil, nil))
            }
        }

        let thenFunction = JSValue(object: thenBlock, in: context)
        let catchFunction = JSValue(object: catchBlock, in: context)

        guard let thenFunction = thenFunction, let catchFunction = catchFunction else {
            streamProgressHandler = nil
            Logger.shared.log("Failed to create JSValue objects for Promise handling", type: "Error")
            completion((nil, nil, nil))
            return
        }

        promise.invokeMethod("then", withArguments: [thenFunction])
        promise.invokeMethod("catch", withArguments: [catchFunction])
    }
}
