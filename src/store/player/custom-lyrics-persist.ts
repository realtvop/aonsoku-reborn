import {
  MAX_SELECTED_CUSTOM_LYRICS,
  type SelectedCustomLyrics,
} from "@/types/playerContext";

export function stripCustomLyricsBodies(
  selected: Record<string, SelectedCustomLyrics> | undefined,
): {
  sanitized: Record<string, SelectedCustomLyrics> | undefined;
  evictedKeys: string[];
} {
  if (!selected || typeof selected !== "object") {
    return { sanitized: selected, evictedKeys: [] };
  }

  const entries = Object.entries(selected);
  const evictedKeys: string[] = [];

  if (entries.length > MAX_SELECTED_CUSTOM_LYRICS) {
    const evicted = entries.slice(
      0,
      entries.length - MAX_SELECTED_CUSTOM_LYRICS,
    );
    evictedKeys.push(...evicted.map(([k]) => k));
  }

  const trimmed = entries.slice(-MAX_SELECTED_CUSTOM_LYRICS);

  const sanitized = Object.fromEntries(
    trimmed
      .filter(([_, v]) => v != null)
      .map(([k, v]) => {
        if ("lyrics" in v || "romaji" in v) {
          const {
            lyrics: _lyrics,
            romaji: _romaji,
            ...meta
          } = v as SelectedCustomLyrics & {
            lyrics?: string;
            romaji?: string;
          };
          return [k, meta];
        }
        return [k, v];
      }),
  );

  return { sanitized, evictedKeys };
}

// biome-ignore lint/suspicious/noExplicitAny: persisted state shape is versioned
export async function migrateCustomLyricsBodiesToIdb(state: any) {
  const entries = state?.settings?.lyrics?.selectedCustomLyrics;
  if (!entries || typeof entries !== "object") return;

  const { setCustomLyricsBody } = await import("@/service/lyrics");
  const promises: Promise<void>[] = [];
  for (const [songKey, entry] of Object.entries(entries)) {
    if (entry && typeof entry === "object" && "lyrics" in entry) {
      // biome-ignore lint/suspicious/noExplicitAny: migration
      const body = (entry as any).lyrics;
      if (typeof body === "string" && body) {
        promises.push(setCustomLyricsBody(songKey, body));
      }
      // biome-ignore lint/suspicious/noExplicitAny: migration
      delete (entry as any).lyrics;
    }
  }
  await Promise.all(promises);
}
