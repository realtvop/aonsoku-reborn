import { createHash } from "node:crypto";
import type {
  APIRequestOptions,
  APIResponse,
  LoginOptions,
  LoginResult,
  PingOptions,
  PingResult,
  ServerInfoResult,
  StoreCredentialsOptions,
  StoredCredentials,
} from "@aonsoku/capacitor-native/bridge";
import { AonsokuStore } from "../../core/store";
import { subsonicFetch } from "./http-agent";

const APP_NAME = "Aonsoku";
const DEFAULT_VERSION = "1.16.0";
const TOKEN_SALT = "40n50kuPl4y3r";

type CredentialStore = { credentials?: StoredCredentials };

function normalizeServerUrl(url: string): string {
  return url.replace(/\/+$/, "");
}

function encodePassword(password: string): string {
  return `enc:${Buffer.from(password, "utf8").toString("hex")}`;
}

function tokenFor(password: string): string {
  return createHash("md5").update(`${password}${TOKEN_SALT}`).digest("hex");
}

function versionNumber(version: string): number {
  return Number.parseInt(version.replaceAll(".", ""), 10) || 1160;
}

export class DesktopNativeBridgeService {
  private readonly store = new AonsokuStore<CredentialStore>({
    name: "native-credentials",
  });

  storeCredentials(options: StoreCredentialsOptions): void {
    const existing = this.getCredentials();
    const password = options.password || existing?.password;
    if (!password)
      throw new Error("Missing password and no credentials stored");
    this.store.set("credentials", {
      ...options,
      serverUrl: normalizeServerUrl(options.serverUrl),
      password,
    });
  }

  getCredentials(): StoredCredentials | null {
    return this.store.get("credentials") ?? null;
  }

  clearCredentials(): void {
    this.store.delete("credentials");
  }

  hasCredentials(): { stored: boolean } {
    return { stored: this.getCredentials() !== null };
  }

  async login(options: LoginOptions): Promise<LoginResult> {
    const urls: Array<{ url: string; type: "primary" | "fallback" }> = [
      { url: normalizeServerUrl(options.url), type: "primary" },
    ];
    if (options.fallbackUrl) {
      urls.push({
        url: normalizeServerUrl(options.fallbackUrl),
        type: "fallback",
      });
    }

    for (const target of urls) {
      for (const authType of ["token", "password"] as const) {
        const password =
          authType === "token"
            ? tokenFor(options.password)
            : encodePassword(options.password);
        const ping = await this.ping({
          url: target.url,
          username: options.username,
          password,
          authType,
        });
        if (!ping.reachable) continue;

        const info = await this.queryServerInfo({ url: target.url });
        this.storeCredentials({
          serverUrl: target.url,
          fallbackUrl: options.fallbackUrl,
          username: options.username,
          password,
          authType,
          protocolVersion: info.protocolVersion,
          serverType: info.serverType,
        });
        return {
          success: true,
          authType,
          protocolVersion: info.protocolVersion,
          serverType: info.serverType,
          activeUrl: target.url,
          activeServerType: target.type,
          password,
        };
      }
    }

    return { success: false, error: "Unable to authenticate with the server" };
  }

  async ping(options: PingOptions): Promise<PingResult> {
    try {
      await this.performRequest(
        {
          serverUrl: normalizeServerUrl(options.url),
          username: options.username,
          password: options.password,
          authType: options.authType,
          protocolVersion: DEFAULT_VERSION,
          serverType: "subsonic",
        },
        { path: "/ping.view" },
      );
      return { reachable: true };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message.startsWith("auth_failed")) {
        return { reachable: false, error: "auth_failed" };
      }
      if (message.startsWith("network_unreachable")) {
        return { reachable: false, error: "network_unreachable" };
      }
      return { reachable: false, error: "server_error" };
    }
  }

  async queryServerInfo(options: { url: string }): Promise<ServerInfoResult> {
    const probe: StoredCredentials = {
      serverUrl: normalizeServerUrl(options.url),
      username: "probe",
      password: tokenFor("probe"),
      authType: "token",
      protocolVersion: DEFAULT_VERSION,
      serverType: "subsonic",
    };
    try {
      const response = await this.performRequest(probe, {
        path: "/ping.view",
      });
      const version = String(response.data.version ?? DEFAULT_VERSION);
      return {
        protocolVersion: version,
        protocolVersionNumber: versionNumber(version),
        serverType: String(response.data.type ?? "subsonic").toLowerCase(),
      };
    } catch {
      return {
        protocolVersion: DEFAULT_VERSION,
        protocolVersionNumber: versionNumber(DEFAULT_VERSION),
        serverType: "subsonic",
      };
    }
  }

  async request(options: APIRequestOptions): Promise<APIResponse> {
    const credentials = this.getCredentials();
    if (!credentials) throw new Error("missing_credentials: No credentials");
    return this.performRequest(credentials, options);
  }

  async downloadBinary(
    path: string,
    query: Record<string, string | number>,
  ): Promise<{ data: Buffer; contentType: string }> {
    const credentials = this.getCredentials();
    if (!credentials) throw new Error("missing_credentials: No credentials");
    const url = this.buildUrl(credentials, { path, query });
    let response: Response;
    try {
      response = await subsonicFetch(url, {
        signal: AbortSignal.timeout(30_000),
      });
    } catch (error) {
      throw new Error(
        `network_unreachable: ${error instanceof Error ? error.message : error}`,
      );
    }
    if (!response.ok) throw new Error(`http_error: HTTP ${response.status}`);
    return {
      data: Buffer.from(await response.arrayBuffer()),
      contentType:
        response.headers.get("content-type") ?? "application/octet-stream",
    };
  }

  getMediaUrl(path: string, query: Record<string, string | number>): URL {
    const credentials = this.getCredentials();
    if (!credentials) throw new Error("missing_credentials: No credentials");
    return this.buildUrl(credentials, { path, query });
  }

  private async performRequest(
    credentials: StoredCredentials,
    options: APIRequestOptions,
  ): Promise<APIResponse> {
    const url = this.buildUrl(credentials, options);
    let response: Response;
    try {
      response = await subsonicFetch(url, {
        method: options.method ?? "GET",
        body: options.body,
        signal: AbortSignal.timeout(30_000),
      });
    } catch (error) {
      throw new Error(
        `network_unreachable: ${error instanceof Error ? error.message : error}`,
      );
    }
    if (!response.ok) {
      throw new Error(`http_error: HTTP ${response.status}`);
    }

    let json: Record<string, unknown>;
    try {
      json = (await response.json()) as Record<string, unknown>;
    } catch {
      throw new Error("parse_error: Failed to parse JSON response");
    }
    const data = json["subsonic-response"] as
      | Record<string, unknown>
      | undefined;
    if (!data) throw new Error("parse_error: Missing subsonic response");
    if (data.status === "failed") {
      const detail = data.error as
        | { code?: number; message?: string }
        | undefined;
      const prefix =
        detail?.code === 40 || detail?.code === 41
          ? "auth_failed"
          : "server_error";
      throw new Error(`${prefix}: ${detail?.message ?? "Request failed"}`);
    }
    return {
      count: Number.parseInt(response.headers.get("x-total-count") ?? "0", 10),
      data,
    };
  }

  private buildUrl(
    credentials: StoredCredentials,
    options: Pick<APIRequestOptions, "path" | "query">,
  ): URL {
    const pathAndQuery = options.path.replace(/^\//, "").split("?", 2);
    const url = new URL(
      `${normalizeServerUrl(credentials.serverUrl)}/rest/${pathAndQuery[0]}`,
    );
    if (pathAndQuery[1]) {
      for (const [key, value] of new URLSearchParams(pathAndQuery[1])) {
        url.searchParams.append(key, value);
      }
    }
    url.searchParams.set("u", credentials.username);
    if (credentials.authType === "token") {
      url.searchParams.set("t", credentials.password ?? "");
      url.searchParams.set("s", TOKEN_SALT);
    } else {
      url.searchParams.set("p", credentials.password ?? "");
    }
    url.searchParams.set("v", credentials.protocolVersion || DEFAULT_VERSION);
    url.searchParams.set("c", APP_NAME);
    url.searchParams.set("f", "json");
    for (const [key, value] of Object.entries(options.query ?? {})) {
      url.searchParams.set(key, String(value));
    }
    return url;
  }
}
