import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  handle: vi.fn(),
  getMediaUrl: vi.fn(),
  subsonicFetch: vi.fn(),
  readCover: vi.fn(),
  readCoverWithMeta: vi.fn(),
}));

vi.mock("electron", () => ({
  protocol: { handle: mocks.handle },
}));
vi.mock("./bridge/ipc", () => ({
  desktopNativeBridgeService: { getMediaUrl: mocks.getMediaUrl },
}));
vi.mock("./bridge/http-agent", () => ({
  subsonicFetch: mocks.subsonicFetch,
}));
vi.mock("./data/ipc", () => ({
  getDesktopNativeDataService: () => ({
    readCover: mocks.readCover,
    readCoverWithMeta: mocks.readCoverWithMeta,
  }),
}));

const { setupDesktopMediaProtocol } = await import("./media-protocol");

describe("desktop media protocol", () => {
  let handleRequest: (request: Request) => Promise<Response>;

  beforeEach(() => {
    vi.resetAllMocks();
    mocks.readCover.mockResolvedValue(null);
    mocks.readCoverWithMeta.mockResolvedValue(null);
    mocks.getMediaUrl.mockImplementation(
      (path: string, query: Record<string, string>) =>
        `https://fixture.invalid${path}?${new URLSearchParams(query)}`,
    );
    mocks.subsonicFetch.mockImplementation(async () => {
      return new Response("network image", {
        headers: { "Content-Type": "image/png" },
      });
    });
    setupDesktopMediaProtocol();
    handleRequest = mocks.handle.mock.calls[0][1];
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it.each(["getcoverart", "getCoverArt"])(
    "loads an uncached cover through %s",
    async (operation) => {
      const query = { id: "song&cover/1", size: "300" };
      const request = new Request(
        `aonsoku-media://${operation}/?${new URLSearchParams(query)}`,
      );

      const response = await handleRequest(request);

      expect(response.status).toBe(200);
      expect(await response.text()).toBe("network image");
      expect(mocks.readCoverWithMeta).toHaveBeenCalledWith(query.id);
      expect(mocks.getMediaUrl).toHaveBeenCalledWith(
        "/getCoverArt.view",
        query,
      );
      expect(mocks.subsonicFetch).toHaveBeenCalledWith(
        expect.stringContaining("/getCoverArt.view?"),
        expect.objectContaining({ signal: expect.any(AbortSignal) }),
      );
    },
  );

  it.each(["getavatar", "getAvatar"])(
    "loads an uncached avatar through %s",
    async (operation) => {
      const query = { username: "user&name", size: "100" };

      const response = await handleRequest(
        new Request(
          `aonsoku-media://${operation}/?${new URLSearchParams(query)}`,
        ),
      );

      expect(response.status).toBe(200);
      expect(await response.text()).toBe("network image");
      expect(mocks.readCoverWithMeta).toHaveBeenCalledWith(query.username);
      expect(mocks.getMediaUrl).toHaveBeenCalledWith("/getAvatar.view", query);
    },
  );

  it("serves a sufficiently large cached cover without a network request", async () => {
    mocks.readCoverWithMeta.mockResolvedValue({
      data: Buffer.from("cached image"),
      contentType: "image/jpeg",
      coverSize: "700",
    });

    const response = await handleRequest(
      new Request("aonsoku-media://getcoverart/?id=cover&size=300"),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("image/jpeg");
    expect(await response.text()).toBe("cached image");
    expect(mocks.subsonicFetch).not.toHaveBeenCalled();
  });

  it("fetches a larger cover when the cached copy is too small", async () => {
    mocks.readCoverWithMeta.mockResolvedValue({
      data: Buffer.from("small image"),
      contentType: "image/jpeg",
      coverSize: "100",
    });

    const response = await handleRequest(
      new Request("aonsoku-media://getcoverart/?id=cover&size=300"),
    );

    expect(await response.text()).toBe("network image");
    expect(mocks.subsonicFetch).toHaveBeenCalledOnce();
  });

  it("serves the cached media URL", async () => {
    mocks.readCover.mockResolvedValue({
      data: Buffer.from("cached image"),
      contentType: "image/jpeg",
    });

    const response = await handleRequest(
      new Request("aonsoku-media://cached/?id=cover"),
    );

    expect(await response.text()).toBe("cached image");
    expect(mocks.readCover).toHaveBeenCalledWith("cover");
    expect(mocks.subsonicFetch).not.toHaveBeenCalled();
  });

  it("keeps streaming on the global fetch path", async () => {
    const fetch = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("audio"));
    const request = new Request("aonsoku-media://stream/?id=song");

    const response = await handleRequest(request);

    expect(await response.text()).toBe("audio");
    expect(fetch).toHaveBeenCalledWith(
      "https://fixture.invalid/stream.view?id=song",
      { headers: request.headers, signal: request.signal },
    );
    expect(mocks.subsonicFetch).not.toHaveBeenCalled();
  });

  it("rejects unknown operations", async () => {
    const response = await handleRequest(
      new Request("aonsoku-media://unknown/?id=cover"),
    );

    expect(response.status).toBe(404);
    expect(mocks.subsonicFetch).not.toHaveBeenCalled();
  });
});
