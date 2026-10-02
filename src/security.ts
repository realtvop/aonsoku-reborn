import type { CoordinationErrorCode } from "./protocol";

export interface Env {
  ACCOUNTS: DurableObjectNamespace;
  STABLE_KEY: string;
  // Exact HTTPS origins controlled/trusted by the operator. No wildcard.
  ALLOWED_IDENTITY_ORIGINS: string;
  ENABLE_OFFLINE_HANDOFF?: boolean | string;
  MAX_DEVICES?: number | string;
}

export function booleanSetting(value: unknown, fallback: boolean): boolean {
  if (value === undefined || value === null || value === "") return fallback;
  if (typeof value === "boolean") return value;
  if (value === "true") return true;
  if (value === "false") return false;
  return fallback;
}

export function integerSetting(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isSafeInteger(parsed) && parsed >= min && parsed <= max
    ? parsed
    : fallback;
}

export class ApiError extends Error {
  constructor(
    readonly code: CoordinationErrorCode,
    message: string,
    readonly status = 400,
  ) {
    super(message);
  }
}

export function fail(
  code: CoordinationErrorCode,
  reason: string,
  status = 400,
): never {
  throw new ApiError(code, reason, status);
}

export function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Authorization, Content-Type",
      "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
      "Cache-Control": "no-store",
    },
  });
}

export function errorResponse(error: unknown): Response {
  if (error instanceof ApiError) {
    return json({ code: error.code, reason: error.message }, error.status);
  }
  // Never include request URLs or credentials in errors/logs.
  return json({ code: "internal", reason: "internal server error" }, 500);
}

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("bad_message", "expected JSON object");
  }
  return value as Record<string, unknown>;
}

export function string(value: unknown, max = 4096): string {
  if (typeof value !== "string" || !value || value.length > max) {
    fail("bad_message", "invalid string");
  }
  return value;
}

export function integer(
  value: unknown,
  min = 0,
  max = Number.MAX_SAFE_INTEGER,
) {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < min ||
    value > max
  ) {
    fail("bad_message", "invalid integer");
  }
  return value;
}

export function uuid(value: unknown): string {
  const id = string(value, 36);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)
  ) {
    fail("bad_message", "invalid UUID");
  }
  return id.toLowerCase();
}

export const MAX_BYTES = 524288;

export async function body(request: Request): Promise<Record<string, unknown>> {
  if (Number(request.headers.get("Content-Length")) > MAX_BYTES) {
    fail("payload_too_large", "request too large", 413);
  }
  const reader = request.body?.getReader();
  let size = 0;
  const chunks: Uint8Array[] = [];
  if (reader) {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BYTES) {
        await reader.cancel();
        fail("payload_too_large", "request too large", 413);
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return object(JSON.parse(new TextDecoder().decode(bytes)));
  } catch (error) {
    if (error instanceof ApiError) throw error;
    fail("bad_message", "invalid JSON");
  }
}

const encoder = new TextEncoder();
function b64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}
function unb64(value: string): Uint8Array {
  return Uint8Array.from(
    atob(value.replaceAll("-", "+").replaceAll("_", "/")),
    (c) => c.charCodeAt(0),
  );
}
async function key(secret: string) {
  if (!secret || secret.length < 32)
    fail("not_ready", "STABLE_KEY must have at least 32 characters", 503);
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}
export async function sign(secret: string, claims: Record<string, unknown>) {
  const payload = encoder.encode(JSON.stringify(claims));
  const signature = await crypto.subtle.sign(
    "HMAC",
    await key(secret),
    payload,
  );
  return `${b64(payload)}.${b64(new Uint8Array(signature))}`;
}
export async function verify(
  secret: string,
  token: string,
  kind?: string,
  allowExpired = false,
) {
  try {
    if (token.length > 4096) throw new Error();
    const parts = token.split(".");
    if (parts.length !== 2) throw new Error();
    const payload = unb64(parts[0]);
    if (
      !(await crypto.subtle.verify(
        "HMAC",
        await key(secret),
        unb64(parts[1]),
        payload,
      ))
    )
      throw new Error();
    const claims = object(JSON.parse(new TextDecoder().decode(payload)));
    uuid(claims.account_id);
    if (kind ? claims.kind !== kind : claims.kind !== undefined)
      throw new Error();
    if (
      typeof claims.exp !== "number" ||
      !Number.isFinite(claims.exp) ||
      (!allowExpired && claims.exp < Date.now() / 1000)
    )
      throw new Error();
    return claims;
  } catch (error) {
    if (error instanceof ApiError && error.code === "not_ready") throw error;
    fail("authentication_failed", "invalid or expired token", 401);
  }
}
export async function hash(value: string) {
  return hex(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(value)),
    ),
  );
}
function hex(bytes: Uint8Array) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
export function canonicalUser(value: unknown) {
  return string(value).trim().normalize("NFKC").toLowerCase();
}
export function identity(value: unknown, env: Env) {
  let url: URL;
  try {
    url = new URL(string(value));
  } catch {
    fail("invalid_identity", "invalid identity URL");
  }
  if (
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    fail(
      "invalid_identity",
      "identity must be HTTPS without credentials, query or fragment",
    );
  }
  const origins =
    env.ALLOWED_IDENTITY_ORIGINS?.split(",")
      .map((v) => v.trim())
      .filter(Boolean) ?? [];
  if (!origins.includes(url.origin))
    fail("ssrf_blocked", "identity origin is not allowed", 403);
  url.pathname = url.pathname.replace(/\/+$/, "") || "/";
  return url.href.replace(/\/$/, url.pathname === "/" ? "/" : "");
}
export async function accountId(secret: string, url: string, user: string) {
  const bytes = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      await key(secret),
      encoder.encode(`${url}||${user}`),
    ),
  );
  // Deterministic account routing, without an account directory or plaintext identity index.
  bytes[6] = (bytes[6] & 15) | 80;
  bytes[8] = (bytes[8] & 63) | 128;
  const h = hex(bytes.slice(0, 16));
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export async function verifyCredentials(
  env: Env,
  input: Record<string, unknown>,
) {
  const base = identity(input.identityUrl, env);
  const url = new URL(`${base.replace(/\/$/, "")}/rest/ping.view`);
  url.search = new URLSearchParams({
    u: string(input.username),
    v: "1.16.1",
    c: "aonsoku-coordination",
    f: "json",
  }).toString();
  if (input.authMode === "token") {
    url.searchParams.set("t", string(input.token));
    url.searchParams.set("s", string(input.salt));
  } else if (input.authMode === "password") {
    url.searchParams.set("p", string(input.password));
  } else fail("bad_message", "authMode must be token or password");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
    // Workers fetch cannot reproduce reqwest's DNS/IP pinning. Restrict verification
    // to operator-trusted exact origins and reject all redirects instead.
    const response = await fetch(url, {
      redirect: "manual",
      signal: controller.signal,
    });
    if (!response.ok)
      fail("verification_failed", "identity verification failed", 401);
    const reader = response.body?.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    if (!reader) fail("verification_failed", "empty identity response", 401);
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 65536) {
        await reader.cancel();
        fail("verification_failed", "identity response too large", 401);
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    const data = object(JSON.parse(new TextDecoder().decode(bytes)));
    if (object(data["subsonic-response"]).status !== "ok")
      fail("verification_failed", "identity rejected credentials", 401);
  } catch (error) {
    if (error instanceof ApiError) throw error;
    fail("verification_failed", "identity verification failed", 401);
  } finally {
    // A live timeout callback prevents DO hibernation even after a successful fetch.
    clearTimeout(timeout);
  }
}
