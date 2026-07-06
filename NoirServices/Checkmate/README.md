# Checkmate (Tsumi) for Noir

TMDB-backed **movies + TV** aggregator ported from [50n50/sources checkmate](https://git.luna-app.eu/50n50/sources/tree/main/checkmate). Search/metadata come from TMDB; playback fans out to five providers loaded at runtime:

| Provider | Label in player |
|----------|-----------------|
| VidEasy | Alpha |
| VidLink | Beta |
| VidFast | Gamma |
| Hexa | Delta |
| VidCore | Epsilon |

Streams are merged, de-duplicated, and sorted by quality then provider priority. English subtitles are fetched from **sub.wyzie.ru** when available.

## Add to Noir

**Modules → +** → paste:

`https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/Checkmate/checkmate.json`

For local testing, point `scriptUrl` at a hosted copy of `checkmate.js` or sideload the script into the app cache.

## Search commands

| Query prefix | TMDB list |
|--------------|-----------|
| `!!` / `!trending` | Trending |
| `??` / `!top-rated-movie` | Top rated movies |
| `::` / `!top-rated-tv` | Top rated TV |
| `;;` / `!popular-movie` | Popular movies |
| `++` / `!popular-tv` | Popular TV |

## Noir-specific changes

- **`noir-checkmate:///` hrefs** — valid URLs for Noir’s episode/detail fetchers
- **`noirRegisterModule` / `noirModuleExtract`** — isolated sub-module eval (no `new Function()`)
- **`soraFetch`** — provided by the app JS runtime
- **45s episode timeout** — TV shows with many seasons need more time
- **String-array stream normalization** — VidLink/VidFast alternate title/URL arrays

## External dependencies

- `post-eosin.vercel.app` — TMDB proxy
- `git.luna-app.eu/50n50/sources` — sub-module scripts
- `enc-dec.app` — decrypt helpers for several providers
- `api.videasy.to`, `vidlink.pro`, `vidfast.pro`, `hexa.su`, `vidcore.net` — stream APIs
- `sub.wyzie.ru` — subtitle search

## Test (Node)

```bash
node NoirServices/Checkmate/test-search.mjs
```

Stream tests require the full Noir JS bridge (`noirRegisterModule`); test in-app after adding the module.
