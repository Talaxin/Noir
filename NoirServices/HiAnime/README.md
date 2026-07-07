# HiAnime (Consumet API)

Anime source for Noir using the [Consumet](https://docs.consumet.org) **hianime** provider.

## API (Consumet hianime)

- **Search**: `GET /anime/hianime/{query}?page=1` → `{ results: [{ id, title, url, image, releaseDate, subOrDub }] }`
- **Info**: `GET /anime/hianime/info?id={id}` → anime details and `episodes: [{ id, number, title, url }]`
- **Watch**: `GET /anime/hianime/watch/{episodeId}?category=sub|dub&server=` → `{ headers, sources: [{ url, quality, isM3U8 }] }`

Docs: [HiAnime search](https://docs.consumet.org/rest-api/Anime/hianime/search), [info](https://docs.consumet.org/rest-api/Anime/hianime/get-anime-info), [watch](https://docs.consumet.org/rest-api/Anime/hianime/get-episode-streaming-links).

## Base URL (your instance)

Default is set to a Tailscale Funnel base so it works from any device without a Tailscale client. To use a different instance, change `CONSUMET_BASE` in `hianime.js` and `baseUrl` / `searchBaseUrl` in `hianime.json`:

| Use case | Base URL |
|----------|----------|
| Same machine | `http://localhost:3000` |
| Other device on network | `http://<this-machine-IP>:3000` |
| Tailscale | `http://100.108.109.53:3000` |
| Public (Tailscale Funnel) | `https://mac2.tail58f58f.ts.net/consumet` |

## Add to Noir

1. In the app: **Modules** → **+** → paste the raw manifest URL:
   `https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/HiAnime/hianime.json`
2. Or copy `hianime.js` / `hianime.json` locally and point `scriptUrl` at your hosted JS.

## Behaviour

- **searchResults(keyword)** → `[{ title, image, href }]` with `href = base + "/anime/" + id`.
- **extractDetails(url)** → parses `id` from `href`, calls info API, returns `[{ description, aliases, airdate }]`.
- **extractEpisodes(url)** → same info API, returns `[{ number, href }]` with `href = episode.id` for watch.
- **extractStreamUrl(episodeId)** → fetches SUB and DUB watch endpoints, returns `{ streams: [{ title, streamUrl, headers }], subtitles: "" }`.

## Test

From `NoirServices/HiAnime/`:

```bash
node test-watch.mjs
node test-watch.mjs https://mac2.tail58f58f.ts.net/consumet frieren
```
