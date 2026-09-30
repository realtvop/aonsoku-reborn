import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath, pathToFileURL } from "node:url";

const workerRoot = fileURLToPath(new URL("../", import.meta.url));
const require = createRequire(import.meta.url);
const wrangler = join(
  dirname(require.resolve("wrangler/package.json")),
  "bin/wrangler.js",
);

async function readJson(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return undefined;
    throw error;
  }
}

export function normalizeOrigins(input) {
  const origins = input.split(",").map((value) => {
    const url = new URL(value.trim());
    if (
      url.protocol !== "https:" ||
      url.username ||
      url.password ||
      url.search ||
      url.hash
    ) {
      throw new Error(
        "请输入可信的 HTTPS Navidrome/Subsonic 地址。禁止包含凭据、查询或片段。",
      );
    }
    return url.origin;
  });
  return [...new Set(origins)].join(",");
}

function runWrangler(args, { capture = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [wrangler, ...args], {
      cwd: workerRoot,
      env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
      stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
    });
    let output = "";
    let errors = "";
    if (capture) {
      child.stdout.on("data", (chunk) => {
        output += chunk;
      });
      child.stderr.on("data", (chunk) => {
        errors += chunk;
      });
    }
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(output);
      else
        reject(new Error(output + errors || `Wrangler 退出，状态码 ${code}`));
    });
  });
}

export async function deploy({
  root = workerRoot,
  run = runWrangler,
  ask,
  log = console.log,
} = {}) {
  const configPath = join(root, "wrangler.deploy.json");
  const secretsPath = join(root, ".deploy.secrets.json");
  const base = JSON.parse(await readFile(join(root, "wrangler.jsonc"), "utf8"));
  let saved = await readJson(configPath);
  if (!saved) {
    const name =
      (await ask(`Worker 名称 [${base.name}]: `)).trim() || base.name;
    if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(name)) {
      throw new Error("Worker 名称需为 1–63 个小写字母、数字或连字符。");
    }
    const origins = normalizeOrigins(
      await ask("Navidrome/Subsonic HTTPS 地址（多个地址用逗号分隔）: "),
    );
    saved = { name, vars: { ALLOWED_IDENTITY_ORIGINS: origins } };
  }

  let identity;
  try {
    identity = JSON.parse(await run(["whoami", "--json"], { capture: true }));
  } catch (error) {
    if (!/"loggedIn"\s*:\s*false/.test(error.message)) throw error;
    log("请在浏览器中登录 Cloudflare。");
    await run(["login"]);
    identity = JSON.parse(await run(["whoami", "--json"], { capture: true }));
  }
  if (!saved.account_id) {
    const accounts = identity.accounts ?? [];
    if (accounts.length === 0)
      throw new Error(
        "Cloudflare 未返回可用账号，请检查 API token 或登录权限。",
      );
    if (accounts.length === 1) saved.account_id = accounts[0].id;
    else {
      log(
        accounts
          .map(
            (account, index) => `${index + 1}. ${account.name} (${account.id})`,
          )
          .join("\n"),
      );
      const index = Number(await ask("选择 Cloudflare 账号编号: ")) - 1;
      if (!Number.isInteger(index) || !accounts[index])
        throw new Error("账号编号无效。");
      saved.account_id = accounts[index].id;
    }
  }

  // Reuse local deployment choices but take bindings/migrations from the current source.
  const config = {
    ...base,
    name: saved.name,
    account_id: saved.account_id,
    vars: { ...base.vars, ...saved.vars },
    workers_dev: true,
  };
  config.vars.ALLOWED_IDENTITY_ORIGINS = normalizeOrigins(
    config.vars.ALLOWED_IDENTITY_ORIGINS,
  );
  await writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`);
  log(`部署 ${config.name}，账号 ${config.account_id}`);
  let secrets;
  try {
    secrets = JSON.parse(
      await run(
        ["secret", "list", "--config", configPath, "--format", "json"],
        { capture: true },
      ),
    );
  } catch (error) {
    if (!error.message.includes(`Worker "${config.name}" not found.`))
      throw error;
    secrets = [];
  }
  const args = ["deploy", "--config", configPath];
  if (secrets.some((secret) => secret.name === "STABLE_KEY")) {
    log("保留线上 STABLE_KEY。");
  } else {
    let backup = await readJson(secretsPath);
    if (!backup) {
      backup = { STABLE_KEY: randomBytes(48).toString("base64url") };
      await writeFile(secretsPath, `${JSON.stringify(backup)}\n`, {
        mode: 0o600,
        flag: "wx",
      });
    }
    if (
      typeof backup.STABLE_KEY !== "string" ||
      backup.STABLE_KEY.length < 32
    ) {
      throw new Error("本地密钥备份无效，请恢复原 STABLE_KEY。");
    }
    args.push("--secrets-file", secretsPath);
    log(`密钥备份：${secretsPath}。请妥善保管，不要提交到 Git。`);
  }
  await run(args);
  log(
    "部署完成。将上方 workers.dev URL 填入 Aonsoku 协调服务设置，可访问 /readyz 检查状态。",
  );
}

if (
  process.argv[1] &&
  pathToFileURL(process.argv[1]).href === import.meta.url
) {
  const readline = createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  try {
    await deploy({ ask: (question) => readline.question(question) });
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    readline.close();
  }
}
