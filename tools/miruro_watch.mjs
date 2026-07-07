#!/usr/bin/env node
import fs from "node:fs/promises";
import vm from "node:vm";
import zlib from "node:zlib";

const SEARCH_TERM = process.env.NOIR_SEARCH_TERM || "Sousou no Frieren";
const TARGET_TITLE = process.env.NOIR_TARGET_TITLE || "Sousou no Frieren";
const TARGET_EPISODE = Number(process.env.NOIR_TARGET_EPISODE || "1");
const TARGET_CATEGORY = process.env.NOIR_TARGET_CATEGORY || "sub";
const WATCH_SECONDS = Number(process.env.NOIR_WATCH_SECONDS || "120");
const SEGMENTS_PER_CYCLE = Number(process.env.NOIR_SEGMENTS_PER_CYCLE || "24");
const MODULE_PATH = process.env.NOIR_MIRURO_MODULE || "/Users/talaxin/Documents/cursor_projs/Noir-main-build/NoirServices/Miruro/miruro.js";
const NON_MEDIA_EXTS = new Set(["webp","png","jpg","jpeg","svg","css","js","json","xml","html","txt","woff","woff2","ttf","otf","eot","ico"]);

function normalize(s) {
  return String(s || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function decodePipeResponse(raw) {
  const input = String(raw || "").trim();
  if (!input || input.startsWith("{") || input.startsWith("[")) return input;
  const candidates = [input, input.replace(/-/g, "+").replace(/_/g, "/")];
  for (const c of candidates) {
    try {
      const padded = c + "===".slice((c.length + 3) % 4);
      const buf = Buffer.from(padded, "base64");
      const txt = buf.toString("utf8");
      if (txt.startsWith("{") || txt.startsWith("[")) return txt;
      try {
        const gunzipped = zlib.gunzipSync(buf).toString("utf8");
        if (gunzipped.startsWith("{") || gunzipped.startsWith("[")) return gunzipped;
      } catch {}
    } catch {}
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
      return { status: res.status, text: () => res.text() };
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(script, sandbox, { filename: filePath });
  return sandbox;
}

function parseUris(baseUrl, text) {
  const lines = String(text || "").split(/\r?\n/);
  const out = [];
  let expectsURI = false;
  let skippedNonMedia = 0;
  for (const lineRaw of lines) {
    const s = lineRaw.trim();
    if (!s) continue;
    if (s.startsWith("#")) {
      if (s.startsWith("#EXT-X-STREAM-INF") || s.startsWith("#EXTINF:") || s.startsWith("#EXT-X-BYTERANGE")) expectsURI = true;
      continue;
    }
    if (!(expectsURI || s.includes(".m3u8") || s.includes(".ts") || s.includes(".m4s") || s.includes(".gif"))) {
      expectsURI = false;
      continue;
    }
    const u = new URL(s, baseUrl).toString();
    const ext = (u.split('?')[0].split('.').pop() || '').toLowerCase();
    if (expectsURI && NON_MEDIA_EXTS.has(ext)) {
      skippedNonMedia += 1;
      expectsURI = false;
      continue;
    }
    out.push(u);
    expectsURI = false;
  }
  return { uris: out, skippedNonMedia };
}

async function fetchText(url, headers) {
  const res = await fetch(url, { headers });
  return { status: res.status, text: await res.text() };
}

async function fetchRange(url, headers) {
  const h = { ...headers, Range: "bytes=0-32767" };
  const res = await fetch(url, { headers: h });
  const buf = await res.arrayBuffer();
  return { status: res.status, bytes: buf.byteLength };
}

async function resolveStream(api) {
  const search = JSON.parse(await api.searchResults(SEARCH_TERM));
  const selected = search.find((x) => normalize(x.title) === normalize(TARGET_TITLE)) || search.find((x) => normalize(x.title).includes(normalize(TARGET_TITLE)));
  if (!selected) throw new Error("Target title not found");
  const episodes = JSON.parse(await api.extractEpisodes(selected.href));
  const ep = episodes.find((e) => Number(e.number) === TARGET_EPISODE);
  if (!ep) throw new Error("Episode not found");
  const payload = JSON.parse(await api.extractStreamUrl(ep.href, TARGET_CATEGORY));
  const streams = payload.streams || [];
  if (!streams.length) throw new Error("No streams returned");
  const chosen = streams.find((s) => String(s.title || "").toLowerCase().includes("hls")) || streams[0];
  return { selectedTitle: selected.title, chosenTitle: chosen.title || "STREAM", streamUrl: chosen.streamUrl, headers: chosen.headers || {} };
}

async function main() {
  const api = await loadModule(MODULE_PATH);
  const stream = await resolveStream(api);
  console.log(`Using ${stream.selectedTitle} / ${stream.chosenTitle}`);
  console.log(`Master: ${stream.streamUrl}`);

  const deadline = Date.now() + WATCH_SECONDS * 1000;
  let cycles = 0;
  let segOk = 0;
  let segFail = 0;

  while (Date.now() < deadline) {
    cycles += 1;
    const master = await fetchText(stream.streamUrl, stream.headers);
    if (master.status !== 200 || !master.text.includes("#EXTM3U")) {
      throw new Error(`master failed cycle=${cycles} status=${master.status}`);
    }
    const levelParse = parseUris(stream.streamUrl, master.text);
    const levels = levelParse.uris;
    if (!levels.length) throw new Error(`no level uri cycle=${cycles}`);

    const level = await fetchText(levels[0], stream.headers);
    if (level.status !== 200 || !level.text.includes("#EXTM3U")) {
      throw new Error(`level failed cycle=${cycles} status=${level.status}`);
    }
    const segParse = parseUris(levels[0], level.text);
    const segs = segParse.uris.filter((u) => !u.toLowerCase().includes('.m3u8'));
    if (!segs.length) throw new Error(`no segments cycle=${cycles}`);

    for (const seg of segs.slice(0, SEGMENTS_PER_CYCLE)) {
      const r = await fetchRange(seg, stream.headers);
      if ((r.status === 200 || r.status === 206) && r.bytes >= 1024) {
        segOk += 1;
      } else {
        segFail += 1;
        throw new Error(`segment failed cycle=${cycles} status=${r.status} bytes=${r.bytes} url=${seg}`);
      }
    }

    if (cycles % 2 === 0) {
      console.log(`cycle=${cycles} segOk=${segOk} segFail=${segFail} skippedNonMedia=${segParse.skippedNonMedia}`);
    }
    await new Promise((r) => setTimeout(r, 1200));
  }

  console.log('WATCH PASS');
  console.log(JSON.stringify({ cycles, segOk, segFail }, null, 2));
}

main().catch((e) => {
  console.error('WATCH FAIL:', e.message || String(e));
  process.exit(1);
});
