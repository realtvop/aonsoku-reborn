import type { LyricLine, LyricWord } from "@applemusic-like-lyrics/core";
import type {
  IStructuredLyric,
  IStructuredLyricLine,
} from "@/types/responses/song";

/** Matches an LRC timestamp at the start of a line: [mm:ss.xx] or [mm:ss:xx] */
export const LRC_TIMESTAMP_REGEX = /^\[\d+:\d+[.:]\d+\]/;

/** Matches common LRC metadata tags like [ti:...], [ar:...], etc. */
export const LRC_METADATA_REGEX = /^\[(ti|ar|al|by|offset|re|ve|length):/;

/**
 * Supports formats: [mm:ss.xx], [mm:ss.xxx], [mm:ss:xx]
 */
function parseTimestamp(timestamp: string): number {
  const match = timestamp.match(/\[(\d+):(\d+)[.:](\d+)\]/);
  if (!match) return 0;

  const minutes = parseInt(match[1], 10);
  const seconds = parseInt(match[2], 10);
  let milliseconds = parseInt(match[3], 10);

  if (match[3].length === 2) {
    milliseconds *= 10;
  } else if (match[3].length === 1) {
    milliseconds *= 100;
  }

  return minutes * 60 * 1000 + seconds * 1000 + milliseconds;
}

function parseLrcLine(
  line: string,
): { timestamp: number; content: string } | null {
  const match = line.match(/^\[(\d+:\d+[.:]\d+)\](.*)$/);
  if (!match) return null;

  const timestamp = parseTimestamp(`[${match[1]}]`);
  const content = match[2].trim();

  return { timestamp, content };
}

/**
 * Build a translation map from structured lyric lines.
 * Maps start time (ms) to translated text.
 */
export function buildTranslationMap(
  lines: IStructuredLyricLine[],
): Map<number, string> {
  const map = new Map<number, string>();
  for (const line of lines) {
    if (line.start != null && line.value) {
      map.set(line.start, line.value);
    }
  }
  return map;
}

/**
 * When two consecutive parsed lines share the same timestamp,
 * the first is the main lyric and the second is the translation.
 */
function extractInlineTranslations(
  parsedLines: { timestamp: number; content: string }[],
): {
  mainLines: { timestamp: number; content: string }[];
  translations: Map<number, string>;
} {
  const mainLines: { timestamp: number; content: string }[] = [];
  const translations = new Map<number, string>();

  let i = 0;
  while (i < parsedLines.length) {
    const current = parsedLines[i];

    if (
      i + 1 < parsedLines.length &&
      parsedLines[i + 1].timestamp === current.timestamp
    ) {
      mainLines.push(current);
      translations.set(current.timestamp, parsedLines[i + 1].content);
      i += 2;
    } else {
      mainLines.push(current);
      i += 1;
    }
  }

  return { mainLines, translations };
}

/**
 * Build a timestamp → romanization map from a romaji/romaja LRC track.
 * The romanization is expected to share timestamps with the main lyrics.
 */
function buildRomanMap(romajiContent: string): Map<number, string> {
  const map = new Map<number, string>();
  for (const line of romajiContent.split("\n")) {
    const parsed = parseLrcLine(line);
    if (parsed && parsed.content) {
      map.set(parsed.timestamp, parsed.content);
    }
  }
  return map;
}

/**
 * Convert LRC format lyrics to AMLL LyricLine[] format.
 * Automatically detects inline dual-timestamp translations.
 *
 * When a `romajiContent` LRC track is provided, each main line is matched to
 * its romanization by timestamp and exposed through `romanLyric`.
 */
export function convertLrcToAMLL(
  lrcContent: string,
  songDurationMs?: number,
  romajiContent?: string,
): LyricLine[] {
  const lines = lrcContent.split("\n");
  const parsedLines: { timestamp: number; content: string }[] = [];

  for (const line of lines) {
    const parsed = parseLrcLine(line);
    if (parsed) {
      parsedLines.push(parsed);
    }
  }

  parsedLines.sort((a, b) => a.timestamp - b.timestamp);

  const extracted = extractInlineTranslations(parsedLines);
  const finalLines = extracted.mainLines;
  const translationMap =
    extracted.translations.size > 0 ? extracted.translations : undefined;
  const romanMap = romajiContent?.trim()
    ? buildRomanMap(romajiContent)
    : undefined;

  return finalLines.map((line, index, arr): LyricLine => {
    const endTime =
      index < arr.length - 1
        ? arr[index + 1].timestamp
        : (songDurationMs ?? line.timestamp + 5000);

    const word: LyricWord = {
      word: line.content,
      startTime: line.timestamp,
      endTime: endTime,
      romanWord: "",
      obscene: false,
    };

    return {
      words: [word],
      startTime: line.timestamp,
      endTime: endTime,
      translatedLyric: translationMap?.get(line.timestamp) ?? "",
      romanLyric: romanMap?.get(line.timestamp) ?? "",
      isBG: false,
      isDuet: false,
    };
  });
}

/**
 * When exactly two consecutive lines share the same start time,
 * the first is the main lyric and the second is the translation.
 * When more than two share the same timestamp, only the last two
 * are paired and the rest are kept as standalone lines.
 *
 * Returns a map keyed by index in `mainLines` (not by timestamp)
 * to avoid collisions when multiple standalone lines share the
 * same start time.
 */
function extractStructuredInlineTranslations(lines: IStructuredLyricLine[]): {
  mainLines: IStructuredLyricLine[];
  /** mainLines index → translated text */
  translations: Map<number, string>;
} {
  const mainLines: IStructuredLyricLine[] = [];
  const translations = new Map<number, string>();

  let i = 0;
  while (i < lines.length) {
    const groupStart = lines[i].start;
    let groupEnd = i;
    while (
      groupEnd + 1 < lines.length &&
      lines[groupEnd + 1].start === groupStart
    ) {
      groupEnd++;
    }

    const groupSize = groupEnd - i + 1;

    if (groupSize >= 2) {
      for (let j = i; j < groupEnd - 1; j++) {
        mainLines.push(lines[j]);
      }
      const pairedIndex = mainLines.length;
      mainLines.push(lines[groupEnd - 1]);
      translations.set(pairedIndex, lines[groupEnd].value);
    } else {
      mainLines.push(lines[i]);
    }

    i = groupEnd + 1;
  }

  return { mainLines, translations };
}

/**
 * Convert structured lyrics (from getLyricsBySongId) directly
 * to AMLL LyricLine[] format. Detects inline dual-timestamp
 * translations when no separate translation track is provided.
 */
export function convertStructuredToAMLL(
  primary: IStructuredLyric,
  translation?: IStructuredLyric,
  songDurationMs?: number,
): LyricLine[] {
  let sourceLines = primary.line;
  /** timestamp → translated text (external translation track) */
  let externalMap: Map<number, string> | undefined;
  /** mainLines index → translated text (inline dual-timestamp) */
  let inlineMap: Map<number, string> | undefined;

  if (translation) {
    externalMap = buildTranslationMap(translation.line);
  } else {
    const extracted = extractStructuredInlineTranslations(primary.line);
    if (extracted.translations.size > 0) {
      sourceLines = extracted.mainLines;
      inlineMap = extracted.translations;
    }
  }

  return sourceLines.map((line, index, arr): LyricLine => {
    const startTime = line.start ?? 0;
    const endTime =
      index < arr.length - 1
        ? (arr[index + 1].start ?? startTime + 5000)
        : (songDurationMs ?? startTime + 5000);

    const word: LyricWord = {
      word: line.value,
      startTime,
      endTime,
      romanWord: "",
      obscene: false,
    };

    // Inline translations keyed by index (avoids timestamp
    // collisions), external ones keyed by timestamp.
    const translated =
      inlineMap?.get(index) ?? externalMap?.get(startTime) ?? "";

    return {
      words: [word],
      startTime,
      endTime,
      translatedLyric: translated,
      romanLyric: "",
      isBG: false,
      isDuet: false,
    };
  });
}

/**
 * Check if lyrics are synced (have LRC timestamps)
 */
export function areLyricsSynced(lyrics: string): boolean {
  const lines = lyrics.trim().split("\n", 20);
  return lines.some((line) => LRC_TIMESTAMP_REGEX.test(line));
}
