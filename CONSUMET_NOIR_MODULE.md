# Consumet + Noir module reference (for assistants / training)

Single source of truth in this repo for **this project’s** Consumet deployment and how Noir uses it.

## This repo’s Consumet base URL

**Base (API root, no trailing slash):**

`https://mac2.tail58f58f.ts.net/consumet`

**AnimeKai search path prefix:**

`https://mac2.tail58f58f.ts.net/consumet/anime/animekai`

Example search URL shape (Consumet animekai provider):

`https://mac2.tail58f58f.ts.net/consumet/anime/animekai/<query>?page=1`

If Consumet moves (e.g. `http://127.0.0.1:3000`), update **both**:

- `NoirServices/AnimeKai/animekai.json` → `baseUrl`, `searchBaseUrl`
- `NoirServices/AnimeKai/animekai.js` → top-level `CONSUMET_BASE`

## Noir module files (AnimeKai / Consumet)

| Role | Path in repo | Raw GitHub URL |
|------|----------------|----------------|
| Manifest | `NoirServices/AnimeKai/animekai.json` | `https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/AnimeKai/animekai.json` |
| Script | `NoirServices/AnimeKai/animekai.js` | `https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/AnimeKai/animekai.js` |

**App eSign catalog (IPA + app version):**

`https://raw.githubusercontent.com/Talaxin/Noir/main/repo.json`

**IPA download URL (as in repo.json):**

`https://github.com/Talaxin/Noir/raw/main/build/Noir.ipa`

**Upstream Git remote for releases:**

`https://github.com/Talaxin/Noir.git`

## Minimal `animekai.json` shape (reference)

```json
{
  "sourceName": "AnimeKai (Consumet)",
  "iconUrl": "https://docs.consumet.org/favicon.ico",
  "author": { "name": "Consumet", "icon": "https://docs.consumet.org/favicon.ico" },
  "version": "semver patch bumps on release",
  "language": "English",
  "streamType": "HLS",
  "quality": "Various",
  "baseUrl": "https://mac2.tail58f58f.ts.net/consumet",
  "searchBaseUrl": "https://mac2.tail58f58f.ts.net/consumet/anime/animekai",
  "scriptUrl": "https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/AnimeKai/animekai.js",
  "type": "anime",
  "asyncJS": true,
  "softsub": true,
  "downloadSupport": true
}
```

## Consumet documentation

`https://docs.consumet.org`

## Playback notes (Noir app, not Consumet server)

- In-app HLS often goes through a **local `StreamProxyServer`** so segment requests carry `Referer` / `Origin` / `User-Agent`.
- Some CDNs serve **MPEG-TS with `Content-Type: image/gif`** and `.gif` URLs; Noir’s proxy may **sniff bytes** and set `video/MP2T` so `AVPlayer` decodes video.
- **Do not** stop the stream proxy on a short timer during in-app playback; stop when the player dismisses (see `NormalPlayer` / `ServicesResultsSheet`).

## Release runbook (agents)

See `AGENT_MODULE_RELEASE.md` in this repo: bump `MARKETING_VERSION` in `Noir.xcodeproj/project.pbxproj` before building IPA so **IPA `CFBundleShortVersionString` matches `repo.json`**, then run `release_esign.py --bump`.

---

*Last aligned with repo paths and Tailscale hostname as used in `NoirServices/AnimeKai/` — update this file if the Consumet host changes.*
