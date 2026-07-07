/**
 * Checkmate (Tsumi) aggregator for Noir — TMDB metadata + multi-provider streams.
 * Sub-modules loaded at runtime from 50n50/sources (VidEasy, VidLink, VidFast, Hexa, VidCore).
 */
const HREF_BASE = "noir-checkmate:///";
const NOIR_PROVIDER_BASE = "https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/Checkmate/providers";
const scriptCache = {};

const SOURCES = [
    { name: "VidLink", url: NOIR_PROVIDER_BASE + "/vidlink.js" },
    { name: "VidEasy", url: "https://git.luna-app.eu/50n50/sources/raw/branch/main/videasy/videasy.js" },
    { name: "VidFast", url: "https://git.luna-app.eu/50n50/sources/raw/branch/main/vidfast/vidfast.js" },
    { name: "Hexa", url: "https://git.luna-app.eu/50n50/sources/raw/branch/main/hexa/hexa.js" }
];

const SOURCE_NAMES = {
    "VidEasy": "Alpha",
    "VidLink": "Beta",
    "VidFast": "Gamma",
    "Hexa": "Delta",
    "VidCore": "Epsilon"
};

const SOURCE_PRIORITY = {
    "Alpha": 5,
    "Beta": 4,
    "Gamma": 3,
    "Delta": 2,
    "Epsilon": 1
};

const VIDFAST_HEADERS = {
    "Referer": "https://vidfast.pro/",
    "Origin": "https://vidfast.pro",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36"
};

function parseMediaPath(id) {
    var s = String(id || "");
    var movieMatch = s.match(/movie\/([^/?#]+)/);
    if (movieMatch) {
        return { type: "movie", tmdbId: movieMatch[1], season: "1", episode: "1" };
    }
    var tvMatch = s.match(/tv\/([^/?#]+)\/([^/?#]+)\/([^/?#]+)/);
    if (tvMatch) {
        return { type: "tv", tmdbId: tvMatch[1], season: tvMatch[2], episode: tvMatch[3] };
    }
    return { type: "", tmdbId: "", season: "1", episode: "1" };
}

function normalizeStreamID(id) {
    var info = parseMediaPath(id);
    if (info.type === "movie") return "/movie/" + info.tmdbId;
    if (info.type === "tv") return "/tv/" + info.tmdbId + "/" + info.season + "/" + info.episode;
    return id;
}

async function getModule(name, url) {
    if (scriptCache[name]) return scriptCache[name];
    try {
        const response = await soraFetch(url);
        if (!response) throw new Error("Failed to fetch script");
        const code = await response.text();
        await new Promise(function(resolve, reject) {
            noirRegisterModule(name, code, resolve, reject);
        });
        scriptCache[name] = {
            extractStreamUrl: function(id) {
                return new Promise(function(resolve, reject) {
                    noirModuleExtract(name, id, resolve, reject);
                });
            }
        };
        return scriptCache[name];
    } catch (e) {
        console.log("Failed to load module " + name + " from " + url + ": " + e.message);
        return null;
    }
}

async function searchResults(query) {
    try {
        let transformedResults = [];

        const keywordGroups = {
            trending: ["!trending", "!hot", "!tr", "!!"],
            topRatedMovie: ["!top-rated-movie", "!topmovie", "!tm", "??"],
            topRatedTV: ["!top-rated-tv", "!toptv", "!tt", "::"],
            popularMovie: ["!popular-movie", "!popmovie", "!pm", ";;"],
            popularTV: ["!popular-tv", "!poptv", "!pt", "++"],
        };

        const skipTitleFilter = Object.values(keywordGroups).flat();

        const shouldFilter = !matchesKeyword(query, skipTitleFilter);

        const encodedQuery = encodeURIComponent(query);
        let baseUrlTemplate = null;

        if (matchesKeyword(query, keywordGroups.trending)) {
            baseUrlTemplate = (page) => `https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/trending/all/week?api_key=9801b6b0548ad57581d111ea690c85c8&include_adult=false&page=${page}`)}&simple=true`;
        } else if (matchesKeyword(query, keywordGroups.topRatedMovie)) {
            baseUrlTemplate = (page) => `https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/movie/top_rated?api_key=9801b6b0548ad57581d111ea690c85c8&include_adult=false&page=${page}`)}&simple=true`;
        } else if (matchesKeyword(query, keywordGroups.topRatedTV)) {
            baseUrlTemplate = (page) => `https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/tv/top_rated?api_key=9801b6b0548ad57581d111ea690c85c8&include_adult=false&page=${page}`)}&simple=true`;
        } else if (matchesKeyword(query, keywordGroups.popularMovie)) {
            baseUrlTemplate = (page) => `https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/movie/popular?api_key=9801b6b0548ad57581d111ea690c85c8&include_adult=false&page=${page}`)}&simple=true`;
        } else if (matchesKeyword(query, keywordGroups.popularTV)) {
            baseUrlTemplate = (page) => `https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/tv/popular?api_key=9801b6b0548ad57581d111ea690c85c8&include_adult=false&page=${page}`)}&simple=true`;
        } else {
            baseUrlTemplate = (page) => `https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/search/multi?api_key=9801b6b0548ad57581d111ea690c85c8&query=${encodedQuery}&include_adult=false&page=${page}`)}&simple=true`;
        }

        const fuzzyMatch = (query, title) => {
            const q = query.toLowerCase().trim();
            const t = title.toLowerCase().trim();

            if (t === q) return 1000;

            if (t.startsWith(q + ' ') || t.startsWith(q + ':') || t.startsWith(q + '-')) return 950;

            const wordBoundaryRegex = new RegExp(`\\b${q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`);
            if (wordBoundaryRegex.test(t)) return 900;

            const qTokens = q.split(/\s+/).filter(token => token.length > 0);
            const tTokens = t.split(/[\s\-:]+/).filter(token => token.length > 0);

            const stopwords = new Set(['the', 'a', 'an', 'and', 'or', 'of', 'in', 'on', 'at', 'to', 'for', 'with']);

            let score = 0;
            let exactMatches = 0;
            let partialMatches = 0;
            let significantMatches = 0;

            qTokens.forEach(qToken => {
                const isStopword = stopwords.has(qToken);
                let bestMatch = 0;
                let hasExactMatch = false;

                tTokens.forEach(tToken => {
                    let matchScore = 0;

                    if (tToken === qToken) {
                        matchScore = isStopword ? 25 : 120;
                        hasExactMatch = true;
                        if (!isStopword) significantMatches++;
                    }
                    else if (qToken.includes(tToken) && tToken.length >= 3 && qToken.length <= tToken.length + 2) {
                        matchScore = isStopword ? 8 : 40;
                        if (!isStopword) significantMatches++;
                    }
                    else if (tToken.startsWith(qToken) && qToken.length >= 3) {
                        matchScore = isStopword ? 12 : 70;
                        if (!isStopword) significantMatches++;
                    }
                    else if (qToken.length >= 4 && tToken.length >= 4) {
                        const dist = levenshteinDistance(qToken, tToken);
                        const maxLen = Math.max(qToken.length, tToken.length);
                        const similarity = 1 - (dist / maxLen);

                        if (similarity > 0.8) {
                            matchScore = Math.floor(similarity * 60);
                            if (!isStopword) significantMatches++;
                        }
                    }

                    bestMatch = Math.max(bestMatch, matchScore);
                });

                if (bestMatch > 0) {
                    score += bestMatch;
                    if (hasExactMatch) exactMatches++;
                    else partialMatches++;
                }
            });

            const significantTokens = qTokens.filter(t => !stopwords.has(t)).length;

            const requiredMatches = Math.max(1, Math.ceil(significantTokens * 0.8));
            if (significantMatches < requiredMatches) {
                return 0;
            }

            if (exactMatches + partialMatches >= qTokens.length) {
                score += 80;
            }

            score += exactMatches * 20;

            const extraWords = tTokens.length - qTokens.length;
            if (extraWords > 2) {
                score -= (extraWords - 2) * 25;
            }

            let orderBonus = 0;
            for (let i = 0; i < qTokens.length - 1; i++) {
                const currentTokenIndex = tTokens.findIndex(t => t.includes(qTokens[i]));
                const nextTokenIndex = tTokens.findIndex(t => t.includes(qTokens[i + 1]));

                if (currentTokenIndex !== -1 && nextTokenIndex !== -1 && currentTokenIndex < nextTokenIndex) {
                    orderBonus += 15;
                }
            }
            score += orderBonus;

            return Math.max(0, score);
        };

        const levenshteinDistance = (a, b) => {
            const matrix = [];

            for (let i = 0; i <= b.length; i++) {
                matrix[i] = [i];
            }

            for (let j = 0; j <= a.length; j++) {
                matrix[0][j] = j;
            }

            for (let i = 1; i <= b.length; i++) {
                for (let j = 1; j <= a.length; j++) {
                    if (b.charAt(i - 1) === a.charAt(j - 1)) {
                        matrix[i][j] = matrix[i - 1][j - 1];
                    } else {
                        matrix[i][j] = Math.min(
                            matrix[i - 1][j - 1] + 1,
                            matrix[i][j - 1] + 1,
                            matrix[i - 1][j] + 1
                        );
                    }
                }
            }

            return matrix[b.length][a.length];
        };

        let dataResults = [];

        if (baseUrlTemplate) {
            const pagePromises = Array.from({ length: 10 }, (_, i) =>
                soraFetch(baseUrlTemplate(i + 1)).then(r => r ? r.json() : { results: [] })
            );
            const pages = await Promise.all(pagePromises);
            dataResults = pages.flatMap(p => p.results || []);
        }

        if (dataResults.length > 0) {
            transformedResults = transformedResults.concat(
                dataResults
                    .map(result => {
                        if (result.media_type === "movie" || result.title) {
                            return {
                                title: result.title || result.name || result.original_title || result.original_name || "Untitled",
                                image: result.poster_path ? `https://image.tmdb.org/t/p/w500${result.poster_path}` : "",
                                href: HREF_BASE + "movie/" + result.id,
                            };
                        } else if (result.media_type === "tv" || result.name) {
                            return {
                                title: result.name || result.title || result.original_name || result.original_title || "Untitled",
                                image: result.poster_path ? `https://image.tmdb.org/t/p/w500${result.poster_path}` : "",
                                href: HREF_BASE + "tv/" + result.id + "/1/1",
                            };
                        }
                    })
                    .filter(Boolean)
                    .filter(result => result.title !== "Overflow")
                    .filter(result => result.title !== "My Marriage Partner Is My Student, a Cocky Troublemaker")
            );
        }

        if (shouldFilter) {
            const scoredResults = transformedResults.map(r => ({
                ...r,
                score: fuzzyMatch(query, r.title)
            }));
            transformedResults = scoredResults
                .filter(r => r.score > 50)
                .sort((a, b) => b.score - a.score)
                .map(({ score, ...rest }) => rest);
        }

        return JSON.stringify(transformedResults);
    } catch (error) {
        console.log("Fetch error in searchResults: " + error);
        return JSON.stringify([{ title: "Error", image: "", href: "" }]);
    }
}

function matchesKeyword(keyword, commands) {
    const lower = keyword.toLowerCase();
    return commands.some(cmd => lower.startsWith(cmd.toLowerCase()));
}

async function extractDetails(url) {
    try {
        if (url.includes('movie')) {
            const match = url.match(/movie\/([^\/]+)/);
            if (!match) throw new Error("Invalid URL format");

            const movieId = match[1];
            const responseText = await soraFetch(`https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/movie/${movieId}?api_key=ad301b7cc82ffe19273e55e4d4206885`)}&simple=true`);
            const data = await responseText.json();

            const transformedResults = [{
                description: data.overview || 'No description available',
                aliases: `Duration: ${data.runtime ? data.runtime + " minutes" : 'Unknown'}`,
                airdate: `Released: ${data.release_date ? data.release_date : 'Unknown'}`
            }];

            return JSON.stringify(transformedResults);
        } else if (url.includes('tv')) {
            const match = url.match(/tv\/([^\/]+)/);
            if (!match) throw new Error("Invalid URL format");

            const showId = match[1];
            const responseText = await soraFetch(`https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/tv/${showId}?api_key=ad301b7cc82ffe19273e55e4d4206885`)}&simple=true`);
            const data = await responseText.json();

            const transformedResults = [{
                description: data.overview || 'No description available',
                aliases: `Duration: ${data.episode_run_time && data.episode_run_time.length ? data.episode_run_time.join(', ') + " minutes" : 'Unknown'}`,
                airdate: `Aired: ${data.first_air_date ? data.first_air_date : 'Unknown'}`
            }];

            return JSON.stringify(transformedResults);
        } else {
            throw new Error("Invalid URL format");
        }
    } catch (error) {
        console.log('Details error: ' + error);
        return JSON.stringify([{
            description: 'Error loading description',
            aliases: 'Duration: Unknown',
            airdate: 'Aired/Released: Unknown'
        }]);
    }
}

async function extractEpisodes(url) {
    try {
        if (url.includes('movie')) {
            const match = url.match(/movie\/([^\/]+)/);
            if (!match) throw new Error("Invalid URL format");
            const movieId = match[1];

            const movie = [
                { href: HREF_BASE + "movie/" + movieId, number: 1, title: "Full Movie" }
            ];
            return JSON.stringify(movie);
        } else if (url.includes('tv')) {
            const match = url.match(/tv\/([^\/]+)\/([^\/]+)\/([^\/]+)/);
            if (!match) throw new Error("Invalid URL format");
            const showId = match[1];

            const showResponseText = await soraFetch(`https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/tv/${showId}?api_key=ad301b7cc82ffe19273e55e4d4206885`)}&simple=true`);
            const showData = await showResponseText.json();

            let allEpisodes = [];
            for (const season of showData.seasons) {
                const seasonNumber = season.season_number;
                if (seasonNumber === 0) continue;

                const seasonResponseText = await soraFetch(`https://post-eosin.vercel.app/api/proxy?url=${encodeURIComponent(`https://api.themoviedb.org/3/tv/${showId}/season/${seasonNumber}?api_key=ad301b7cc82ffe19273e55e4d4206885`)}&simple=true`);
                const seasonData = await seasonResponseText.json();

                if (seasonData.episodes && seasonData.episodes.length) {
                    const episodes = seasonData.episodes.map(episode => ({
                        href: HREF_BASE + "tv/" + showId + "/" + seasonNumber + "/" + episode.episode_number,
                        number: episode.episode_number,
                        title: episode.name || ""
                    }));
                    allEpisodes = allEpisodes.concat(episodes);
                }
            }
            return JSON.stringify(allEpisodes);
        } else {
            throw new Error("Invalid URL format");
        }
    } catch (error) {
        console.log('Fetch error in extractEpisodes: ' + error);
        return JSON.stringify([]);
    }
}

const PROVIDER_TIMEOUT_MS = 14000;
const GLOBAL_POLL_TIMEOUT_MS = 20000;

function withTimeout(promise, ms, label) {
    return Promise.race([
        promise,
        new Promise(function(_, reject) {
            setTimeout(function() { reject(new Error(label + " timeout")); }, ms);
        })
    ]);
}

async function fetchDefaultSubtitle(media) {
    try {
        if (media.type === "movie" && media.tmdbId) {
            const subResponse = await fetchv2("https://sub.wyzie.ru/search?id=" + encodeURIComponent(media.tmdbId) + "&format=srt");
            const subtitles = await subResponse.json();
            if (Array.isArray(subtitles)) {
                var enSub = subtitles.find(function(sub) { return sub.language && sub.language.toLowerCase() === "en"; });
                return (enSub && enSub.url) ? enSub.url : "";
            }
        } else if (media.type === "tv" && media.tmdbId) {
            const subResponse = await fetchv2("https://sub.wyzie.ru/search?id=" + encodeURIComponent(media.tmdbId) + "&format=srt&season=" + encodeURIComponent(media.season) + "&episode=" + encodeURIComponent(media.episode));
            const subtitles = await subResponse.json();
            if (Array.isArray(subtitles)) {
                var enSubTv = subtitles.find(function(sub) { return sub.language && sub.language.toLowerCase() === "en"; });
                return (enSubTv && enSubTv.url) ? enSubTv.url : "";
            }
        }
    } catch (e) { /* optional */ }
    return "";
}

function streamsFromProviderResult(source, data) {
    if (!data || !Array.isArray(data.streams)) return [];
    const sourceName = source.name;
    const mappedName = SOURCE_NAMES[sourceName] || sourceName;
    const out = [];

    if (data.streams.length > 0 && typeof data.streams[0] === "string") {
        for (let i = 0; i < data.streams.length; i += 2) {
            const label = data.streams[i] || "Default";
            const url = data.streams[i + 1];
            if (!url || url.indexOf("http") !== 0) continue;
            let quality = "1080p";
            const qualityMatch = String(label).match(/(4K|2160p|1080p|720p|480p|360p)/i);
            if (qualityMatch) quality = qualityMatch[0].toLowerCase();
            const title = mappedName + " " + quality.toUpperCase() + " 🇺🇸";
            var hdrs = data.referer ? { Referer: data.referer } : (sourceName === "VidFast" ? VIDFAST_HEADERS : {});
            out.push({
                title: title,
                streamUrl: url,
                headers: hdrs,
                sourceMapped: mappedName
            });
        }
        return out;
    }

    data.streams.forEach(function(stream) {
        var origTitle = stream.title || "Default";
        var streamUrl = stream.streamUrl || stream.url || "";
        if (!streamUrl || streamUrl.indexOf("http") !== 0) return;

        var quality = "1080p";
        var qualityMatch = origTitle.match(/(4K|2160p|1080p|720p|480p|360p|\d+p)/i);
        if (qualityMatch) {
            quality = qualityMatch[0].toLowerCase();
        } else if (origTitle.toLowerCase().indexOf("hd") >= 0) {
            quality = "720p";
        }

        var flagMatch = origTitle.match(/[\uD83C][\uDDE6-\uDDFF]/g);
        var emoji = (flagMatch && flagMatch.length >= 2) ? flagMatch.join("") : (origTitle.match(/[\uD83C][\uDDE6-\uDDFF][\uD83C][\uDDE6-\uDDFF]/) ? origTitle.match(/[\uD83C][\uDDE6-\uDDFF][\uD83C][\uDDE6-\uDDFF]/)[0] : "🇺🇸");

        var serverHint = origTitle.replace(/\[.*?\]/g, "").trim();
        var title = mappedName + " " + quality.toUpperCase();
        if (serverHint && serverHint.toLowerCase() !== "default" && serverHint.toLowerCase() !== quality.toLowerCase()) {
            title += " (" + serverHint + ")";
        }
        title += " " + emoji;

        var hdrs = stream.headers || (data.referer ? { Referer: data.referer } : {});
        if (!hdrs["User-Agent"]) {
            hdrs["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36";
        }

        out.push({
            title: title,
            streamUrl: streamUrl,
            headers: hdrs,
            sourceMapped: mappedName
        });
    });
    return out;
}

function dedupeAndSortStreams(allStreams) {
    const seenUrls = new Set();
    let streams = allStreams.filter(function(stream) {
        if (!stream.streamUrl || typeof stream.streamUrl !== "string") return false;
        if (stream.streamUrl.indexOf("http") !== 0) return false;
        if (seenUrls.has(stream.streamUrl)) return false;
        seenUrls.add(stream.streamUrl);
        return true;
    });

    const getQualityWeight = (title) => {
        const t = title.toLowerCase();
        if (t.includes('4k') || t.includes('2160p')) return 4000;
        if (t.includes('1080p') || t.includes('fhd')) return 1080;
        if (t.includes('720p') || t.includes('hd')) return 720;
        if (t.includes('480p') || t.includes('sd')) return 480;
        if (t.includes('360p')) return 360;
        return 0;
    };

    streams.sort((a, b) => {
        const qualA = getQualityWeight(a.title);
        const qualB = getQualityWeight(b.title);
        if (qualA !== qualB) return qualB - qualA;
        const prioA = SOURCE_PRIORITY[a.sourceMapped] || 0;
        const prioB = SOURCE_PRIORITY[b.sourceMapped] || 0;
        return prioB - prioA;
    });
    return streams;
}

function emitCheckmateProgress(allStreams, subtitle) {
    if (typeof noirOnStreamsProgress !== "function" || !allStreams.length) return;
    const payload = {
        streams: allStreams.map(function(s) { return { title: s.title, streamUrl: s.streamUrl, headers: s.headers }; }),
        subtitles: subtitle || "",
        subtitle: subtitle || "",
        partial: true
    };
    try {
        noirOnStreamsProgress(JSON.stringify(payload));
    } catch (e) {
        console.log("emitCheckmateProgress failed: " + e.message);
    }
}

async function runProvider(source, streamID) {
    const mod = await getModule(source.name, source.url);
    if (!mod) return [];
    const resText = await mod.extractStreamUrl(streamID);
    const parsed = JSON.parse(resText);
    return streamsFromProviderResult(source, parsed);
}

async function extractStreamUrl(ID) {
    try {
        const media = parseMediaPath(ID);
        const streamID = normalizeStreamID(ID);
        const subtitlePromise = fetchDefaultSubtitle(media);

        // Preload all provider scripts in parallel (cached after first load).
        await Promise.all(SOURCES.map(function(s) {
            return getModule(s.name, s.url).catch(function() { return null; });
        }));

        let allStreams = [];
        let defaultSubtitle = "";
        let finished = 0;

        const outputPayload = async function() {
            const subtitle = defaultSubtitle || await subtitlePromise.catch(function() { return ""; });
            const sorted = dedupeAndSortStreams(allStreams);
            return JSON.stringify({
                streams: sorted.map(function(s) { return { title: s.title, streamUrl: s.streamUrl, headers: s.headers }; }),
                subtitles: subtitle,
                subtitle: subtitle,
                partial: false
            });
        };

        return await new Promise(function(resolve) {
            let resolved = false;
            function finish() {
                if (resolved) return;
                resolved = true;
                outputPayload().then(resolve);
            }

            if (!SOURCES.length) {
                finish();
                return;
            }

            const globalTimer = setTimeout(function() {
                console.log("Checkmate: global poll timeout with " + allStreams.length + " stream(s)");
                finish();
            }, GLOBAL_POLL_TIMEOUT_MS);

            subtitlePromise.then(function(sub) {
                if (sub) defaultSubtitle = sub;
                if (allStreams.length) emitCheckmateProgress(dedupeAndSortStreams(allStreams), defaultSubtitle);
            });

            SOURCES.forEach(function(source) {
                withTimeout(runProvider(source, streamID), PROVIDER_TIMEOUT_MS, source.name)
                    .then(function(streams) {
                        if (streams && streams.length) {
                            allStreams = allStreams.concat(streams);
                            const sorted = dedupeAndSortStreams(allStreams);
                            allStreams = sorted;
                            console.log("Checkmate: " + source.name + " returned " + streams.length + " stream(s)");
                            emitCheckmateProgress(sorted, defaultSubtitle);
                        }
                    })
                    .catch(function(err) {
                        console.log("Checkmate: " + source.name + " failed — " + err.message);
                    })
                    .finally(function() {
                        finished += 1;
                        if (finished >= SOURCES.length) {
                            clearTimeout(globalTimer);
                            finish();
                        }
                    });
            });
        });
    } catch (error) {
        console.log('Checkmate stream URL error: ' + error);
        return JSON.stringify({
            streams: [],
            subtitles: "",
            subtitle: ""
        });
    }
}

async function legacyFetch(url, headers) {
  return fetch(url, headers);
}

async function soraFetch(url, options = { headers: {}, method: 'GET', body: null, encoding: 'utf-8' }) {
    try {
        return await fetchv2(
            url,
            options.headers ?? {},
            options.method ?? 'GET',
            options.body ?? null,
            true,
            options.encoding ?? 'utf-8'
        );
    } catch (e) {
        try {
            return await legacyFetch(url, options.headers ?? {});
        } catch (error) {
            return null;
        }
    }
}
