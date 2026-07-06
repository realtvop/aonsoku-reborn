// Coordination HTTP client (design §6, §8).
// Handles auth flow, token refresh, device management, and history sync.

import { AuthType } from "@/types/serverConfig";
import { saltWord } from "@/utils/salt";
import type {
  AccountId,
  ChallengeRequest,
  ChallengeResponse,
  DeviceDto,
  DeviceId,
  HistoryOperationInput,
  HistoryPullResponse,
  HistoryPushResponse,
  LegacyImportRequest,
  LegacyImportResponse,
  RegisterRequest,
  RegisterResponse,
  TokenRefreshRequest,
  TokenRefreshResponse,
  WsTicketResponse,
} from "./types";

export interface CoordinationCredentials {
  identityUrl: string;
  username: string;
  password: string;
  authType: AuthType | null;
}

export type CoordinationRecoveryProvider = () =>
  | CoordinationCredentials
  | null
  | Promise<CoordinationCredentials | null>;

export interface StoredDeviceTokens {
  deviceId: DeviceId;
  accountId: AccountId;
  accessToken: string;
  refreshToken: string;
  accessTokenExpiresAt: number;
  historyLimit: number;
}

export class CoordinationHttpClient {
  private baseUrl: string;
  private tokens: StoredDeviceTokens | null = null;
  private refreshPromise: Promise<void> | null = null;

  constructor(
    readonly baseUrl: string,
    private readonly fetchImpl: typeof fetch = fetch.bind(globalThis),
    private readonly onTokensUpdated?: (
      tokens: StoredDeviceTokens | null,
    ) => Promise<void> | void,
    private readonly getRecoveryCredentials?: CoordinationRecoveryProvider,
  ) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
  }

  setTokens(tokens: StoredDeviceTokens | null) {
    this.tokens = tokens;
  }

  getTokens(): StoredDeviceTokens | null {
    return this.tokens;
  }

  private authHeaders(): Record<string, string> {
    if (!this.tokens?.accessToken) return {};
    return { Authorization: `Bearer ${this.tokens.accessToken}` };
  }

  private async request<T>(
    path: string,
    options: RequestInit = {},
    requireAuth = true,
  ): Promise<T> {
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      ...(requireAuth ? this.authHeaders() : {}),
      ...(options.headers as Record<string, string>),
    };
    const resp = await this.fetchImpl(`${this.baseUrl}${path}`, {
      ...options,
      headers,
    });
    if (resp.status === 401 && requireAuth && this.tokens?.refreshToken) {
      await this.ensureValidAccessToken();
      return this.request<T>(path, options, requireAuth);
    }
    if (!resp.ok) {
      const body = await resp
        .json()
        .catch(() => ({ code: "internal", reason: resp.statusText }));
      const error = new CoordinationApiError(
        body.code ?? "internal",
        body.reason ?? "unknown error",
        resp.status,
      );
      throw error;
    }
    if (resp.status === 204) return undefined as T;
    return resp.json() as Promise<T>;
  }

  async ensureValidAccessToken(): Promise<void> {
    if (this.refreshPromise) {
      await this.refreshPromise;
      return;
    }
    if (!this.tokens) return;
    const now = Date.now();
    if (this.tokens.accessTokenExpiresAt - now > 60_000) return;
    this.refreshPromise = this.refreshTokens();
    try {
      await this.refreshPromise;
    } finally {
      this.refreshPromise = null;
    }
  }

  private async refreshTokens(): Promise<void> {
    if (!this.tokens) return;
    const req: TokenRefreshRequest = {
      deviceId: this.tokens.deviceId,
      refreshToken: this.tokens.refreshToken,
    };
    try {
      const resp = await this.requestTokenRefresh(req);
      await this.applyTokenRefreshResponse(resp);
    } catch (e) {
      if (e instanceof CoordinationApiError) {
        if (e.code === "device_revoked") {
          this.tokens = null;
          this.onTokensUpdated?.(null);
        } else if (e.code === "authentication_failed") {
          await this.recoverTokens(req);
          return;
        }
      }
      throw e;
    }
  }

  private async requestTokenRefresh(
    req: TokenRefreshRequest,
  ): Promise<TokenRefreshResponse> {
    return this.request<TokenRefreshResponse>(
      "/v1/auth/token",
      {
        method: "POST",
        body: JSON.stringify(req),
      },
      false,
    );
  }

  private async recoverTokens(req: TokenRefreshRequest): Promise<void> {
    const creds = await this.getRecoveryCredentials?.();
    if (!creds) {
      throw new CoordinationApiError(
        "authentication_failed",
        "invalid refresh token",
        401,
      );
    }
    try {
      const challenge = await this.requestChallenge({
        identityUrl: creds.identityUrl,
        username: creds.username,
      });
      const proof = buildSubsonicProof(creds);
      const resp = await this.requestTokenRefresh({
        ...req,
        challengeId: challenge.challengeId,
        identityUrl: creds.identityUrl,
        username: creds.username,
        authMode: proof.authMode,
        token: proof.token,
        salt: proof.salt,
        password: proof.password,
      });
      await this.applyTokenRefreshResponse(resp);
    } catch (e) {
      if (e instanceof CoordinationApiError && e.code === "device_revoked") {
        this.tokens = null;
        this.onTokensUpdated?.(null);
      }
      throw e;
    }
  }

  private async applyTokenRefreshResponse(
    resp: TokenRefreshResponse,
  ): Promise<void> {
    if (!this.tokens) return;
    this.tokens = {
      ...this.tokens,
      accessToken: resp.accessToken,
      refreshToken: resp.refreshToken,
      accessTokenExpiresAt: Date.now() + resp.expiresIn * 1000,
    };
    await this.onTokensUpdated?.(this.tokens);
  }

  async requestChallenge(req: ChallengeRequest): Promise<ChallengeResponse> {
    return this.request<ChallengeResponse>(
      "/v1/auth/challenge",
      {
        method: "POST",
        body: JSON.stringify(req),
      },
      false,
    );
  }

  async register(req: RegisterRequest): Promise<RegisterResponse> {
    const resp = await this.request<RegisterResponse>(
      "/v1/auth/register",
      {
        method: "POST",
        body: JSON.stringify(req),
      },
      false,
    );
    this.tokens = {
      deviceId: resp.deviceId,
      accountId: resp.accountId,
      accessToken: resp.accessToken,
      refreshToken: resp.refreshToken,
      accessTokenExpiresAt: Date.now() + resp.expiresIn * 1000,
      historyLimit: resp.historyLimit,
    };
    this.onTokensUpdated?.(this.tokens);
    return resp;
  }

  async getWsTicket(): Promise<WsTicketResponse> {
    await this.ensureValidAccessToken();
    return this.request<WsTicketResponse>("/v1/auth/ws-ticket", {
      method: "POST",
      body: JSON.stringify({}),
    });
  }

  async renameDevice(id: DeviceId, name: string): Promise<DeviceDto> {
    await this.ensureValidAccessToken();
    return this.request<DeviceDto>(`/v1/devices/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ name }),
    });
  }

  /// List devices for the current account (design §6.3, §12.1). Used by the
  /// stale-epoch retry path to refresh the expected generation when no
  /// cached snapshot is available.
  async listDevices(): Promise<DeviceDto[]> {
    await this.ensureValidAccessToken();
    return this.request<DeviceDto[]>("/v1/devices");
  }

  async revokeDevice(id: DeviceId): Promise<void> {
    await this.ensureValidAccessToken();
    await this.request<void>(`/v1/devices/${id}`, { method: "DELETE" });
  }

  async deleteAccount(): Promise<void> {
    await this.ensureValidAccessToken();
    await this.request<void>("/v1/account", { method: "DELETE" });
  }

  async pullHistory(
    afterRevision: number,
    limit = 100,
  ): Promise<HistoryPullResponse> {
    await this.ensureValidAccessToken();
    return this.request<HistoryPullResponse>(
      `/v1/history?after_revision=${afterRevision}&limit=${limit}`,
    );
  }

  async pushHistory(
    operations: HistoryOperationInput[],
  ): Promise<HistoryPushResponse> {
    await this.ensureValidAccessToken();
    return this.request<HistoryPushResponse>("/v1/history", {
      method: "POST",
      body: JSON.stringify({ operations }),
    });
  }

  async legacyImport(req: LegacyImportRequest): Promise<LegacyImportResponse> {
    await this.ensureValidAccessToken();
    return this.request<LegacyImportResponse>("/v1/history/legacy-import", {
      method: "POST",
      body: JSON.stringify(req),
    });
  }
}

export class CoordinationApiError extends Error {
  constructor(
    readonly code: string,
    reason: string,
    readonly httpStatus: number,
  ) {
    super(reason);
    this.name = "CoordinationApiError";
  }
}

/// Build the Subsonic proof for credential verification (design §6.2).
/// PASSWORD mode: client holds reversible enc: credentials, generates a
/// fresh random-salt token. TOKEN mode: client only has the fixed-salt token,
/// sends the existing u/t/s combination.
export function buildSubsonicProof(creds: CoordinationCredentials): {
  authMode: "token" | "password";
  token?: string;
  salt?: string;
  password?: string;
} {
  if (creds.authType === AuthType.TOKEN) {
    return {
      authMode: "token",
      token: creds.password,
      salt: saltWord,
    };
  }
  if (creds.authType === AuthType.PASSWORD) {
    return {
      authMode: "password",
      password: creds.password,
    };
  }
  throw new Error("coordination: no valid auth type configured");
}
