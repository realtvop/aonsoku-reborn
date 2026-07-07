import { describe, expect, it } from "vitest";
import type {
  IStructuredLyric,
  IStructuredLyricLine,
} from "@/types/responses/song";
import {
  areLyricsSynced,
  buildTranslationMap,
  convertLrcToAMLL,
  convertStructuredToAMLL,
  LRC_METADATA_REGEX,
  LRC_TIMESTAMP_REGEX,
} from "./lrc-converter";

describe("LRC_TIMESTAMP_REGEX", () => {
  it("matches standard LRC timestamps", () => {
    expect(LRC_TIMESTAMP_REGEX.test("[00:12.34]")).toBe(true);
    expect(LRC_TIMESTAMP_REGEX.test("[1:23.45]")).toBe(true);
    expect(LRC_TIMESTAMP_REGEX.test("[10:05:00]")).toBe(true);
  });

  it("rejects non-timestamp lines", () => {
    expect(LRC_TIMESTAMP_REGEX.test("[ti:Song Title]")).toBe(false);
    expect(LRC_TIMESTAMP_REGEX.test("plain text")).toBe(false);
  });
});

describe("LRC_METADATA_REGEX", () => {
  it("matches metadata tags", () => {
    expect(LRC_METADATA_REGEX.test("[ti:Song]")).toBe(true);
    expect(LRC_METADATA_REGEX.test("[ar:Artist]")).toBe(true);
    expect(LRC_METADATA_REGEX.test("[al:Album]")).toBe(true);
  });

  it("rejects timestamp lines", () => {
    expect(LRC_METADATA_REGEX.test("[00:12.34]")).toBe(false);
  });
});

describe("areLyricsSynced", () => {
  it("returns true for LRC content with timestamps", () => {
    expect(areLyricsSynced("[00:12.34]Hello world")).toBe(true);
  });

  it("returns false for plain text lyrics", () => {
    expect(areLyricsSynced("Hello world\nThis is a song")).toBe(false);
  });

  it("returns false for empty string", () => {
    expect(areLyricsSynced("")).toBe(false);
  });

  it("returns true even if only some lines have timestamps", () => {
    expect(areLyricsSynced("Hello\n[00:12.34]World")).toBe(true);
  });
});

describe("convertLrcToAMLL", () => {
  it("converts simple LRC to AMLL format", () => {
    const lrc = "[00:00.00]First line\n[00:05.00]Second line";
    const result = convertLrcToAMLL(lrc);
    expect(result).toHaveLength(2);
    expect(result[0].startTime).toBe(0);
    expect(result[0].words[0].word).toBe("First line");
    expect(result[1].startTime).toBe(5000);
    expect(result[1].words[0].word).toBe("Second line");
  });

  it("sets endTime from next line", () => {
    const lrc = "[00:00.00]First\n[00:10.00]Second";
    const result = convertLrcToAMLL(lrc);
    expect(result[0].endTime).toBe(10000);
  });

  it("uses songDurationMs for last line endTime", () => {
    const lrc = "[00:00.00]Only line";
    const result = convertLrcToAMLL(lrc, 30000);
    expect(result[0].endTime).toBe(30000);
  });

  it("defaults to +5000ms for last line without duration", () => {
    const lrc = "[00:00.00]Only line";
    const result = convertLrcToAMLL(lrc);
    expect(result[0].endTime).toBe(5000);
  });

  it("skips non-timestamp lines", () => {
    const lrc = "[ti:Title]\n[00:00.00]Hello";
    const result = convertLrcToAMLL(lrc);
    expect(result).toHaveLength(1);
  });

  it("handles inline translations (duplicate timestamps)", () => {
    const lrc = "[00:01.00]Hello\n[00:01.00]Hola\n[00:05.00]World";
    const result = convertLrcToAMLL(lrc);
    expect(result).toHaveLength(2);
    expect(result[0].words[0].word).toBe("Hello");
    expect(result[0].translatedLyric).toBe("Hola");
    expect(result[1].words[0].word).toBe("World");
  });

  it("leaves romanLyric empty without a romaji track", () => {
    const lrc = "[00:00.00]こんにちは\n[00:05.00]世界";
    const result = convertLrcToAMLL(lrc);
    expect(result[0].romanLyric).toBe("");
    expect(result[1].romanLyric).toBe("");
  });

  it("maps a romaji track onto romanLyric by timestamp", () => {
    const lrc = "[00:00.00]こんにちは\n[00:05.00]世界";
    const romaji = "[00:00.00]konnichiwa\n[00:05.00]sekai";
    const result = convertLrcToAMLL(lrc, undefined, romaji);
    expect(result[0].romanLyric).toBe("konnichiwa");
    expect(result[1].romanLyric).toBe("sekai");
  });

  it("keeps romaji alongside inline translations", () => {
    const lrc = "[00:01.00]こんにちは\n[00:01.00]你好\n[00:05.00]世界";
    const romaji = "[00:01.00]konnichiwa\n[00:05.00]sekai";
    const result = convertLrcToAMLL(lrc, undefined, romaji);
    expect(result).toHaveLength(2);
    expect(result[0].words[0].word).toBe("こんにちは");
    expect(result[0].translatedLyric).toBe("你好");
    expect(result[0].romanLyric).toBe("konnichiwa");
    expect(result[1].romanLyric).toBe("sekai");
  });

  it("ignores a blank romaji track", () => {
    const lrc = "[00:00.00]世界";
    const result = convertLrcToAMLL(lrc, undefined, "   ");
    expect(result[0].romanLyric).toBe("");
  });
});

describe("buildTranslationMap", () => {
  it("maps start times to values", () => {
    const lines: IStructuredLyricLine[] = [
      { start: 1000, value: "Hola" },
      { start: 2000, value: "Mundo" },
    ];
    const map = buildTranslationMap(lines);
    expect(map.get(1000)).toBe("Hola");
    expect(map.get(2000)).toBe("Mundo");
  });

  it("skips lines without start or value", () => {
    const lines: IStructuredLyricLine[] = [
      { start: undefined, value: "Skip" },
      { start: 1000, value: "" },
      { start: 2000, value: "Keep" },
    ];
    const map = buildTranslationMap(lines);
    expect(map.has(1000)).toBe(false);
    expect(map.get(2000)).toBe("Keep");
  });
});

describe("convertStructuredToAMLL", () => {
  it("converts structured lyrics to AMLL format", () => {
    const primary: IStructuredLyric = {
      line: [
        { start: 0, value: "First" },
        { start: 5000, value: "Second" },
      ],
    };
    const result = convertStructuredToAMLL(primary);
    expect(result).toHaveLength(2);
    expect(result[0].words[0].word).toBe("First");
    expect(result[1].startTime).toBe(5000);
  });

  it("applies external translation track", () => {
    const primary: IStructuredLyric = {
      line: [{ start: 0, value: "Hello" }],
    };
    const translation: IStructuredLyric = {
      line: [{ start: 0, value: "Hola" }],
    };
    const result = convertStructuredToAMLL(primary, translation);
    expect(result[0].translatedLyric).toBe("Hola");
  });

  it("detects inline dual-timestamp translations", () => {
    const primary: IStructuredLyric = {
      line: [
        { start: 0, value: "Hello" },
        { start: 0, value: "Hola" },
      ],
    };
    const result = convertStructuredToAMLL(primary);
    expect(result).toHaveLength(1);
    expect(result[0].translatedLyric).toBe("Hola");
  });

  it("uses songDurationMs for last line", () => {
    const primary: IStructuredLyric = {
      line: [{ start: 0, value: "Only" }],
    };
    const result = convertStructuredToAMLL(primary, undefined, 60000);
    expect(result[0].endTime).toBe(60000);
  });

  it("handles lines with undefined start as 0", () => {
    const primary: IStructuredLyric = {
      line: [{ start: undefined, value: "Test" }],
    };
    const result = convertStructuredToAMLL(primary);
    expect(result[0].startTime).toBe(0);
  });
});
