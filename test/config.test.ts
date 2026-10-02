import { describe, expect, it } from "vitest";
import { booleanSetting, integerSetting } from "../src/security";

describe("Worker runtime settings", () => {
  it("accepts dashboard boolean values and keeps a safe default", () => {
    expect(booleanSetting(true, false)).toBe(true);
    expect(booleanSetting("false", true)).toBe(false);
    expect(booleanSetting("unexpected", true)).toBe(true);
    expect(booleanSetting(undefined, true)).toBe(true);
  });

  it("bounds the configurable device limit", () => {
    expect(integerSetting(250, 100, 1, 1000)).toBe(250);
    expect(integerSetting("12", 100, 1, 1000)).toBe(12);
    expect(integerSetting(0, 100, 1, 1000)).toBe(100);
    expect(integerSetting(1001, 100, 1, 1000)).toBe(100);
  });
});
