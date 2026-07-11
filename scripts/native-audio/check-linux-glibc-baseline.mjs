#!/usr/bin/env node
/**
 * Static consistency check for the Linux native-audio glibc baseline.
 *
 * Verifies that the documented glibc baseline (currently glibc >= 2.35,
 * matching the Ubuntu 22.04 CI build environment) is consistently reflected
 * in:
 *   - forge.config.ts (MakerDeb depends / MakerRpm requires)
 *   - docs/native-audio-libmpv.md
 *   - .github/actions/setup-native-audio/action.yml
 *   - Linux CI workflow files
 *
 * This check does not need a Linux build environment or ELF files; it is a
 * textual consistency check so it can run on any development machine.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const BASELINE = "2.35";
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "../..");

const files = {
  forge: "forge.config.ts",
  docs: "docs/native-audio-libmpv.md",
  action: ".github/actions/setup-native-audio/action.yml",
  workflows: [
    ".github/workflows/build.yml",
    ".github/workflows/release.yml",
    ".github/workflows/nightly.yml",
  ],
};

function main() {
  const errors = [];
  const forge = readFile(files.forge);
  const docs = readFile(files.docs);
  const action = readFile(files.action);

  const debDepends = `depends: ["libc6 (>= ${BASELINE})"]`;
  const rpmRequires = `requires: ["glibc >= ${BASELINE}"]`;

  if (!forge.includes(debDepends)) {
    errors.push(
      `${files.forge}: MakerDeb depends should include "${debDepends}"`,
    );
  }

  if (!forge.includes(rpmRequires)) {
    errors.push(
      `${files.forge}: MakerRpm requires should include "${rpmRequires}"`,
    );
  }

  if (!docs.includes(`glibc >= ${BASELINE}`)) {
    errors.push(`${files.docs}: should document glibc >= ${BASELINE} baseline`);
  }

  if (!docs.includes("Ubuntu 22.04")) {
    errors.push(
      `${files.docs}: should mention the Ubuntu 22.04 build environment`,
    );
  }

  if (!action.includes(`glibc >= ${BASELINE}`)) {
    errors.push(
      `${files.action}: should mention the glibc >= ${BASELINE} baseline`,
    );
  }

  for (const workflow of files.workflows) {
    const contents = readFile(workflow);
    if (!contents.includes("ubuntu-22.04")) {
      errors.push(`${workflow}: Linux matrix should use ubuntu-22.04 runners`);
    }
    if (
      !contents.includes(`glibc >= ${BASELINE}`) &&
      !contents.includes(`glibc ${BASELINE}`)
    ) {
      errors.push(
        `${workflow}: should mention the glibc >= ${BASELINE} baseline in comments or release notes`,
      );
    }
  }

  if (errors.length > 0) {
    console.error("Linux glibc baseline consistency check failed:");
    for (const error of errors) {
      console.error(`  - ${error}`);
    }
    process.exit(1);
  }

  console.log(
    `Linux native-audio glibc baseline (${BASELINE}) is consistently documented.`,
  );
  console.log("Checked:");
  console.log(`  - ${files.forge}`);
  console.log(`  - ${files.docs}`);
  console.log(`  - ${files.action}`);
  for (const workflow of files.workflows) {
    console.log(`  - ${workflow}`);
  }
}

function readFile(relativePath) {
  return readFileSync(path.join(root, relativePath), "utf8");
}

main();
