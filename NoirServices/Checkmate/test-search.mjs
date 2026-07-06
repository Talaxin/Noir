#!/usr/bin/env node
/**
 * Smoke-test Checkmate search + episode list (no sub-module stream fetch).
 * Run from repo root: node NoirServices/Checkmate/test-search.mjs [query]
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const QUERY = process.argv[2] || "inception";

const script = readFileSync(join(__dirname, "checkmate.js"), "utf8");

async function fetchv2(url, headers = {}, method = "GET", body = null) {
  const res = await globalThis.fetch(url, {
    method,
    headers: { "User-Agent": "Noir-Test", Accept: "application/json", ...headers },
    body: method !== "GET" && body ? body : undefined,
  });
  const text = await res.text();
  return {
    status: res.status,
    headers: Object.fromEntries(res.headers.entries()),
    text: () => Promise.resolve(text),
    json: () => Promise.resolve(JSON.parse(text)),
  };
}

async function fetch(url, headers = {}) {
  const res = await globalThis.fetch(url, { headers: { "User-Agent": "Noir-Test", ...headers } });
  return res.text();
}

async function soraFetch(url, options = {}) {
  return fetchv2(url, options.headers || {}, options.method || "GET", options.body || null);
}

function noirRegisterModule() {}
function noirModuleExtract() {}

const fn = new Function(
  "fetchv2",
  "fetch",
  "soraFetch",
  "noirRegisterModule",
  "noirModuleExtract",
  script + "\nreturn { searchResults, extractEpisodes };"
);

const api = fn(fetchv2, fetch, soraFetch, noirRegisterModule, noirModuleExtract);

const searchRaw = await api.searchResults(QUERY);
const search = JSON.parse(searchRaw);
console.log("Search results:", search.length);
if (!search.length || !search[0].href) process.exit(1);
console.log("First:", search[0].title, search[0].href);

const epsRaw = await api.extractEpisodes(search[0].href);
const eps = JSON.parse(epsRaw);
console.log("Episodes:", eps.length);
console.log("OK");
