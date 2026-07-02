import { createStore, del, get, set } from "idb-keyval";
import { httpClient } from "@/api/httpClient";
import { usePlayerStore } from "@/store/player.store";
import type { LyricsSource, SelectedCustomLyrics } from "@/types/playerContext";
import type {
  ILyric,
  IStructuredLyric,
  LyricsBySongIdResponse,
  LyricsResponse,
} from "@/types/responses/song";
import { lrclibClient } from "@/utils/appName";
import { logger } from "@/utils/logger";
import { checkServerType } from "@/utils/servers";

export const CUSTOM_LYRICS_IDB_PREFIX = "custom-lyrics:";
export const CUSTOM_LYRICS_DB_NAME = "aonsoku-custom-lyrics";
export const CUSTOM_LYRICS_STORE_NAME = "lyrics";

const customLyricsStore = createStore(
  CUSTOM_LYRICS_DB_NAME,
  CUSTOM_LYRICS_STORE_NAME,
);

async function setCustomLyricsBodyWithRetry(
  idbKey: string,
  lyrics: string,
  retries = 1,
) {
  try {
    await set(idbKey, lyrics, customLyricsStore);
  } catch (err) {
    if (retries > 0) {
      await new Promise((resolve) => setTimeout(resolve, 200));
      return setCustomLyricsBodyWithRetry(idbKey, lyrics, retries - 1);
    }

    throw err;
  }
}

export async function getCustomLyricsBody(
  songKey: string,
): Promise<string | undefined> {
  const idbKey = `${CUSTOM_LYRICS_IDB_PREFIX}${songKey}`;

  try {
    const body = await get<string>(idbKey, customLyricsStore);
    return body;
  } catch (err) {
    logger.warn("[lyrics] Failed to read custom lyrics body from IDB:", err);
    return undefined;
  }
}

export async function setCustomLyricsBody(
  songKey: string,
  lyrics: string,
): Promise<void> {
  const idbKey = `${CUSTOM_LYRICS_IDB_PREFIX}${songKey}`;
  await setCustomLyricsBodyWithRetry(idbKey, lyrics);
}

export function deleteCustomLyricsBodies(songKeys: string[]): Promise<void[]> {
  return Promise.all(
    songKeys.map((key) =>
      del(`${CUSTOM_LYRICS_IDB_PREFIX}${key}`, customLyricsStore).catch(
        (err) => {
          logger.warn("[lyrics] Failed to delete custom lyrics body:", err);
        },
      ),
    ),
  );
}

export interface GetLyricsData {
  artist: string;
  title: string;
  album?: string;
  duration?: number;
  path?: string;
}

export interface CustomLyricsSearchData {
  artist?: string;
  title?: string;
}

export interface CustomLyricsCandidate {
  id?: string;
  title?: string;
  artist?: string;
  lyrics?: string;
}

export function getSelectedCustomLyrics(
  selectedLyrics: Record<string, SelectedCustomLyrics> | undefined,
  songKey: string,
) {
  return selectedLyrics?.[songKey];
}

interface LRCLibResponse {
  id: number;
  trackName: string;
  artistName: string;
  plainLyrics: string;
  syncedLyrics: string;
}

async function getLyrics(getLyricsData: GetLyricsData) {
  const lyricsSettings = usePlayerStore.getState().settings.lyrics;
  const { preferSyncedLyrics } = lyricsSettings;
  const sourcePriority = getEnabledLyricsSources(
    lyricsSettings.sourcePriority,
    lyricsSettings.customServerEnabled,
    lyricsSettings.customServerUrl,
  );
  const selectedCustomLyrics = getSelectedCustomLyrics(
    lyricsSettings.selectedCustomLyrics,
    getCustomLyricsSongKey(getLyricsData),
  );

  if (selectedCustomLyrics?.disabled) {
    return {
      artist: getLyricsData.artist,
      title: getLyricsData.title,
      value: "",
    };
  }

  const cacheKey = getLyricsCacheKey(
    getLyricsData,
    preferSyncedLyrics,
    sourcePriority,
    lyricsSettings.customServerEnabled,
    lyricsSettings.customServerUrl,
    selectedCustomLyrics?.key,
  );

  const cachedLyrics = await get(cacheKey);

  if (cachedLyrics) {
    return cachedLyrics;
  }

  for (const source of sourcePriority) {
    const lyrics = await getLyricsFromSource(source, getLyricsData);

    if (lyrics?.value) {
      set(cacheKey, lyrics);
      return lyrics;
    }
  }

  return {
    artist: getLyricsData.artist,
    title: getLyricsData.title,
    value: "",
  };
}

async function getLyricsFromSource(
  source: LyricsSource,
  getLyricsData: GetLyricsData,
) {
  if (source === "lrclib") return getLyricsFromLRCLib(getLyricsData);
  if (source === "custom") return getLyricsFromCustomServer(getLyricsData);

  return getLyricsFromNavidrome(getLyricsData);
}

async function getLyricsFromNavidrome(getLyricsData: GetLyricsData) {
  const response = await httpClient<LyricsResponse>("/getLyrics", {
    method: "GET",
    query: {
      artist: getLyricsData.artist,
      title: getLyricsData.title,
    },
  });

  return response?.data.lyrics;
}

async function getLyricsFromLRCLib(getLyricsData: GetLyricsData) {
  const { lrcLibEnabled } = usePlayerStore.getState().settings.privacy;
  const { isLms } = checkServerType();

  const { title, album, duration } = getLyricsData;

  // LMS server tends to join all artists into a single string
  // Ex: "Cartoon, Jeja, Daniel Levi, Time To Talk"
  // To LRCLIB work correctly, we have to send only one
  const artist = isLms
    ? getLyricsData.artist.split(",")[0]
    : getLyricsData.artist;

  if (!lrcLibEnabled) {
    return {
      artist,
      title,
      value: "",
    };
  }

  try {
    const params = new URLSearchParams({
      artist_name: artist,
      track_name: title,
    });

    if (duration) params.append("duration", duration.toString());
    if (album) params.append("album_name", album);

    const url = new URL("https://lrclib.net/api/get");
    url.search = params.toString();

    const request = await fetch(url.toString(), {
      headers: {
        "Lrclib-Client": lrclibClient,
      },
    });
    const response: LRCLibResponse = await request.json();

    if (response) {
      const { syncedLyrics, plainLyrics } = response;

      let finalLyric = "";

      if (syncedLyrics) {
        finalLyric = syncedLyrics;
      } else if (plainLyrics) {
        finalLyric = plainLyrics;
      }

      return {
        artist,
        title,
        value: formatLyrics(finalLyric),
      };
    }
  } catch {}

  return {
    artist,
    title,
    value: "",
  };
}

async function getLyricsFromCustomServer(
  getLyricsData: GetLyricsData,
): Promise<ILyric> {
  const { customServerEnabled, customServerUrl, customServerPassword } =
    usePlayerStore.getState().settings.lyrics;
  const { artist, title, album, duration, path } = getLyricsData;
  const songKey = getCustomLyricsSongKey(getLyricsData);
  const selectedCustomLyrics = getSelectedCustomLyrics(
    usePlayerStore.getState().settings.lyrics.selectedCustomLyrics,
    songKey,
  );

  if (selectedCustomLyrics?.key) {
    const body = await getCustomLyricsBody(songKey);
    if (body) {
      return {
        artist: selectedCustomLyrics.artist || artist,
        title: selectedCustomLyrics.title || title,
        value: formatLyrics(body),
      };
    }
  }

  if (!customServerEnabled || !customServerUrl.trim()) {
    return { artist, title, value: "" };
  }

  try {
    const url = new URL(customServerUrl.trim());
    if (title) url.searchParams.set("title", title);
    if (artist) url.searchParams.set("artist", artist);
    if (album) url.searchParams.set("album", album);
    if (duration) url.searchParams.set("duration", duration.toString());
    if (path) url.searchParams.set("path", path);
    url.searchParams.set("offset", "0");
    url.searchParams.set("limit", "10");

    const headers = new Headers();
    if (customServerPassword) {
      headers.set("Authorization", customServerPassword);
    }

    const request = await fetch(url.toString(), { headers });

    if (!request.ok) {
      return { artist, title, value: "" };
    }

    const contentType = request.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      const response = (await request.json()) as CustomLyricsCandidate[];
      const candidates = Array.isArray(response)
        ? response.filter((candidate) => candidate.lyrics?.trim())
        : [];
      if (!candidates.length) return { artist, title, value: "" };

      const item =
        candidates.find(
          (candidate, index) =>
            getCustomLyricsCandidateKey(candidate, index) ===
            selectedCustomLyrics?.key,
        ) ?? candidates[0];

      return {
        artist: item.artist || artist,
        title: item.title || title,
        value: item.lyrics ? formatLyrics(item.lyrics) : "",
      };
    }

    const response = await request.text();

    return {
      artist,
      title,
      value: formatLyrics(response),
    };
  } catch {
    return { artist, title, value: "" };
  }
}

async function getCustomLyricsCandidates(
  getLyricsData: CustomLyricsSearchData,
): Promise<CustomLyricsCandidate[]> {
  const { customServerEnabled, customServerUrl, customServerPassword } =
    usePlayerStore.getState().settings.lyrics;
  const { artist, title } = getLyricsData;

  if (!customServerEnabled || !customServerUrl.trim()) return [];

  try {
    const headers = new Headers();
    if (customServerPassword) {
      headers.set("Authorization", customServerPassword);
    }

    const url = new URL(customServerUrl.trim());
    if (title?.trim()) url.searchParams.set("title", title.trim());
    if (artist?.trim()) url.searchParams.set("artist", artist.trim());

    const request = await fetch(url.toString(), { headers });

    if (!request.ok) return [];

    const contentType = request.headers.get("content-type") || "";
    if (!contentType.includes("application/json")) return [];

    const response = (await request.json()) as CustomLyricsCandidate[];
    if (!Array.isArray(response)) return [];

    return response.filter((candidate) => candidate.lyrics?.trim());
  } catch {
    return [];
  }
}

export function getCustomLyricsSongKey(getLyricsData: GetLyricsData) {
  return [
    getLyricsData.path || "",
    getLyricsData.artist,
    getLyricsData.title,
    getLyricsData.album || "",
  ].join("\u001f");
}

export function getCustomLyricsCandidateKey(
  candidate: CustomLyricsCandidate,
  index: number,
) {
  return (
    candidate.id ||
    `${index}:${candidate.artist || ""}:${candidate.title || ""}`
  );
}

function formatLyrics(lyrics: string) {
  return lyrics.trim().replaceAll("\r\n", "\n");
}

function getLyricsCacheKey(
  getLyricsData: GetLyricsData,
  preferSyncedLyrics: boolean,
  sourcePriority: LyricsSource[],
  customServerEnabled: boolean,
  customServerUrl: string,
  selectedCustomLyricsKey?: string,
) {
  const { artist, title, album, duration, path } = getLyricsData;

  const type = preferSyncedLyrics ? "synced" : "plain";
  const customServerKey = customServerEnabled ? customServerUrl.trim() : "off";
  const albumKey = album?.trim() || "";
  const durationKey = duration?.toString() || "";
  const pathKey = path?.trim() || "";

  return [
    "lyrics",
    artist,
    title,
    albumKey,
    durationKey,
    pathKey,
    type,
    sourcePriority.join(","),
    customServerKey,
    selectedCustomLyricsKey || "auto",
  ].join(":");
}

function getEnabledLyricsSources(
  sourcePriority: LyricsSource[] | undefined,
  customServerEnabled: boolean,
  customServerUrl: string,
) {
  const configuredSources = Array.isArray(sourcePriority) ? sourcePriority : [];
  const sources = configuredSources.filter(isLyricsSource);

  for (const source of ["navidrome", "lrclib", "custom"] as const) {
    if (!sources.includes(source)) sources.push(source);
  }

  return sources.filter(
    (source) =>
      source !== "custom" ||
      (customServerEnabled && customServerUrl.trim().length > 0),
  );
}

function isLyricsSource(value: unknown): value is LyricsSource {
  return value === "navidrome" || value === "lrclib" || value === "custom";
}

async function getStructuredLyrics(
  songId: string,
): Promise<IStructuredLyric[] | null> {
  // IDB-first (P7.2): explicit/smart downloads prefetch structured
  // lyrics into libraryDb.lyrics alongside the audio so offline
  // playback has them immediately.
  try {
    const { libraryDb } = await import("@/store/library-db");
    const stored = await libraryDb.lyrics.get(songId);
    if (stored?.content) {
      const parsed = JSON.parse(stored.content) as IStructuredLyric[];
      if (Array.isArray(parsed) && parsed.length > 0) {
        libraryDb.lyrics
          .update(songId, { lastAccessedAt: Date.now() })
          .catch(() => {});
        return parsed;
      }
    }
  } catch (err) {
    console.warn("[lyrics] libraryDb lookup failed, falling back:", err);
  }

  const cacheKey = `lyrics-structured:${songId}`;

  const cached = await get(cacheKey);
  if (cached) return cached;

  try {
    const response = await httpClient<LyricsBySongIdResponse>(
      "/getLyricsBySongId",
      {
        method: "GET",
        query: { id: songId },
      },
    );

    const structuredLyrics = response.data.lyricsList?.structuredLyrics;

    if (structuredLyrics && structuredLyrics.length > 0) {
      set(cacheKey, structuredLyrics);
      return structuredLyrics;
    }
  } catch {
    // Silently fallback — endpoint may not be supported
  }

  return null;
}

export const lyrics = {
  getLyrics,
  getLyricsFromLRCLib,
  getLyricsFromCustomServer,
  getCustomLyricsCandidates,
  getCustomLyricsSongKey,
  getCustomLyricsCandidateKey,
  getStructuredLyrics,
};
