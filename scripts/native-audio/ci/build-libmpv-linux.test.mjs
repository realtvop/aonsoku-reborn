import { describe, expect, it } from "vitest";
import {
  DEFAULT_MPV_VERSION,
  parseArgs,
  RELEASE_MPV_VERSIONS,
  resolveMpvSourceConfig,
  verifySourceCommit,
} from "./build-libmpv-linux.mjs";

const PINNED = RELEASE_MPV_VERSIONS[DEFAULT_MPV_VERSION];

describe("parseArgs", () => {
  it("parses staging and jobs", () => {
    const parsed = parseArgs(["--staging", "./build", "--jobs", "3"]);
    expect(parsed).toEqual({ staging: "./build", jobs: 3 });
  });

  it("parses mpv-version and expected-commit value options", () => {
    const parsed = parseArgs([
      "--mpv-version",
      "v0.35.0",
      "--expected-commit",
      "deadbeef",
    ]);
    expect(parsed).toEqual({
      mpvVersion: "v0.35.0",
      expectedCommit: "deadbeef",
    });
  });

  it("parses --allow-unpinned as a boolean flag without consuming a value", () => {
    const parsed = parseArgs(["--allow-unpinned", "--staging", "./build"]);
    expect(parsed).toEqual({ allowUnpinned: true, staging: "./build" });
  });

  it("falls back to defaults when flags are absent", () => {
    expect(parseArgs([])).toEqual({});
  });
});

describe("resolveMpvSourceConfig", () => {
  it("defaults to the known release with the pinned commit", () => {
    const config = resolveMpvSourceConfig({});
    expect(config).toEqual({
      mpvVersion: DEFAULT_MPV_VERSION,
      expectedCommit: PINNED,
      verifyCommit: true,
      isRelease: true,
      warning: null,
    });
  });

  it("uses the pinned commit for an explicit known release without --expected-commit", () => {
    const config = resolveMpvSourceConfig({ mpvVersion: "v0.35.0" });
    expect(config.expectedCommit).toBe(PINNED);
    expect(config.verifyCommit).toBe(true);
    expect(config.isRelease).toBe(true);
    expect(config.warning).toBeNull();
  });

  it("accepts an --expected-commit matching the pin as the release build", () => {
    const config = resolveMpvSourceConfig({
      mpvVersion: "v0.35.0",
      expectedCommit: PINNED.toUpperCase(),
    });
    expect(config.expectedCommit).toBe(PINNED);
    expect(config.isRelease).toBe(true);
  });

  it("flags a differing --expected-commit for a known release as non-release", () => {
    const config = resolveMpvSourceConfig({
      mpvVersion: "v0.35.0",
      expectedCommit: "0123456789abcdef0123456789abcdef01234567",
    });
    expect(config.isRelease).toBe(false);
    expect(config.verifyCommit).toBe(true);
    expect(config.expectedCommit).toBe(
      "0123456789abcdef0123456789abcdef01234567",
    );
    expect(config.warning).toMatch(/Overriding pinned v0.35.0 commit/);
  });

  it("requires --expected-commit or --allow-unpinned for an unknown version", () => {
    expect(() =>
      resolveMpvSourceConfig({ mpvVersion: "v9.99.0" }),
    ).toThrowError(/--mpv-version v9.99.0 is not a known Aonsoku release/);
  });

  it("builds a pinned non-release for an unknown version with --expected-commit", () => {
    const config = resolveMpvSourceConfig({
      mpvVersion: "main",
      expectedCommit: "abcdefabcdefabcdefabcdefabcdefabcdefabcd",
    });
    expect(config.isRelease).toBe(false);
    expect(config.verifyCommit).toBe(true);
    expect(config.expectedCommit).toBe(
      "abcdefabcdefabcdefabcdefabcdefabcdefabcd",
    );
    expect(config.warning).toMatch(/not a known Aonsoku release/);
  });

  it("skips verification for an unknown version with --allow-unpinned", () => {
    const config = resolveMpvSourceConfig({
      mpvVersion: "main",
      allowUnpinned: true,
    });
    expect(config.isRelease).toBe(false);
    expect(config.verifyCommit).toBe(false);
    expect(config.expectedCommit).toBeNull();
    expect(config.warning).toMatch(/skipping commit verification/);
  });

  it("uses an injected knownReleases map", () => {
    const config = resolveMpvSourceConfig({
      mpvVersion: "custom",
      knownReleases: { custom: "feedface" },
    });
    expect(config.expectedCommit).toBe("feedface");
    expect(config.isRelease).toBe(true);
  });
});

describe("verifySourceCommit", () => {
  const ok = (sha) => ({ status: 0, stdout: `${sha}\n`, stderr: "" });

  it("returns the matching commit on success", () => {
    const result = verifySourceCommit({
      sourceDir: "/repo/mpv-src",
      expectedCommit: PINNED,
      runGit: () => ok(PINNED),
    });
    expect(result).toEqual({
      actualCommit: PINNED,
      expectedCommit: PINNED,
    });
  });

  it("compares case-insensitively and trims whitespace", () => {
    const result = verifySourceCommit({
      sourceDir: "/repo/mpv-src",
      expectedCommit: PINNED.toUpperCase(),
      runGit: () => ok(`  ${PINNED}  \n`),
    });
    expect(result.actualCommit).toBe(PINNED);
  });

  it("throws on commit mismatch", () => {
    expect(() =>
      verifySourceCommit({
        sourceDir: "/repo/mpv-src",
        expectedCommit: PINNED,
        runGit: () => ok("0123456789abcdef0123456789abcdef01234567"),
      }),
    ).toThrowError(/mpv source commit mismatch/);
  });

  it("throws when git rev-parse fails", () => {
    expect(() =>
      verifySourceCommit({
        sourceDir: "/repo/mpv-src",
        expectedCommit: PINNED,
        runGit: () => ({
          status: 128,
          stdout: "",
          stderr: "fatal: not a repo",
        }),
      }),
    ).toThrowError(/git rev-parse HEAD failed/);
  });

  it("throws when called without an expected commit", () => {
    expect(() =>
      verifySourceCommit({
        sourceDir: "/repo/mpv-src",
        expectedCommit: null,
        runGit: () => ok(PINNED),
      }),
    ).toThrowError(/without an expected commit/);
  });
});
