import { describe, expect, it } from "vitest";
import { AuthType } from "@/types/serverConfig";
import type { ServerAuthConfig } from "./urlBuilder";
import {
  buildCoverArtUrl,
  buildQueryParams,
  buildSongStreamUrl,
  buildUrl,
} from "./urlBuilder";

const tokenConfig: ServerAuthConfig = {
  url: "https://music.example.com",
  username: "admin",
  password: "abc123",
  authType: AuthType.TOKEN,
  protocolVersion: "1.16.1",
};

const passwordConfig: ServerAuthConfig = {
  url: "https://music.example.com",
  username: "admin",
  password: "mypassword",
  authType: AuthType.PASSWORD,
};

describe("buildQueryParams", () => {
  it("includes auth, version, client, and format params for token auth", () => {
    const params = buildQueryParams(tokenConfig);
    expect(params).toHaveProperty("u", "admin");
    expect(params).toHaveProperty("t", "abc123");
    expect(params).toHaveProperty("s", "40n50kuPl4y3r");
    expect(params).toHaveProperty("v", "1.16.1");
    expect(params).toHaveProperty("c", "Aonsoku");
    expect(params).toHaveProperty("f", "json");
  });

  it("includes password auth params for password auth", () => {
    const params = buildQueryParams(passwordConfig);
    expect(params).toHaveProperty("u", "admin");
    expect(params).toHaveProperty("p", "mypassword");
    expect(params).not.toHaveProperty("t");
    expect(params).not.toHaveProperty("s");
  });

  it("defaults protocol version to 1.16.0 when not provided", () => {
    const config = { ...tokenConfig, protocolVersion: undefined };
    const params = buildQueryParams(config);
    expect(params.v).toBe("1.16.0");
  });
});

describe("buildUrl", () => {
  it("builds a URL with query parameters", () => {
    const url = buildUrl("getAlbum", tokenConfig);
    expect(url).toContain("https://music.example.com/rest/getAlbum?");
    expect(url).toContain("u=admin");
    expect(url).toContain("f=json");
  });

  it("strips leading slash from path", () => {
    const url = buildUrl("/getAlbum", tokenConfig);
    expect(url).toContain("/rest/getAlbum?");
    expect(url).not.toContain("/rest//getAlbum");
  });

  it("appends extra query parameters", () => {
    const url = buildUrl("getAlbum", tokenConfig, {
      id: "42",
      size: "300",
    });
    expect(url).toContain("id=42");
    expect(url).toContain("size=300");
  });

  it("skips undefined extra query parameters", () => {
    const url = buildUrl("getAlbum", tokenConfig, {
      id: "42",
      size: undefined,
    });
    expect(url).toContain("id=42");
    expect(url).not.toContain("size=");
  });

  it("handles paths with existing query string", () => {
    const url = buildUrl("stream?format=raw", tokenConfig);
    expect(url).toContain("&");
    expect(url).toContain("format=raw");
  });
});

describe("buildCoverArtUrl", () => {
  it("returns a full URL when id is provided", () => {
    const url = buildCoverArtUrl(tokenConfig, "album-42", "album", "300");
    expect(url).toContain("/rest/getCoverArt?");
    expect(url).toContain("id=album-42");
    expect(url).toContain("size=300");
  });

  it("returns undefined when no id", () => {
    const url = buildCoverArtUrl(tokenConfig, undefined, "album");
    expect(url).toBeUndefined();
  });

  it("returns undefined for artist type with no id", () => {
    const url = buildCoverArtUrl(tokenConfig, undefined, "artist");
    expect(url).toBeUndefined();
  });

  it("defaults type to album and returns undefined when no id", () => {
    const url = buildCoverArtUrl(tokenConfig, undefined);
    expect(url).toBeUndefined();
  });

  it("defaults size to 300", () => {
    const url = buildCoverArtUrl(tokenConfig, "id1");
    expect(url).toContain("size=300");
  });
});

describe("buildSongStreamUrl", () => {
  it("builds stream URL with id", () => {
    const url = buildSongStreamUrl(tokenConfig, "song-1");
    expect(url).toContain("/rest/stream?");
    expect(url).toContain("id=song-1");
    expect(url).toContain("estimateContentLength=false");
  });

  it("includes optional maxBitRate and format", () => {
    const url = buildSongStreamUrl(tokenConfig, "song-1", "128", "mp3");
    expect(url).toContain("maxBitRate=128");
    expect(url).toContain("format=mp3");
  });
});
