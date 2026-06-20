import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { CoordinationHttpClient, buildSubsonicProof, CoordinationApiError } from "./httpClient";
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
		client = new CoordinationHttpClient("https://coord.example", mockFetch as unknown as typeof fetch);
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
		await client.listDevices();
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
		await expect(client.listDevices()).rejects.toThrow(CoordinationApiError);
		try {
			mockFetch.mockResolvedValueOnce({
				ok: false,
				status: 429,
				statusText: "Too Many Requests",
				json: async () => ({ code: "rate_limited", reason: "slow down" }),
			});
			await client.listDevices();
		} catch (e) {
			expect(e).toBeInstanceOf(CoordinationApiError);
			expect((e as CoordinationApiError).code).toBe("rate_limited");
		}
	});

	it("strips trailing slash from base URL", () => {
		const c = new CoordinationHttpClient("https://coord.example/", mockFetch as unknown as typeof fetch);
		expect((c as unknown as { baseUrl: string }).baseUrl).toBe("https://coord.example");
	});
});