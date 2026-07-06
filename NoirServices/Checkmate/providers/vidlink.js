/**
 * Noir patch for VidLink — handles current vidlink.pro API (qualities MP4 map).
 * Upstream still expects stream.playlist which is often missing.
 */
const VIDLINK_HEADERS = {
  "Referer": "https://vidlink.pro/",
  "Origin": "https://vidlink.pro",
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"
};

function qualitiesToStreams(qualities) {
  if (!qualities || typeof qualities !== "object") return [];
  var keys = Object.keys(qualities).sort(function (a, b) {
    return (parseInt(b, 10) || 0) - (parseInt(a, 10) || 0);
  });
  var out = [];
  keys.forEach(function (key) {
    var entry = qualities[key];
    if (!entry || !entry.url || entry.url.indexOf("http") !== 0) return;
    var label = key;
    if (/^\d+$/.test(key)) label = key + "p";
    out.push({
      title: label.toUpperCase(),
      streamUrl: entry.url,
      headers: VIDLINK_HEADERS
    });
  });
  return out;
}

async function extractStreamUrl(ID) {
  try {
    var tmdbID = "";
    var seasonNumber = "1";
    var episodeNumber = "1";
    var isMovie = ID.indexOf("movie") >= 0;

    if (isMovie) {
      var mm = ID.match(/movie\/([^/?#]+)/);
      if (!mm) throw new Error("Invalid movie id");
      tmdbID = mm[1];
    } else if (ID.indexOf("tv") >= 0) {
      var tm = ID.match(/tv\/([^/?#]+)\/([^/?#]+)\/([^/?#]+)/);
      if (!tm) throw new Error("Invalid tv id");
      tmdbID = tm[1];
      seasonNumber = tm[2];
      episodeNumber = tm[3];
    } else {
      return JSON.stringify({ streams: [], subtitles: "" });
    }

    var encRes = await fetchv2("https://enc-dec.app/api/enc-vidlink?text=" + encodeURIComponent(tmdbID));
    var encData = await encRes.json();
    if (!encData || !encData.result) throw new Error("enc-vidlink failed");

    var apiUrl = isMovie
      ? "https://vidlink.pro/api/b/movie/" + encodeURIComponent(encData.result) + "?multiLang=0"
      : "https://vidlink.pro/api/b/tv/" + encodeURIComponent(encData.result) + "/" + encodeURIComponent(seasonNumber) + "/" + encodeURIComponent(episodeNumber) + "?multiLang=0";

    var apiRes = await fetchv2(apiUrl, VIDLINK_HEADERS);
    var dataTwo = await apiRes.json();
    var stream = dataTwo.stream || {};
    var streams = [];

    if (stream.playlist && stream.playlist.indexOf("http") === 0) {
      streams.push({ title: "HLS", streamUrl: stream.playlist, headers: VIDLINK_HEADERS });
    }
    streams = streams.concat(qualitiesToStreams(stream.qualities));

    var englishSubtitle = null;
    var caps = stream.captions || [];
    for (var i = 0; i < caps.length; i++) {
      var c = caps[i];
      if (c && c.url && c.language && String(c.language).toLowerCase().indexOf("english") >= 0) {
        englishSubtitle = c.url;
        break;
      }
    }

    return JSON.stringify({ streams: streams, subtitles: englishSubtitle || "" });
  } catch (err) {
    console.error("VidLink (Noir) error:", err);
    return JSON.stringify({ streams: [], subtitles: "" });
  }
}
