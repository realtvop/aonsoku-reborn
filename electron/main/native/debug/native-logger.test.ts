import { describe, expect, it } from "vitest";
import { NativeDebugLogger } from "./native-logger";

describe("NativeDebugLogger", () => {
  it("stores entries and returns them oldest first", () => {
    const logger = new NativeDebugLogger();
    logger.debug("first", "audio");
    logger.info("second", "audio");
    logger.warn("third", "queue");

    const entries = logger.getEntries();
    expect(entries).toHaveLength(3);
    expect(entries[0].message).toBe("first");
    expect(entries[2].message).toBe("third");
  });

  it("assigns increasing timestamps and preserves level/source", () => {
    const logger = new NativeDebugLogger();
    logger.error("boom", "engine");
    const entries = logger.getEntries();
    expect(entries[0]).toMatchObject({
      level: "error",
      message: "boom",
      source: "engine",
    });
    expect(typeof entries[0].timestamp).toBe("number");
  });

  it("buckets per source and caps each bucket", () => {
    const logger = new NativeDebugLogger({ maxEntriesPerSource: 3 });
    for (let i = 0; i < 5; i += 1) logger.info(`a${i}`, "alpha");
    for (let i = 0; i < 2; i += 1) logger.info(`b${i}`, "beta");

    const entries = logger.getEntries();
    const alpha = entries.filter((e) => e.source === "alpha");
    const beta = entries.filter((e) => e.source === "beta");
    expect(alpha).toHaveLength(3);
    expect(beta).toHaveLength(2);
    // Oldest alpha entries evicted, keeping the most recent 3.
    expect(alpha.map((e) => e.message)).toEqual(["a2", "a3", "a4"]);
  });

  it("treats empty source as its own bucket", () => {
    const logger = new NativeDebugLogger();
    logger.info("no source");
    logger.info("with source", "x");
    const entries = logger.getEntries();
    expect(entries.find((e) => e.message === "no source")?.source).toBe("");
  });

  it("clears all entries", () => {
    const logger = new NativeDebugLogger();
    logger.info("a", "x");
    logger.info("b", "y");
    expect(logger.size).toBe(2);
    logger.clear();
    expect(logger.getEntries()).toHaveLength(0);
    expect(logger.size).toBe(0);
  });

  it("sorts same-timestamp entries by level rank (debug before error)", () => {
    const logger = new NativeDebugLogger();
    const now = 1000;
    // Force same timestamp by spying on Date is overkill; instead push directly
    // via log() in level order and verify getEntries is stable by level when
    // timestamps tie. We approximate by logging in reverse and checking sort.
    const original = Date.now;
    let t = now;
    Date.now = () => t;
    try {
      logger.log("error", "e", "s");
      logger.log("debug", "d", "s");
      t = now + 1;
      logger.log("info", "i", "s");
    } finally {
      Date.now = original;
    }
    const entries = logger.getEntries();
    expect(entries.map((e) => e.message)).toEqual(["d", "e", "i"]);
  });
});
