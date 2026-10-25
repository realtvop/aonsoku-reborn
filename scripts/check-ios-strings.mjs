#!/usr/bin/env node
// Checks that every translation key the native iOS app uses exists in the
// shared web strings (src/i18n/locales/en.json) or in the native-only
// strings (ios/native-locales/en.json), and that the native-only string
// files define the same keys.
//
// Usage: node scripts/check-ios-strings.mjs
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const sourceRoots = ["ios/Aonsoku", "ios/AonsokuKit/Sources"];
const nativeLocales = join(root, "ios/native-locales");

function flatten(object, prefix = "", keys = new Set()) {
  for (const [name, value] of Object.entries(object)) {
    const key = prefix ? `${prefix}.${name}` : name;
    if (value && typeof value === "object") {
      flatten(value, key, keys);
    } else {
      keys.add(key);
    }
  }
  return keys;
}

function readKeys(path) {
  return flatten(JSON.parse(readFileSync(path, "utf8")));
}

function swiftFiles(directory) {
  const files = [];
  for (const name of readdirSync(directory)) {
    const path = join(directory, name);
    if (statSync(path).isDirectory()) {
      files.push(...swiftFiles(path));
    } else if (name.endsWith(".swift")) {
      files.push(path);
    }
  }
  return files;
}

const webKeys = readKeys(join(root, "src/i18n/locales/en.json"));
const nativeKeys = readKeys(join(nativeLocales, "en.json"));
const known = new Set([...webKeys, ...nativeKeys]);
const namespaces = new Set(
  [...known].map((key) => key.split(".")[0]).concat("native"),
);

// String literals that name SF Symbols rather than translations.
const symbolContext = /(systemImage|systemName|placeholder):\s*$/;
const keyShape = /^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9_-]+)+$/;
// Versioned storage keys such as "settings.v1".
const storageKey = /\.v\d+$/;
const literal = /"((?:[^"\\]|\\.)*)"/g;

function exists(key) {
  return known.has(key) || known.has(`${key}_one`) || known.has(`${key}_other`);
}

const missing = [];
const dynamic = [];
const used = new Set();

for (const sourceRoot of sourceRoots) {
  for (const file of swiftFiles(join(root, sourceRoot))) {
    const lines = readFileSync(file, "utf8").split("\n");
    lines.forEach((line, index) => {
      if (line.trim().startsWith("//")) return;
      for (const match of line.matchAll(literal)) {
        const value = match[1];
        if (symbolContext.test(line.slice(0, match.index))) continue;
        const location = `${relative(root, file)}:${index + 1}`;
        if (value.includes("\\(")) {
          const head = value.split("\\(")[0];
          if (namespaces.has(head.split(".")[0]) && head.includes(".")) {
            dynamic.push(`${location}  ${value}`);
          }
          continue;
        }
        if (!keyShape.test(value) || storageKey.test(value)) continue;
        if (!namespaces.has(value.split(".")[0])) continue;
        used.add(value);
        if (!exists(value)) missing.push(`${location}  ${value}`);
      }
    });
  }
}

const problems = [...missing.map((entry) => `missing key: ${entry}`)];

for (const name of readdirSync(nativeLocales)) {
  if (!name.endsWith(".json") || name === "en.json") continue;
  const keys = readKeys(join(nativeLocales, name));
  for (const key of keys) {
    if (!nativeKeys.has(key)) {
      problems.push(`ios/native-locales/${name}: ${key} is not in en.json`);
    }
  }
}

const unused = [...nativeKeys].filter(
  (key) => !used.has(key) && !used.has(key.replace(/_(one|other)$/, "")),
);

for (const entry of dynamic) {
  console.log(`not checked (built at runtime): ${entry}`);
}
for (const key of unused) {
  console.log(`unused native key: ${key}`);
}
for (const problem of problems) {
  console.error(problem);
}

if (problems.length > 0) {
  process.exit(1);
}
console.log(`${used.size} keys checked.`);
