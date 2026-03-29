/**
 * Miruro service for Noir (miruro.to)
 * Uses the secure pipe API: GET /api/secure/pipe?e=base64({path, method, query, body})
 * Streams via pro.ultracloud.cc (Referer required).
 */

const BASE = "https://www.miruro.to";

const HEADERS = {
  "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  "Accept": "application/json",
  "Referer": BASE + "/"
};

function safeText(res) {
  if (!res || typeof res.text !== "function") return Promise.resolve("");
  return res.text().then(function (t) { return t != null ? String(t) : ""; }).catch(function () { return ""; });
}

/** RFC-like Origin: scheme + host (+ port). Some CDNs reject Origin when it includes a path. */
function originFromReferer(ref) {
  if (!ref || typeof ref !== "string") return BASE.replace(/\/$/, "");
  try {
    return new URL(ref).origin;
  } catch (e) {
    return String(ref).replace(/\/$/, "");
  }
}

/**
 * Call the secure pipe API.
 * @param {string} path - e.g. "config", "sources", "search", "anime", "episodes"
 * @param {object} query - query params (e.g. { episodeId, provider, category, anilistId })
 * @returns {Promise<object>} parsed JSON response
 */
async function pipe(path, query) {
  var payload = { path: path, method: "GET", query: query || {}, body: null };
  var jsonStr = JSON.stringify(payload);
  var e = btoa(jsonStr);
  var url = BASE + "/api/secure/pipe?e=" + encodeURIComponent(e);
  var res = await fetchv2(url, HEADERS);
  var text = await safeText(res);
  if (!text || res.status !== 200) {
    var status = res.status != null ? res.status : "no status";
    var snippet = (text && text.length > 0) ? (" body: " + String(text).substring(0, 80)) : " (empty body)";
    throw new Error("Pipe " + path + " failed: " + status + snippet);
  }
  var trimmed = text.trim();
  var jsonString = trimmed;
  if (trimmed.charAt(0) !== "{" && trimmed.charAt(0) !== "[") {
    if (typeof decodePipeResponse === "function") {
      var decoded = decodePipeResponse(trimmed);
      if (decoded && (decoded.charAt(0) === "{" || decoded.charAt(0) === "[")) jsonString = decoded;
    }
    if (jsonString.charAt(0) !== "{" && jsonString.charAt(0) !== "[") {
      var preview = (trimmed.length > 0) ? trimmed.substring(0, 60) : "(empty)";
      throw new Error("Pipe " + path + " non-JSON (got: " + preview + ")");
    }
  }
  return JSON.parse(jsonString);
}

async function searchResults(keyword) {
  var results = [];
  try {
    // Pipe search: path "search", query { q, limit, offset, type, sort }
    var pipeRes = await pipe("search", { q: keyword, limit: 15, offset: 0, type: "ANIME", sort: "POPULARITY_DESC" });
    var list = pipeRes.results || pipeRes.data || (pipeRes.Page && pipeRes.Page.media) || (Array.isArray(pipeRes) ? pipeRes : []);
    if (Array.isArray(list) && list.length) {
      for (var i = 0; i < list.length; i++) {
        var item = list[i];
        var id = item.id != null ? item.id : (item.anilistId != null ? item.anilistId : item.malId);
        var title = (item.title && (item.title.userPreferred || item.title.english || item.title.romaji)) ? (item.title.userPreferred || item.title.english || item.title.romaji) : (item.title || "Unknown");
        var img = (item.coverImage && (item.coverImage.large || item.coverImage.medium)) ? (item.coverImage.large || item.coverImage.medium) : (item.image || item.poster || "");
        results.push({ title: title, image: img, href: BASE + "/info/" + (id != null ? id : "") });
      }
      return JSON.stringify(results);
    }
    return JSON.stringify([{ title: "No results found", image: "", href: "" }]);
  } catch (err) {
    var msg = (err && (err.message || (err.toString && err.toString()))) || String(err);
    console.error("Miruro search error: " + msg);
    return JSON.stringify([{ title: "Search failed", image: "", href: "" }]);
  }
}

async function extractDetails(url) {
  try {
    var anilistId = null;
    if (url && /\/info\/(\d+)/.test(url)) anilistId = RegExp.$1;
    if (!anilistId) return JSON.stringify([{ description: "Invalid URL (expected /info/{id})", aliases: "", airdate: "" }]);
    var info = await pipe("info/" + anilistId, {});
    var data = info.media || info.data || info;
    var desc = data.description || data.synopsis || "N/A";
    var aliases = Array.isArray(data.synonyms) ? data.synonyms.join(", ") : (data.aliases || "N/A");
    var airdate = "N/A";
    if (data.startDate && data.startDate.year) {
      var parts = [data.startDate.year, data.startDate.month, data.startDate.day];
      airdate = parts.filter(Boolean).join("-");
    } else if (data.releaseDate) airdate = data.releaseDate;
    else if (data.airdate) airdate = data.airdate;
    return JSON.stringify([{ description: desc, aliases: aliases, airdate: airdate }]);
  } catch (err) {
    console.error("Miruro extractDetails error:", err);
    return JSON.stringify([{ description: "Error loading details", aliases: "", airdate: "" }]);
  }
}

async function extractEpisodes(url) {
  try {
    var anilistId = null;
    if (url && /\/info\/(\d+)/.test(url)) anilistId = RegExp.$1;
    if (!anilistId) return JSON.stringify([{ number: 1, href: "" }]);
    var epRes = await pipe("episodes", { anilistId: String(anilistId) });
    var list = [];
    var prov = epRes.providers || {};
    if (prov.arc && prov.arc.episodes) {
      list = prov.arc.episodes.sub || prov.arc.episodes.dub || [];
    }
    if (!list.length && prov.kiwi && prov.kiwi.episodes) {
      list = prov.kiwi.episodes.sub || prov.kiwi.episodes.dub || [];
    }
    if (!Array.isArray(list) || !list.length) return JSON.stringify([{ number: 1, href: "" }]);
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var ep = list[i];
      var num = parseInt(ep.number != null ? ep.number : (ep.episode != null ? ep.episode : (i + 1)), 10) || (i + 1);
      var episodeId = ep.id != null ? ep.id : (ep.episodeId != null ? ep.episodeId : ep.slug);
      if (episodeId == null || typeof episodeId === "object") episodeId = String(num);
      else episodeId = String(episodeId);
      out.push({ number: num, href: episodeId + "|" + anilistId });
    }
    return JSON.stringify(out);
  } catch (err) {
    console.error("Miruro extractEpisodes error:", err);
    return JSON.stringify([{ number: 1, href: "" }]);
  }
}

/**
 * Fetches stream URLs for an episode. Pipe API: path "sources", query { episodeId, provider, category, anilistId }.
 * Optional second argument: "sub" or "dub" to only fetch that category (like Ashi: user chooses before fetch).
 * If omitted, requests both and returns all streams with SUB/DUB labels.
 */
async function extractStreamUrl(episodeIdOrUrl, preferredCategory) {
  try {
    var episodeId = null;
    var anilistId = null;
    var raw = typeof episodeIdOrUrl === "string" ? episodeIdOrUrl : "";
    if (raw.indexOf("|") >= 0) {
      var parts = raw.split("|");
      episodeId = parts[0];
      anilistId = parts[1] ? parseInt(parts[1], 10) : null;
    } else {
      episodeId = raw;
    }
    if (!episodeId) return JSON.stringify({ streams: [], subtitles: [] });
    var streamHeaders = { "Referer": BASE + "/", "Origin": BASE, "User-Agent": HEADERS["User-Agent"] };
    var streams = [];
    /** Flat list [label1, url1, label2, url2, ...] for app subtitle menu (all languages). */
    var subtitleTracks = [];
    var subtitleSeen = {};
    function collectSubtitles(subs) {
      if (!Array.isArray(subs)) return;
      for (var t = 0; t < subs.length; t++) {
        var track = subs[t];
        var u = track.file || track.url || track.src;
        if (!u || subtitleSeen[u]) continue;
        subtitleSeen[u] = true;
        var lab = (track.label || track.lang || "Subtitles").trim();
        if (!lab) lab = "Subtitles";
        subtitleTracks.push(lab, u);
      }
    }
    var providers = ["kiwi", "arc"];
    /** Video streams: only the category the user picked (or both if unspecified). */
    var streamCategories = (preferredCategory === "sub" || preferredCategory === "dub") ? [preferredCategory] : ["sub", "dub"];
    for (var p = 0; p < providers.length; p++) {
      for (var c = 0; c < streamCategories.length; c++) {
        try {
          var q = { episodeId: episodeId, provider: providers[p], category: streamCategories[c] };
          if (anilistId != null) q.anilistId = parseInt(anilistId, 10);
          var srcRes = await pipe("sources", q);
          var sources = srcRes.streams || srcRes.sources || (srcRes.data && srcRes.data.sources) || (Array.isArray(srcRes) ? srcRes : []);
          var subs = srcRes.subtitles || (srcRes.data && srcRes.data.subtitles) || [];
          for (var s = 0; s < sources.length; s++) {
            var src = sources[s];
            var file = src.url || src.file || src.src;
            if (!file) continue;
            var ref = src.referer || BASE + "/";
            var audioTag = (src.audio && String(src.audio).toLowerCase() === "dub") ? " DUB" : " SUB";
            var qualityPart = (src.quality || src.type || "").toUpperCase();
            var label = qualityPart ? (qualityPart + audioTag) : (providers[p] + " " + streamCategories[c]).toUpperCase();
            var type = (src.type || "").toLowerCase();
            streams.push({
              title: label,
              streamUrl: file,
              headers: { "Referer": ref, "Origin": originFromReferer(ref), "User-Agent": HEADERS["User-Agent"] },
              _type: type,
              _audio: streamCategories[c]
            });
          }
          collectSubtitles(subs);
        } catch (e) {}
      }
    }
    /**
     * Dubbed streams: merge subtitle tracks from the sub payload too.
     * Miruro often exposes Signs & Songs / Full Subtitles only on category=sub.
     */
    if (preferredCategory === "dub") {
      for (var p2 = 0; p2 < providers.length; p2++) {
        try {
          var qSub = { episodeId: episodeId, provider: providers[p2], category: "sub" };
          if (anilistId != null) qSub.anilistId = parseInt(anilistId, 10);
          var subOnlyRes = await pipe("sources", qSub);
          var subOnlySubs = subOnlyRes.subtitles || (subOnlyRes.data && subOnlyRes.data.subtitles) || [];
          collectSubtitles(subOnlySubs);
        } catch (e2) {}
      }
    }
    streams.sort(function (a, b) {
      var typeA = (a._type === "hls") ? 0 : 1;
      var typeB = (b._type === "hls") ? 0 : 1;
      if (typeA !== typeB) return typeA - typeB;
      var subFirst = (a._audio === "sub" ? 0 : 1) - (b._audio === "sub" ? 0 : 1);
      if (subFirst !== 0) return subFirst;
      return 0;
    });
    for (var i = 0; i < streams.length; i++) {
      delete streams[i]._type;
      delete streams[i]._audio;
    }
    if (!streams.length && raw.indexOf("http") >= 0) {
      streams.push({ title: "STREAM", streamUrl: raw, headers: streamHeaders });
    }
    return JSON.stringify({ streams: streams, subtitles: subtitleTracks });
  } catch (err) {
    console.error("Miruro extractStreamUrl error:", err);
    return JSON.stringify({ streams: [], subtitles: [] });
  }
}
