#!/usr/bin/env node
/**
 * Test HiAnime (Consumet) end-to-end: search → info → watch → check stream.
 *
 * From NoirServices/HiAnime/:
 *   node test-watch.mjs
 *   node test-watch.mjs https://mac2.tail58f58f.ts.net/consumet frieren
 *
 * From repo root:
 *   node NoirServices/HiAnime/test-watch.mjs
 *
 * Node 18+ for fetch.
 */

const BASE = process.argv[2] || "https://mac2.tail58f58f.ts.net/consumet";
const QUERY = process.argv[3] || "naruto";

const HEADERS = {
  "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:146.0) Gecko/20100101 Firefox/146.0",
  Accept: "application/json",
};

async function get(url) {
  const res = await fetch(url, { headers: HEADERS });
  const text = await res.text();
  if (res.status !== 200) throw new Error(`HTTP ${res.status}: ${text.slice(0, 200)}`);
  if (!text.trim().startsWith("{")) throw new Error("Not JSON");
  return JSON.parse(text);
}

function buildWatchUrl(episodeId, category) {
  const base = `${BASE}/anime/hianime/watch/`;
  const cat = category || "sub";
  if (episodeId.includes("?")) {
    const qm = episodeId.indexOf("?");
    return `${base}${encodeURIComponent(episodeId.slice(0, qm))}${episodeId.slice(qm)}&category=${cat}`;
  }
  return `${base}${encodeURIComponent(episodeId)}?category=${cat}`;
}

async function main() {
  console.log("Base URL:", BASE);
  console.log("Query:   ", QUERY);
  console.log("");

  console.log("1. Search...");
  const searchUrl = `${BASE}/anime/hianime/${encodeURIComponent(QUERY)}?page=1`;
  const search = await get(searchUrl);
  if (search.message) throw new Error(search.message);
  const results = search.results || [];
  if (results.length === 0) {
    console.log("   No results.");
    process.exit(1);
  }
  const first = results[0];
  console.log("   First result:", first.title, "| id:", first.id);

  console.log("\n2. Info...");
  const infoUrl = `${BASE}/anime/hianime/info?id=${encodeURIComponent(first.id)}`;
  const info = await get(infoUrl);
  if (info.message) throw new Error(info.message);
  const episodes = info.episodes || [];
  if (episodes.length === 0) {
    console.log("   No episodes.");
    process.exit(1);
  }
  const ep = episodes[0];
  console.log("   First episode:", ep.number, ep.title || "", "| id:", ep.id);

  console.log("\n3. Watch (sub)...");
  const watchUrl = buildWatchUrl(ep.id, "sub");
  const watch = await get(watchUrl);
  if (watch.message) {
    console.log("   Error:", watch.message);
    process.exit(1);
  }
  const sources = watch.sources || [];
  const headers = watch.headers || {};
  if (sources.length === 0) {
    console.log("   No sources.");
    process.exit(1);
  }
  const stream = sources[0];
  const m3u8Url = stream.url;
  console.log("   Stream URL:", m3u8Url.slice(0, 80) + "...");
  console.log("   Referer:   ", headers.Referer || "(none)");

  console.log("\n4. Check stream reachable...");
  const streamRes = await fetch(m3u8Url, {
    method: "GET",
    headers: {
      ...HEADERS,
      Referer: headers.Referer || BASE + "/",
    },
    redirect: "follow",
  });
  const status = streamRes.status;
  const contentType = streamRes.headers.get("content-type") || "";
  const body = await streamRes.text();
  const isM3u8 = contentType.includes("mpegurl") || contentType.includes("m3u8") || body.trim().startsWith("#EXTM3U");

  if (status === 200 && (isM3u8 || body.length > 100)) {
    console.log("   OK – HTTP 200, content looks like m3u8 (" + body.length + " bytes).");
  } else {
    console.log("   HTTP", status, "| Content-Type:", contentType);
    console.log("   Body preview:", body.slice(0, 200));
  }

  console.log("\nDone.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
