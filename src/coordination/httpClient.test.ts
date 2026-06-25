import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import {
  CoordinationHttpClient,
  buildSubsonicProof,
  CoordinationApiError,
} from "./httpClient";
import { AuthType } from "@/types/serverConfig";

describe("buildSubsonicProof", () => {
  it("builds token proof for TOKEN mode", () => {
    const proof = buildSubsonicProof({
      identityUrl: "https://navidrome.example",
      username: "alice",
      password: "md5token",
      authType: AuthType.TOKEN,
    });
    expect(proof.authMode).toBe("token");
    expect(proof.token).toBe("md5token");
    expect(proof.salt).toBe("40n50kuPl4y3r");
  });

  it("builds password proof for PASSWORD mode", () => {
    const proof = buildSubsonicProof({
      identityUrl: "https://navidrome.example",
      username: "alice",
      password: "enc:616c696365",
      authType: AuthType.PASSWORD,
    });
    expect(proof.authMode).toBe("password");
    expect(proof.password).toBe("enc:616c696365");
  });

  it("throws for missing auth type", () => {
    expect(() =>
      buildSubsonicProof({
        identityUrl: "https://navidrome.example",
        username: "alice",
        password: "x",
        authType: null,
      }),
    ).toThrow();
  });
});

describe("CoordinationHttpClient", () => {
  let client: CoordinationHttpClient;
  let mockFetch: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockFetch = vi.fn();
    client = new CoordinationHttpClient(
      "https://coord.example",
      mockFetch as unknown as typeof fetch,
    );
    client.setTokens({
      deviceId: "dev-1",
      accountId: "acc-1",
      accessToken: "access-token",
      refreshToken: "refresh-token",
      accessTokenExpiresAt: Date.now() + 600_000,
      historyLimit: 100,
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("sends authorization header for authenticated requests", async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => [],
    });
    await client.pullHistory(0);
    const call = mockFetch.mock.calls[0];
    const headers = call[1].headers as Record<string, string>;
    expect(headers.Authorization).toBe("Bearer access-token");
  });

  it("does not send auth header for challenge request", async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({ challengeId: "ch-1" }),
    });
    await client.requestChallenge({ identityUrl: "https://x", username: "u" });
    const call = mockFetch.mock.calls[0];
    const headers = call[1].headers as Record<string, string>;
    expect(headers.Authorization).toBeUndefined();
  });

  it("throws CoordinationApiError on non-200", async () => {
    mockFetch.mockResolvedValueOnce({
      ok: false,
      status: 429,
      statusText: "Too Many Requests",
      json: async () => ({ code: "rate_limited", reason: "slow down" }),
    });
    await expect(client.pullHistory(0)).rejects.toThrow(CoordinationApiError);
    try {
      mockFetch.mockResolvedValueOnce({
        ok: false,
        status: 429,
        statusText: "Too Many Requests",
        json: async () => ({ code: "rate_limited", reason: "slow down" }),
      });
      await client.pullHistory(0);
    } catch (e) {
      expect(e).toBeInstanceOf(CoordinationApiError);
      expect((e as CoordinationApiError).code).toBe("rate_limited");
    }
  });

  it("strips trailing slash from base URL", () => {
    const c = new CoordinationHttpClient(
      "https://coord.example/",
      mockFetch as unknown as typeof fetch,
    );
    expect((c as unknown as { baseUrl: string }).baseUrl).toBe(
      "https://coord.example",
    );
  });

  it("does not recurse through authenticated retry for token refresh 401", async () => {
    client.setTokens({
      ...client.getTokens()!,
      accessTokenExpiresAt: Date.now() - 1,
    });
    mockFetch.mockResolvedValueOnce({
      ok: false,
      status: 401,
      statusText: "Unauthorized",
      json: async () => ({
        code: "authentication_failed",
        reason: "invalid refresh token",
      }),
    });

    await expect(client.ensureValidAccessToken()).rejects.toThrow(
      CoordinationApiError,
    );
    expect(mockFetch).toHaveBeenCalledTimes(1);
    expect(mockFetch.mock.calls[0][0]).toBe(
      "https://coord.example/v1/auth/token",
    );
  });

  it("recovers an invalid refresh token with current Subsonic credentials", async () => {
    const onTokensUpdated = vi.fn();
    client = new CoordinationHttpClient(
      "https://coord.example",
      mockFetch as unknown as typeof fetch,
      onTokensUpdated,
      () => ({
        identityUrl: "https://navidrome.example",
        username: "alice",
        password: "enc:616c696365",
        authType: AuthType.PASSWORD,
      }),
    );
    client.setTokens({
      deviceId: "dev-1",
      accountId: "acc-1",
      accessToken: "access-token",
      refreshToken: "old-refresh",
      accessTokenExpiresAt: Date.now() - 1,
      historyLimit: 100,
    });
    mockFetch
      .mockResolvedValueOnce({
        ok: false,
        status: 401,
        statusText: "Unauthorized",
        json: async () => ({
          code: "authentication_failed",
          reason: "invalid refresh token",
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({ challengeId: "challenge-1" }),
      })
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          accessToken: "new-access",
          refreshToken: "new-refresh",
          expiresIn: 3600,
        }),
      });

    await client.ensureValidAccessToken();

    expect(mockFetch).toHaveBeenCalledTimes(3);
    expect(mockFetch.mock.calls[1][0]).toBe(
      "https://coord.example/v1/auth/challenge",
    );
    expect(JSON.parse(mockFetch.mock.calls[2][1].body as string)).toMatchObject(
      {
        deviceId: "dev-1",
        refreshToken: "old-refresh",
        challengeId: "challenge-1",
        identityUrl: "https://navidrome.example",
        username: "alice",
        authMode: "password",
        password: "enc:616c696365",
      },
    );
    expect(client.getTokens()).toMatchObject({
      deviceId: "dev-1",
      accessToken: "new-access",
      refreshToken: "new-refresh",
    });
    expect(onTokensUpdated).toHaveBeenCalledWith(
      expect.objectContaining({
        deviceId: "dev-1",
        refreshToken: "new-refresh",
      }),
    );
  });

  it("attempts credential recovery only once for a refresh failure", async () => {
    const getRecoveryCredentials = vi.fn(() => ({
      identityUrl: "https://navidrome.example",
      username: "alice",
      password: "token",
      authType: AuthType.TOKEN,
    }));
    client = new CoordinationHttpClient(
      "https://coord.example",
      mockFetch as unknown as typeof fetch,
      undefined,
      getRecoveryCredentials,
    );
    client.setTokens({
      deviceId: "dev-1",
      accountId: "acc-1",
      accessToken: "access-token",
      refreshToken: "old-refresh",
      accessTokenExpiresAt: Date.now() - 1,
      historyLimit: 100,
    });
    mockFetch
      .mockResolvedValueOnce({
        ok: false,
        status: 401,
        statusText: "Unauthorized",
        json: async () => ({
          code: "authentication_failed",
          reason: "invalid refresh token",
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({ challengeId: "challenge-1" }),
      })
      .mockResolvedValueOnce({
        ok: false,
        status: 401,
        statusText: "Unauthorized",
        json: async () => ({
          code: "authentication_failed",
          reason: "verification failed",
        }),
      });

    await expect(client.ensureValidAccessToken()).rejects.toThrow(
      CoordinationApiError,
    );
    expect(getRecoveryCredentials).toHaveBeenCalledTimes(1);
    expect(mockFetch).toHaveBeenCalledTimes(3);
  });

  it("clears tokens for revoked devices without attempting recovery", async () => {
    const onTokensUpdated = vi.fn();
    const getRecoveryCredentials = vi.fn();
    client = new CoordinationHttpClient(
      "https://coord.example",
      mockFetch as unknown as typeof fetch,
      onTokensUpdated,
      getRecoveryCredentials,
    );
    client.setTokens({
      deviceId: "dev-1",
      accountId: "acc-1",
      accessToken: "access-token",
      refreshToken: "old-refresh",
      accessTokenExpiresAt: Date.now() - 1,
      historyLimit: 100,
    });
    mockFetch.mockResolvedValueOnce({
      ok: false,
      status: 403,
      statusText: "Forbidden",
      json: async () => ({
        code: "device_revoked",
        reason: "device revoked",
      }),
    });

    await expect(client.ensureValidAccessToken()).rejects.toThrow(
      CoordinationApiError,
    );
    expect(getRecoveryCredentials).not.toHaveBeenCalled();
    expect(client.getTokens()).toBeNull();
    expect(onTokensUpdated).toHaveBeenCalledWith(null);
  });
});
