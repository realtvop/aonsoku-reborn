import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  parseLddOutput,
  parseReadelfDynamic,
  verifyLinuxRuntimeLinkage,
} from "./linux-runtime-linkage.mjs";

describe("parseLddOutput", () => {
  it("parses resolved, not-found, and loader/vdso lines", () => {
    const stdout = [
      "\tlinux-vdso.so.1 (0x00007ffd9f9fe000)",
      "\tlibmpv.so.2 => /bundle/libmpv.so.2 (0x00007f0000000000)",
      "\tlibavcodec.so.58 => /bundle/libavcodec.so.58 (0x00007f0000100000)",
      "\tlibmissing.so.1 => not found",
      "\t/lib64/ld-linux-x86-64.so.2 (0x00007f0000200000)",
    ].join("\n");

    const entries = parseLddOutput(stdout);
    expect(entries).toEqual([
      {
        soname: "libmpv.so.2",
        path: "/bundle/libmpv.so.2",
        notFound: false,
      },
      {
        soname: "libavcodec.so.58",
        path: "/bundle/libavcodec.so.58",
        notFound: false,
      },
      {
        soname: "libmissing.so.1",
        path: null,
        notFound: true,
      },
    ]);
  });

  it("treats an unrecognized => shape as unresolved", () => {
    const stdout = "\tlibweird.so.1 => something unexpected";
    const entries = parseLddOutput(stdout);
    expect(entries).toEqual([
      { soname: "libweird.so.1", path: null, notFound: true },
    ]);
  });

  it("ignores blank lines and lines without =>", () => {
    const stdout = [
      "",
      "\tlinux-vdso.so.1 (0x00007ffd9f9fe000)",
      "",
      "\t/lib64/ld-linux-x86-64.so.2 (0x00007f0000200000)",
      "",
    ].join("\n");
    expect(parseLddOutput(stdout)).toEqual([]);
  });
});

describe("parseReadelfDynamic", () => {
  it("extracts NEEDED, RPATH, and RUNPATH", () => {
    const stdout = [
      "Dynamic section at offset 0x1000 contains 5 entries:",
      "  Tag        Type                         Name/Value",
      " 0x0000000000000001 (NEEDED)             Shared library: [libmpv.so.2]",
      " 0x0000000000000001 (NEEDED)             Shared library: [libstdc++.so.6]",
      " 0x000000000000000f (RPATH)              Library rpath: [$ORIGIN]",
      " 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN:/usr/lib]",
    ].join("\n");

    expect(parseReadelfDynamic(stdout)).toEqual({
      needed: ["libmpv.so.2", "libstdc++.so.6"],
      rpath: "$ORIGIN",
      runpath: "$ORIGIN:/usr/lib",
    });
  });

  it("returns null rpath/runpath when absent", () => {
    const stdout = [
      "Dynamic section at offset 0x1000 contains 1 entries:",
      " 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]",
    ].join("\n");
    expect(parseReadelfDynamic(stdout)).toEqual({
      needed: ["libc.so.6"],
      rpath: null,
      runpath: null,
    });
  });
});

const LDD_OK = (entries) => ({
  status: 0,
  stdout: entries
    .map(
      (e) =>
        `\t${e.soname} => ${
          e.notFound ? "not found" : `${e.path} (0x00007f0000000000)`
        }`,
    )
    .join("\n"),
  stderr: "",
});

const READELF_OK = (rpath, runpath, needed) => ({
  status: 0,
  stdout: [
    "Dynamic section at offset 0x1000 contains 3 entries:",
    ...needed.map(
      (n) => ` 0x0000000000000001 (NEEDED)             Shared library: [${n}]`,
    ),
    ...(rpath
      ? [` 0x000000000000000f (RPATH)              Library rpath: [${rpath}]`]
      : []),
    ...(runpath
      ? [
          ` 0x000000000000001d (RUNPATH)            Library runpath: [${runpath}]`,
        ]
      : []),
  ].join("\n"),
  stderr: "",
});

function makeRunCommand(perFile) {
  return (file, tool) =>
    perFile[path.basename(file)]?.[tool] ?? {
      status: 0,
      stdout: "",
      stderr: "",
    };
}

const bundle = path.resolve("/repo/resources/native-audio/linux-x64");
const ADDON = "aonsoku_libmpv.node";

/**
 * Build a `verifyLinuxRuntimeLinkage` call where every file referenced by the
 * manifest (+addon) is assumed to exist on disk, so tests only need to specify
 * the ldd/readelf output per file. Pass `missing: [names]` to simulate absent
 * files.
 */
function runVerify({ manifest, runCommand, missing = [], overrides = {} }) {
  const libraries = [
    ...(manifest.libraries ?? []),
    ...(manifest.dependencies ?? []),
  ];
  const known = [ADDON, ...libraries].filter((name) => !missing.includes(name));
  const existsFile = (absolutePath) =>
    known.includes(path.basename(absolutePath));

  return verifyLinuxRuntimeLinkage({
    nativeAudioDirectory: bundle,
    manifest,
    hostPlatform: "linux",
    targetPlatform: "linux",
    runCommand,
    existsFile,
    ...overrides,
  });
}

describe("verifyLinuxRuntimeLinkage", () => {
  it("is a no-op when target is not linux or host is not linux", () => {
    const result = verifyLinuxRuntimeLinkage({
      nativeAudioDirectory: bundle,
      manifest: { libraries: ["libmpv.so.2"] },
      hostPlatform: "darwin",
      targetPlatform: "linux",
      runCommand: makeRunCommand({}),
    });
    expect(result.errors).toEqual([]);
    expect(result.checked).toEqual([]);
    expect(result.warnings[0]).toMatch(/Skipping Linux runtime linkage check/);
  });

  it("reports missing addon", () => {
    const result = runVerify({
      manifest: { libraries: [] },
      runCommand: makeRunCommand({}),
      missing: [ADDON],
    });
    expect(result.errors.some((e) => /missing addon/.test(e))).toBe(true);
  });

  it("passes a clean self-contained bundle", () => {
    const runCommand = makeRunCommand({
      [ADDON]: {
        ldd: LDD_OK([
          {
            soname: "libmpv.so.2",
            path: path.join(bundle, "libmpv.so.2"),
            notFound: false,
          },
          {
            soname: "libavcodec.so.58",
            path: path.join(bundle, "libavcodec.so.58"),
            notFound: false,
          },
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        readelf: READELF_OK("$ORIGIN", null, ["libmpv.so.2", "libc.so.6"]),
      },
      "libmpv.so.2": {
        ldd: LDD_OK([
          {
            soname: "libavcodec.so.58",
            path: path.join(bundle, "libavcodec.so.58"),
            notFound: false,
          },
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        readelf: READELF_OK(null, "$ORIGIN", ["libavcodec.so.58", "libc.so.6"]),
      },
      "libavcodec.so.58": {
        ldd: LDD_OK([
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        readelf: READELF_OK(null, "$ORIGIN", ["libc.so.6"]),
      },
    });

    const result = runVerify({
      manifest: { libraries: ["libmpv.so.2", "libavcodec.so.58"] },
      runCommand,
    });

    expect(result.errors).toEqual([]);
    expect(result.checked).toEqual([ADDON, "libmpv.so.2", "libavcodec.so.58"]);
  });

  it("reports a not-found dependency", () => {
    const runCommand = makeRunCommand({
      [ADDON]: {
        ldd: LDD_OK([
          {
            soname: "libmpv.so.2",
            path: path.join(bundle, "libmpv.so.2"),
            notFound: false,
          },
          { soname: "libmissing.so.1", path: null, notFound: true },
        ]),
        readelf: READELF_OK("$ORIGIN", null, ["libmpv.so.2"]),
      },
      "libmpv.so.2": {
        ldd: LDD_OK([
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        readelf: READELF_OK(null, "$ORIGIN", ["libc.so.6"]),
      },
    });

    const result = runVerify({
      manifest: { libraries: ["libmpv.so.2"] },
      runCommand,
    });

    expect(
      result.errors.some((e) =>
        /unresolved dependency: libmissing\.so\.1/.test(e),
      ),
    ).toBe(true);
  });

  it("reports a missing $ORIGIN rpath on a bundled library", () => {
    const runCommand = makeRunCommand({
      [ADDON]: {
        ldd: LDD_OK([
          {
            soname: "libmpv.so.2",
            path: path.join(bundle, "libmpv.so.2"),
            notFound: false,
          },
        ]),
        readelf: READELF_OK("$ORIGIN", null, ["libmpv.so.2"]),
      },
      "libmpv.so.2": {
        ldd: LDD_OK([
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        // No RPATH/RUNPATH at all.
        readelf: READELF_OK(null, null, ["libc.so.6"]),
      },
    });

    const result = runVerify({
      manifest: { libraries: ["libmpv.so.2"] },
      runCommand,
    });

    expect(
      result.errors.some((e) =>
        /libmpv\.so\.2 is missing a \$ORIGIN rpath\/RUNPATH/.test(e),
      ),
    ).toBe(true);
  });

  it("reports libmpv resolving outside the bundle (system path)", () => {
    const runCommand = makeRunCommand({
      [ADDON]: {
        ldd: LDD_OK([
          {
            soname: "libmpv.so.2",
            // Resolves to a system path, not the bundle.
            path: "/usr/lib/x86_64-linux-gnu/libmpv.so.2",
            notFound: false,
          },
        ]),
        readelf: READELF_OK("$ORIGIN", null, ["libmpv.so.2"]),
      },
      "libmpv.so.2": {
        ldd: LDD_OK([
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        readelf: READELF_OK(null, "$ORIGIN", ["libc.so.6"]),
      },
    });

    const result = runVerify({
      manifest: { libraries: ["libmpv.so.2"] },
      runCommand,
    });

    expect(
      result.errors.some((e) =>
        /libmpv dependency resolves outside the \$ORIGIN bundle/.test(e),
      ),
    ).toBe(true);
  });

  it("reports when the addon has no libmpv dependency at all", () => {
    const runCommand = makeRunCommand({
      [ADDON]: {
        ldd: LDD_OK([
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        readelf: READELF_OK("$ORIGIN", null, ["libc.so.6"]),
      },
      "libmpv.so.2": {
        ldd: LDD_OK([
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        readelf: READELF_OK(null, "$ORIGIN", ["libc.so.6"]),
      },
    });

    const result = runVerify({
      manifest: { libraries: ["libmpv.so.2"] },
      runCommand,
    });

    expect(
      result.errors.some((e) =>
        /does not declare a libmpv\.so dependency/.test(e),
      ),
    ).toBe(true);
  });

  it("accepts a multi-path rpath that contains a $ORIGIN segment", () => {
    // RUNPATH "$ORIGIN:/opt/lib" should still be accepted.
    const runCommand = makeRunCommand({
      [ADDON]: {
        ldd: LDD_OK([
          {
            soname: "libmpv.so.2",
            path: path.join(bundle, "libmpv.so.2"),
            notFound: false,
          },
        ]),
        readelf: READELF_OK(null, "$ORIGIN:/opt/lib", ["libmpv.so.2"]),
      },
      "libmpv.so.2": {
        ldd: LDD_OK([
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        readelf: READELF_OK(null, "$ORIGIN", ["libc.so.6"]),
      },
    });

    const result = runVerify({
      manifest: { libraries: ["libmpv.so.2"] },
      runCommand,
    });

    expect(result.errors).toEqual([]);
  });

  it("rejects an rpath that does not contain $ORIGIN", () => {
    const runCommand = makeRunCommand({
      [ADDON]: {
        ldd: LDD_OK([
          {
            soname: "libmpv.so.2",
            // Would resolve to system because rpath lacks $ORIGIN.
            path: "/usr/lib/libmpv.so.2",
            notFound: false,
          },
        ]),
        readelf: READELF_OK(null, "/usr/lib", ["libmpv.so.2"]),
      },
      "libmpv.so.2": {
        ldd: LDD_OK([
          {
            soname: "libc.so.6",
            path: "/lib/x86_64-linux-gnu/libc.so.6",
            notFound: false,
          },
        ]),
        readelf: READELF_OK(null, "/usr/lib", ["libc.so.6"]),
      },
    });

    const result = runVerify({
      manifest: { libraries: ["libmpv.so.2"] },
      runCommand,
    });

    expect(
      result.errors.some((e) =>
        /aonsoku_libmpv\.node is missing a \$ORIGIN rpath\/RUNPATH/.test(e),
      ),
    ).toBe(true);
    expect(
      result.errors.some((e) =>
        /libmpv dependency resolves outside the \$ORIGIN bundle/.test(e),
      ),
    ).toBe(true);
  });
});
