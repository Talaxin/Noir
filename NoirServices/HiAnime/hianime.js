/**
 * HiAnime service for Noir via Consumet API
 * Routes: /anime/hianime/{query}, /anime/hianime/info?id=, /anime/hianime/watch/{episodeId}
 * See: https://docs.consumet.org/rest-api/Anime/hianime
 * Base URL: your Consumet instance. Examples:
 *   Same machine:     http://localhost:3000
 *   Tailscale network: http://100.108.109.53:3000
 *   Public (Funnel):   https://mac2.tail58f58f.ts.net/consumet
 */
const CONSUMET_BASE = "https://mac2.tail58f58f.ts.net/consumet";

const HEADERS = {
  "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:146.0) Gecko/20100101 Firefox/146.0",
  "Accept": "application/json"
};

function safeText(res) {
  if (!res || typeof res.text !== "function") return Promise.resolve("");
  return res.text().then(function (t) { return t != null ? String(t) : ""; }).catch(function () { return ""; });
}

function parseIdFromHref(url) {
  if (!url || typeof url !== "string") return "";
  var idx = url.indexOf("/anime/");
  if (idx < 0) return url;
  return url.slice(idx + 7).split("?")[0].split("/")[0];
}

function buildWatchUrl(episodeId, category) {
  var base = CONSUMET_BASE + "/anime/hianime/watch/";
  var cat = category || "sub";
  if (episodeId.indexOf("?") >= 0) {
    var qm = episodeId.indexOf("?");
    return base + encodeURIComponent(episodeId.slice(0, qm)) + episodeId.slice(qm) + "&category=" + cat;
  }
  return base + encodeURIComponent(episodeId) + "?category=" + cat;
}

function streamHeadersFromWatch(json) {
  var apiHeaders = json.headers || {};
  var ref = apiHeaders.Referer || CONSUMET_BASE + "/";
  var origin = ref;
  var m = typeof ref === "string" ? ref.match(/^(https?:\/\/[^/]+)/i) : null;
  if (m && m[1]) origin = m[1];
  return {
    "Referer": ref,
    "Origin": apiHeaders.Origin || origin,
    "User-Agent": apiHeaders["User-Agent"] || HEADERS["User-Agent"]
  };
}

function sourcesToStreams(json, labelPrefix) {
  var streamHeaders = streamHeadersFromWatch(json);
  var sources = json.sources || [];
  return sources.map(function (s) {
    var quality = (s.quality || "default").toUpperCase();
    var prefix = labelPrefix ? labelPrefix + " " : "";
    return {
      title: prefix + quality,
      streamUrl: s.url || "",
      headers: streamHeaders
    };
  }).filter(function (s) { return s.streamUrl; });
}

async function fetchWatchStreams(episodeId, category) {
  var watchUrl = buildWatchUrl(episodeId, category);
  var response = await fetchv2(watchUrl, HEADERS);
  var text = await safeText(response);
  if (!response || response.status !== 200 || !text || text.trim().charAt(0) !== "{") {
    return [];
  }
  var json = JSON.parse(text);
  if (json.message) return [];
  var label = category === "dub" ? "DUB" : "SUB";
  return sourcesToStreams(json, label);
}

async function searchResults(keyword) {
  try {
    var q = (keyword || "").trim();
    if (!q) return JSON.stringify([{ title: "No results found", image: "", href: "" }]);
    var url = CONSUMET_BASE + "/anime/hianime/" + encodeURIComponent(q) + "?page=1";
    var response = await fetchv2(url, HEADERS);
    var text = await safeText(response);
    if (!response || response.status !== 200 || !text || text.trim().charAt(0) !== "{") {
      throw new Error("Search failed or invalid response");
    }
    var json = JSON.parse(text);
    if (json.message) throw new Error(json.message);
    var results = json.results || [];
    var out = results.map(function (item) {
      return {
        title: item.title || "Unknown",
        image: item.image || "",
        href: CONSUMET_BASE + "/anime/" + (item.id || "")
      };
    });
    return JSON.stringify(out.length ? out : [{ title: "No results found", image: "", href: "" }]);
  } catch (err) {
    console.error("HiAnime search error:", err);
    return JSON.stringify([{ title: "Search failed", image: "", href: "" }]);
  }
}

async function extractDetails(url) {
  try {
    var id = parseIdFromHref(url);
    if (!id) throw new Error("Invalid URL");
    var apiUrl = CONSUMET_BASE + "/anime/hianime/info?id=" + encodeURIComponent(id);
    var response = await fetchv2(apiUrl, HEADERS);
    var text = await safeText(response);
    if (!response || response.status !== 200 || !text || text.trim().charAt(0) !== "{") {
      throw new Error("Info failed or invalid response");
    }
    var json = JSON.parse(text);
    if (json.message) throw new Error(json.message);
    return JSON.stringify([{
      description: json.description || "N/A",
      aliases: json.otherName || (json.genres || []).join(", ") || "N/A",
      airdate: json.releaseDate || json.status || "N/A"
    }]);
  } catch (err) {
    console.error("HiAnime extractDetails error:", err);
    return JSON.stringify([{ description: "Error loading details", aliases: "", airdate: "" }]);
  }
}

async function extractEpisodes(url) {
  try {
    var id = parseIdFromHref(url);
    if (!id) return JSON.stringify([{ number: 1, href: "" }]);
    var apiUrl = CONSUMET_BASE + "/anime/hianime/info?id=" + encodeURIComponent(id);
    var response = await fetchv2(apiUrl, HEADERS);
    var text = await safeText(response);
    if (!response || response.status !== 200 || !text || text.trim().charAt(0) !== "{") {
      throw new Error("Info failed");
    }
    var json = JSON.parse(text);
    if (json.message) throw new Error(json.message);
    var episodes = json.episodes || [];
    var out = episodes.map(function (ep) {
      var num = parseInt(ep.number, 10) || 0;
      var href = ep.id != null ? String(ep.id) : "";
      return { number: num, href: href };
    });
    return JSON.stringify(out.length ? out : [{ number: 1, href: "" }]);
  } catch (err) {
    console.error("HiAnime extractEpisodes error:", err);
    return JSON.stringify([{ number: 1, href: "" }]);
  }
}

async function extractStreamUrl(episodeIdOrUrl) {
  try {
    var episodeId = episodeIdOrUrl;
    if (typeof episodeIdOrUrl !== "string") episodeId = "";
    else if (episodeIdOrUrl.indexOf("/anime/") >= 0) {
      var match = episodeIdOrUrl.match(/\/watch\/([^/?]+)/);
      if (match) episodeId = match[1];
      else episodeId = parseIdFromHref(episodeIdOrUrl);
    }
    if (!episodeId) return JSON.stringify({ streams: [], subtitles: "" });

    var subStreams = await fetchWatchStreams(episodeId, "sub");
    var dubStreams = await fetchWatchStreams(episodeId, "dub");
    var streams = subStreams.concat(dubStreams);
    if (!streams.length) {
      streams = await fetchWatchStreams(episodeId, "");
    }

    return JSON.stringify({ streams: streams, subtitles: "" });
  } catch (err) {
    console.error("HiAnime extractStreamUrl error:", err);
    return JSON.stringify({ streams: [], subtitles: "" });
  }
}
