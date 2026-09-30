import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { deploy, normalizeOrigins } from "./deploy.mjs";

const identity = JSON.stringify({
  accounts: [{ id: "account-1", name: "Test" }],
});

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "coordination-deploy-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(
    join(root, "wrangler.jsonc"),
    JSON.stringify({
      name: "aonsoku-coordination",
      main: "src/index.ts",
      migrations: [{ tag: "v2" }],
    }),
  );
  return root;
}

test("normalizes server base paths and rejects unsafe identities", () => {
  assert.equal(
    normalizeOrigins(
      "https://music.test/navidrome/,https://music.test,https://other.test:8443",
    ),
    "https://music.test,https://other.test:8443",
  );
  for (const value of [
    "",
    "http://music.test",
    "https://user:pass@music.test",
    "https://music.test/?token=secret",
    "https://music.test/#fragment",
  ]) {
    assert.throws(() => normalizeOrigins(value));
  }
});

test("first deploy uploads a generated key atomically and retries reuse it", async (t) => {
  const root = await fixture(t);
  const calls = [];
  const answers = ["", "https://music.test/subsonic"];
  const run = async (args) => {
    calls.push(args);
    if (args[0] === "whoami") return identity;
    if (args[0] === "secret")
      throw new Error('Worker "aonsoku-coordination" not found.');
    if (
      args[0] === "deploy" &&
      calls.filter((call) => call[0] === "deploy").length === 1
    )
      throw new Error("upload failed");
    return "";
  };
  const options = {
    root,
    run,
    ask: async () => answers.shift(),
    log: () => {},
  };
  await assert.rejects(deploy(options), /upload failed/);
  const backup = await readFile(join(root, ".deploy.secrets.json"), "utf8");
  assert.equal(JSON.parse(backup).STABLE_KEY.length, 64);
  await deploy({
    ...options,
    ask: async () => {
      throw new Error("unexpected prompt");
    },
  });
  assert.equal(
    await readFile(join(root, ".deploy.secrets.json"), "utf8"),
    backup,
  );
  const config = JSON.parse(
    await readFile(join(root, "wrangler.deploy.json"), "utf8"),
  );
  assert.equal(config.account_id, "account-1");
  assert.equal(config.vars.ALLOWED_IDENTITY_ORIGINS, "https://music.test");
  assert.ok(calls.at(-1).includes("--secrets-file"));
});

test("updates preserve the remote secret and use current migrations", async (t) => {
  const root = await fixture(t);
  await writeFile(
    join(root, "wrangler.deploy.json"),
    JSON.stringify({
      name: "existing",
      account_id: "account-1",
      vars: { ALLOWED_IDENTITY_ORIGINS: "https://music.test" },
      migrations: [{ tag: "old" }],
    }),
  );
  const calls = [];
  await deploy({
    root,
    log: () => {},
    ask: async () => {
      throw new Error("unexpected prompt");
    },
    run: async (args) => {
      calls.push(args);
      if (args[0] === "whoami") return identity;
      if (args[0] === "secret") return '[{"name":"STABLE_KEY"}]';
      return "";
    },
  });
  assert.ok(!calls.at(-1).includes("--secrets-file"));
  await assert.rejects(readFile(join(root, ".deploy.secrets.json")), {
    code: "ENOENT",
  });
  const config = JSON.parse(
    await readFile(join(root, "wrangler.deploy.json"), "utf8"),
  );
  assert.deepEqual(config.migrations, [{ tag: "v2" }]);
});

test("permission failures never generate a new secret or deploy", async (t) => {
  const root = await fixture(t);
  const answers = ["", "https://music.test"];
  const calls = [];
  await assert.rejects(
    deploy({
      root,
      log: () => {},
      ask: async () => answers.shift(),
      run: async (args) => {
        calls.push(args);
        if (args[0] === "whoami") return identity;
        throw new Error("Authentication error [code: 10000]");
      },
    }),
    /Authentication error/,
  );
  assert.ok(!calls.some((args) => args[0] === "deploy"));
  await assert.rejects(readFile(join(root, ".deploy.secrets.json")), {
    code: "ENOENT",
  });
});

test("login and multiple-account selection bind the chosen account", async (t) => {
  const root = await fixture(t);
  const answers = ["custom", "https://music.test", "2"];
  let authenticated = false;
  await deploy({
    root,
    log: () => {},
    ask: async () => answers.shift(),
    run: async (args) => {
      if (args[0] === "whoami") {
        if (!authenticated) throw new Error('{"loggedIn": false}');
        return JSON.stringify({
          accounts: [
            { id: "one", name: "One" },
            { id: "two", name: "Two" },
          ],
        });
      }
      if (args[0] === "login") {
        authenticated = true;
        return "";
      }
      if (args[0] === "secret") return '[{"name":"STABLE_KEY"}]';
      return "";
    },
  });
  const config = JSON.parse(
    await readFile(join(root, "wrangler.deploy.json"), "utf8"),
  );
  assert.equal(config.account_id, "two");
});
