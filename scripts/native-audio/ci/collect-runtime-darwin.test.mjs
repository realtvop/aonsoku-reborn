import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

const collector = fileURLToPath(
  new URL("./collect-runtime-darwin.mjs", import.meta.url),
);
const directories = [];
// These integration tests compile dylibs and run Apple's linker/signing tools.
// Keep their budget local instead of relaxing ordinary unit-test deadlines.
const toolTimeout = 20_000;
const testTimeout = 30_000;

afterEach(() => {
  for (const directory of directories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

function run(command, args) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    timeout: toolTimeout,
  });
  if (result.error) throw result.error;
  expect(result.status, result.stderr).toBe(0);
  return result.stdout;
}

function fixture() {
  const directory = mkdtempSync(path.join(tmpdir(), "aonsoku-darwin-runtime-"));
  directories.push(directory);
  const prefix = path.join(directory, "brew");
  const lib = path.join(prefix, "lib");
  const cellar = path.join(prefix, "Cellar", "fixture", "1", "lib");
  mkdirSync(lib, { recursive: true });
  mkdirSync(cellar, { recursive: true });

  function compile(name, source, installName, options = []) {
    const sourcePath = path.join(directory, `${name}.c`);
    const library = path.join(cellar, `${name}.dylib`);
    writeFileSync(sourcePath, source);
    run("clang", [
      "-dynamiclib",
      sourcePath,
      "-o",
      library,
      "-Wl,-headerpad_max_install_names",
      "-install_name",
      installName,
      ...options,
    ]);
    return library;
  }

  const common = compile(
    "libcommon",
    "int common(void) { return 1; }",
    "@rpath/libcommon.dylib",
  );
  const decoder = compile(
    "libdecoder",
    "int common(void); int decode(void) { return common(); }",
    "@loader_path/libdecoder.dylib",
    [common, "-Wl,-rpath,@loader_path"],
  );
  const root = compile(
    "libmpv",
    "int decode(void); int mpv(void) { return decode(); }",
    "@rpath/libmpv.dylib",
    [decoder],
  );
  // Resolve @loader_path from the real binary, even through Homebrew symlinks.
  const rootLink = path.join(lib, "libmpv.dylib");
  symlinkSync(root, rootLink);
  return { directory, rootLink, common };
}

describe.skipIf(process.platform !== "darwin")(
  "macOS native runtime collection",
  () => {
    it("bundles and rewrites transitive loader-path and rpath dependencies", () => {
      const { directory, rootLink } = fixture();
      const staging = path.join(directory, "staging");
      const output = run(process.execPath, [
        collector,
        "--root",
        rootLink,
        "--staging",
        staging,
      ]);
      expect(output).toContain('"libcommon.dylib"');
      expect(
        run("otool", ["-L", path.join(staging, "libdecoder.dylib")]),
      ).toContain("@loader_path/libcommon.dylib");
      // Prove the staged closure loads after its Homebrew source disappears.
      rmSync(path.join(directory, "brew"), { recursive: true });
      const probe = path.join(directory, "probe.c");
      writeFileSync(
        probe,
        "#include <dlfcn.h>\nint main(int argc, char **argv) { return dlopen(argv[1], RTLD_NOW) ? 0 : 1; }",
      );
      run("clang", [probe, "-o", path.join(directory, "probe")]);
      run(path.join(directory, "probe"), [path.join(staging, "libmpv.dylib")]);
      expect(
        readFileSync(path.join(staging, "libcommon.dylib")).length,
      ).toBeGreaterThan(0);
    }, testTimeout);

    it("fails collection when a transitive dependency cannot be resolved", () => {
      const { directory, rootLink, common } = fixture();
      rmSync(common);
      const result = spawnSync(
        process.execPath,
        [
          collector,
          "--root",
          rootLink,
          "--staging",
          path.join(directory, "staging"),
        ],
        { encoding: "utf8", timeout: toolTimeout },
      );
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("Cannot resolve @rpath/libcommon.dylib");
    }, testTimeout);
  },
);
