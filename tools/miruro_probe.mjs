#!/usr/bin/env node
import fs from "node:fs/promises";
import vm from "node:vm";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import zlib from "node:zlib";

const execFileAsync = promisify(execFile);

const SEARCH_TERM = process.env.NOIR_SEARCH_TERM || "Sousou no Frieren";
const TARGET_TITLE = process.env.NOIR_TARGET_TITLE || "Sousou no Frieren";
const TARGET_EPISODE = Number(process.env.NOIR_TARGET_EPISODE || "1");
const TARGET_CATEGORY = process.env.NOIR_TARGET_CATEGORY || "sub";
const ATTEMPTS = Number(process.env.NOIR_ATTEMPTS || "3");
const MODULE_PATH =
  process.env.NOIR_MIRURO_MODULE ||
  "/Users/talaxin/Documents/cursor_projs/Noir-main-build/NoirServices/Miruro/miruro.js";

function normalize(s) {
  return String(s || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function decodePipeResponse(raw) {
  const input = String(raw || "").trim();
  if (!input) return input;
  if (input.startsWith("{") || input.startsWith("[")) return input;

  const candidates = [
    input,
    input.replace(/-/g, "+").replace(/_/g, "/"),
    decodeURIComponent(input)
      .replace(/-/g, "+")
      .replace(/_/g, "/"),
  ];

  for (const c of candidates) {
    try {
      const padded = c + "===".slice((c.length + 3) % 4);
      const decodedBuf = Buffer.from(padded, "base64");
      const decoded = decodedBuf.toString("utf8");
      if (decoded.startsWith("{") || decoded.startsWith("[")) return decoded;
      try {
        const gunzipped = zlib.gunzipSync(decodedBuf).toString("utf8");
        if (gunzipped.startsWith("{") || gunzipped.startsWith("[")) return gunzipped;
      } catch {
        // not gzip payload
      }
    } catch {
      // ignore and try next strategy
    }
  }
  return input;
}

async function loadModule(filePath) {
  const script = await fs.readFile(filePath, "utf8");
  const sandbox = {
    console,
    setTimeout,
    clearTimeout,
    btoa: (v) => Buffer.from(String(v), "utf8").toString("base64"),
    atob: (v) => Buffer.from(String(v), "base64").toString("utf8"),
    decodePipeResponse,
    fetchv2: async (url, headers = {}) => {
      const res = await fetch(url, { method: "GET", headers });
      return {
        status: res.status,
        text: () => res.text(),
      };
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(script, sandbox, { filename: filePath });
  const required = [
    "searchResults",
    "extractEpisodes",
    "extractStreamUrl",
  ];
  for (const fn of required) {
    if (typeof sandbox[fn] !== "function") {
      throw new Error(`Module missing function: ${fn}`);
    }
  }
  return sandbox;
}

function parseM3U8Uris(baseUrl, body) {
  const lines = body.split(/\r?\n/);
  const uris = [];
  let expectsURI = false;
  for (const lineRaw of lines) {
    const line = lineRaw.trim();
    if (!line) continue;
    if (line.startsWith("#")) {
      if (line.startsWith("#EXT-X-STREAM-INF") || line.startsWith("#EXTINF:") || line.startsWith("#EXT-X-BYTERANGE")) {
        expectsURI = true;
      }
      continue;
    }
    if (expectsURI || line.includes(".m3u8") || line.includes(".ts") || line.includes(".m4s")) {
      uris.push(new URL(line, baseUrl).toString());
    }
    expectsURI = false;
  }
  return uris;
}

async function fetchText(url, headers) {
  const res = await fetch(url, { headers });
  const text = await res.text();
  return { status: res.status, text };
}

async function fetchHeadOrRange(url, headers) {
  const rangeHeaders = { ...headers, Range: "bytes=0-32767" };
  const res = await fetch(url, { headers: rangeHeaders });
  const chunk = await res.arrayBuffer();
  return { status: res.status, bytes: chunk.byteLength };
}

function formatHeadersForFFprobe(headers) {
  return Object.entries(headers)
    .map(([k, v]) => `${k}: ${v}\r\n`)
    .join("");
}

async function probeWithFFprobe(url, headers) {
  const ffHeaders = formatHeadersForFFprobe(headers);
  const args = [
    "-v",
    "error",
    "-headers",
    ffHeaders,
    "-show_entries",
    "format=duration",
    "-of",
    "default=nw=1:nk=1",
    "-i",
    url,
  ];
  try {
    const { stdout } = await execFileAsync("ffprobe", args, { timeout: 30000 });
    const out = String(stdout || "").trim();
    const dur = Number(out.split(/\r?\n/).find((l) => l.trim() && !Number.isNaN(Number(l.trim()))) || "0");
    return { ok: dur > 0, duration: dur, raw: out };
  } catch (error) {
    return { ok: false, error: error.message || String(error) };
  }
}

async function singleAttempt(api, n) {
  console.log(`\n=== Attempt ${n} ===`);
  const searchRaw = await api.searchResults(SEARCH_TERM);
  const searchList = JSON.parse(searchRaw);
  const selected =
    searchList.find((x) => normalize(x.title) === normalize(TARGET_TITLE)) ||
    searchList.find((x) => normalize(x.title).includes(normalize(TARGET_TITLE)));
  if (!selected) throw new Error("Target title not found in search results");
  console.log(`Selected: ${selected.title} (${selected.href})`);

  const epsRaw = await api.extractEpisodes(selected.href);
  const eps = JSON.parse(epsRaw);
  const ep = eps.find((e) => Number(e.number) === TARGET_EPISODE);
  if (!ep) throw new Error(`Episode ${TARGET_EPISODE} not found`);
  console.log(`Episode token: ${ep.href}`);

  const streamRaw = await api.extractStreamUrl(ep.href, TARGET_CATEGORY);
  const payload = JSON.parse(streamRaw);
  const streams = payload.streams || [];
  const subtitles = payload.subtitles || [];
  if (!streams.length) throw new Error("No streams returned by module");
  console.log(`Streams: ${streams.length}, subtitle entries: ${subtitles.length}`);

  const chosen =
    streams.find((s) => String(s.title || "").toLowerCase().includes("hls")) ||
    streams[0];
  const streamUrl = chosen.streamUrl;
  const headers = chosen.headers || {};
  console.log(`Chosen stream: ${chosen.title || "STREAM"} => ${streamUrl}`);

  const master = await fetchText(streamUrl, headers);
  if (master.status !== 200 || !master.text.includes("#EXTM3U")) {
    throw new Error(`Master playlist fetch failed: status=${master.status}`);
  }

  const levelUris = parseM3U8Uris(streamUrl, master.text);
  if (!levelUris.length) throw new Error("No level/segment URIs found in master");
  const firstLevel = levelUris[0];
  console.log(`First level URI: ${firstLevel}`);

  const level = await fetchText(firstLevel, headers);
  if (level.status !== 200 || !level.text.includes("#EXTM3U")) {
    throw new Error(`Level playlist fetch failed: status=${level.status}`);
  }

  const segUris = parseM3U8Uris(firstLevel, level.text).filter((u) => !u.toLowerCase().includes(".m3u8"));
  if (!segUris.length) throw new Error("No media segment URI found");
  const firstSeg = segUris[0];
  const seg = await fetchHeadOrRange(firstSeg, headers);
  if (!(seg.status === 200 || seg.status === 206) || seg.bytes < 1024) {
    throw new Error(`Segment probe failed: status=${seg.status}, bytes=${seg.bytes}`);
  }
  console.log(`Segment probe: status=${seg.status}, bytes=${seg.bytes}`);

  const ff = await probeWithFFprobe(streamUrl, headers);
  if (ff.ok) {
    console.log(`ffprobe duration=${ff.duration.toFixed(2)}s`);
  } else {
    console.log(`ffprobe note: ${ff.error || ff.raw || "unknown"}`);
  }

  return {
    selectedTitle: selected.title,
    streamTitle: chosen.title || "STREAM",
    streamUrl,
    firstLevel,
    firstSegment: firstSeg,
    ffprobeDuration: ff.duration,
  };
}

async function main() {
  const api = await loadModule(MODULE_PATH);
  let lastError = null;
  for (let i = 1; i <= ATTEMPTS; i += 1) {
    try {
      const result = await singleAttempt(api, i);
      console.log("\nPASS");
      console.log(JSON.stringify(result, null, 2));
      return;
    } catch (err) {
      lastError = err;
      console.error(`Attempt ${i} failed: ${err.message || String(err)}`);
    }
  }
  throw lastError || new Error("All attempts failed");
}

main().catch((err) => {
  console.error(`FAIL: ${err.message || String(err)}`);
  process.exit(1);
});
