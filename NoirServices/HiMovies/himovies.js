/**
 * HiMovies service for Noir via Consumet API
 * Search: GET /movies/himovies/{query}?page=1
 * Info:  GET /movies/himovies/info?id={mediaId}
 * Watch: GET /movies/himovies/watch?episodeId=&mediaId=
 * Docs: https://docs.consumet.org
 */
const CONSUMET_BASE = "https://mac2.tail58f58f.ts.net/consumet";

const HEADERS = {
  "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:146.0) Gecko/20100101 Firefox/146.0",
  "Accept": "application/json"
};

const ITEM_PATH = "/movies/himovies/item/";

function safeText(res) {
  if (!res || typeof res.text !== "function") return Promise.resolve("");
  return res.text().then(function (t) { return t != null ? String(t) : ""; }).catch(function () { return ""; });
}

function parseMediaIdFromHref(url) {
  if (!url || typeof url !== "string") return "";
  try {
    var path = url.split("?")[0];
    var idx = path.indexOf(ITEM_PATH);
    if (idx < 0) return "";
    return decodeURIComponent(path.slice(idx + ITEM_PATH.length).split("#")[0].split("/")[0]);
  } catch (e) {
    return "";
  }
}

function episodeHref(episodeId, mediaId) {
  return encodeURIComponent(String(episodeId || "")) + "|" + encodeURIComponent(String(mediaId || ""));
}

function parseEpisodePayload(raw) {
  if (!raw || typeof raw !== "string") return { episodeId: "", mediaId: "" };
  var i = raw.indexOf("|");
  if (i < 0) return { episodeId: raw.trim(), mediaId: raw.trim() };
  try {
    return {
      episodeId: decodeURIComponent(raw.slice(0, i)),
      mediaId: decodeURIComponent(raw.slice(i + 1))
    };
  } catch (e) {
    return { episodeId: raw.slice(0, i), mediaId: raw.slice(i + 1) };
  }
}

async function searchResults(keyword) {
  try {
    var q = (keyword || "").trim();
    if (!q) return JSON.stringify([{ title: "No results found", image: "", href: "" }]);
    var url = CONSUMET_BASE + "/movies/himovies/" + encodeURIComponent(q) + "?page=1";
    var response = await fetchv2(url, HEADERS);
    var text = await safeText(response);
    if (!response || response.status !== 200 || !text || text.trim().charAt(0) !== "{") {
      throw new Error("Search failed or invalid response");
    }
    var json = JSON.parse(text);
    var results = json.results || [];
    var out = results.map(function (item) {
      var id = item.id != null ? String(item.id) : "";
      return {
        title: item.title || "Unknown",
        image: item.image || "",
        href: id ? (CONSUMET_BASE + ITEM_PATH + encodeURIComponent(id)) : ""
      };
    });
    return JSON.stringify(out.length ? out : [{ title: "No results found", image: "", href: "" }]);
  } catch (err) {
    console.error("HiMovies search error:", err);
    return JSON.stringify([{ title: "Search failed", image: "", href: "" }]);
  }
}

function normalizeEpisodesList(json, mediaId) {
  var eps = json.episodes;
  if (!eps && json.mediaInfo && json.mediaInfo.episodes) eps = json.mediaInfo.episodes;
  if (!Array.isArray(eps)) eps = [];
  return eps;
}

async function fetchInfoJson(mediaId) {
  var apiUrl = CONSUMET_BASE + "/movies/himovies/info?id=" + encodeURIComponent(mediaId);
  var response = await fetchv2(apiUrl, HEADERS);
  var text = await safeText(response);
  if (!response || response.status !== 200 || !text || text.trim().charAt(0) !== "{") {
    throw new Error("Info failed or invalid response");
  }
  return JSON.parse(text);
}

async function extractDetails(url) {
  try {
    var mediaId = parseMediaIdFromHref(url);
    if (!mediaId) throw new Error("Invalid URL");
    var json = await fetchInfoJson(mediaId);
    var desc = json.description || json.overview || json.synopsis || "N/A";
    var aliases = json.otherName || json.originalTitle || json.alternativeTitle || "N/A";
    var airdate = json.releaseDate || json.year || json.status || "N/A";
    return JSON.stringify([{ description: desc, aliases: aliases, airdate: airdate }]);
  } catch (err) {
    console.error("HiMovies extractDetails error:", err);
    return JSON.stringify([{ description: "Error loading details", aliases: "", airdate: "" }]);
  }
}

async function extractEpisodes(url) {
  try {
    var mediaId = parseMediaIdFromHref(url);
    if (!mediaId) return JSON.stringify([{ number: 1, href: "" }]);
    var json = await fetchInfoJson(mediaId);
    var episodes = normalizeEpisodesList(json, mediaId);
    var out = [];
    for (var i = 0; i < episodes.length; i++) {
      var ep = episodes[i];
      var num = parseInt(ep.number != null ? ep.number : (ep.episode != null ? ep.episode : (i + 1)), 10) || (i + 1);
      var eid = ep.id != null ? String(ep.id) : (ep.episodeId != null ? String(ep.episodeId) : "");
      if (!eid) continue;
      out.push({ number: num, href: episodeHref(eid, mediaId) });
    }
    if (!out.length) {
      var fallbackId = json.id != null ? String(json.id) : mediaId;
      out.push({ number: 1, href: episodeHref(fallbackId, mediaId) });
    }
    return JSON.stringify(out);
  } catch (err) {
    console.error("HiMovies extractEpisodes error:", err);
    var mid = parseMediaIdFromHref(url);
    var href = mid ? episodeHref(mid, mid) : "";
    return JSON.stringify([{ number: 1, href: href }]);
  }
}

async function extractStreamUrl(episodeIdOrUrl) {
  try {
    var raw = typeof episodeIdOrUrl === "string" ? episodeIdOrUrl : "";
    var episodeId = "";
    var mediaId = "";
    if (raw.indexOf("|") >= 0) {
      var p = parseEpisodePayload(raw);
      episodeId = p.episodeId;
      mediaId = p.mediaId;
    } else {
      episodeId = raw;
      mediaId = raw;
    }
    if (!episodeId || !mediaId) return JSON.stringify({ streams: [], subtitles: [] });
    var watchUrl = CONSUMET_BASE + "/movies/himovies/watch?episodeId=" + encodeURIComponent(episodeId) + "&mediaId=" + encodeURIComponent(mediaId);
    var response = await fetchv2(watchUrl, HEADERS);
    var text = await safeText(response);
    if (!response || response.status !== 200 || !text || text.trim().charAt(0) !== "{") {
      throw new Error("Watch failed or invalid response");
    }
    var json = JSON.parse(text);
    var apiHeaders = json.headers || {};
    var ref = apiHeaders.Referer || CONSUMET_BASE + "/";
    var origin = ref;
    var m = typeof ref === "string" ? ref.match(/^(https?:\/\/[^/]+)/i) : null;
    if (m && m[1]) origin = m[1];
    var streamHeaders = {
      "Referer": ref,
      "Origin": apiHeaders.Origin || origin,
      "User-Agent": apiHeaders["User-Agent"] || HEADERS["User-Agent"]
    };
    var sources = json.sources || [];
    var streams = sources.map(function (s) {
      var quality = (s.quality || (s.isM3U8 ? "HLS" : "default")).toString();
      var label = quality.toUpperCase();
      return {
        title: label,
        streamUrl: s.url || "",
        headers: streamHeaders
      };
    }).filter(function (s) { return s.streamUrl; });
    var subtitleTracks = [];
    var subList = json.subtitles || [];
    for (var i = 0; i < subList.length; i++) {
      var sub = subList[i];
      var u = sub.url || sub.file || sub.src;
      if (!u) continue;
      var lab = (sub.lang || sub.label || "Subtitles").toString().trim() || "Subtitles";
      subtitleTracks.push(lab, u);
    }
    return JSON.stringify({ streams: streams, subtitles: subtitleTracks });
  } catch (err) {
    console.error("HiMovies extractStreamUrl error:", err);
    return JSON.stringify({ streams: [], subtitles: [] });
  }
}
