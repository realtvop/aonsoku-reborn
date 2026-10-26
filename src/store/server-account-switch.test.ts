import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({
  reachable: true,
  reset: vi.fn(async () => {}),
  end: vi.fn(async () => {}),
}));
vi.mock("@/api/pingServer", () => ({
  pingServer: async () => mocks.reachable,
}));
vi.mock("@/api/queryServerInfo", () => ({
  queryServerInfo: async () => ({
    protocolVersion: "1.16.1",
    serverType: "navidrome",
  }),
}));
vi.mock("@/utils/discordRpc", () => ({ discordRpc: {} }));
vi.mock("@/native/bridge/facade", () => ({
  isNativeBridgeAvailable: () => false,
}));
vi.mock("@/lib/account-reset", () => ({ markAccountReset: mocks.reset }));
vi.mock("@/coordination/store", () => ({
  useCoordinationStore: { getState: () => ({ endSession: mocks.end }) },
}));
import { useAppStore } from "./app.store";
import { AuthType } from "@/types/serverConfig";

describe("primary-server account boundary", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.reachable = true;
    useAppStore.setState((state) => {
      Object.assign(state.data, {
        url: "https://old.test",
        primaryUrl: "https://old.test",
        fallbackUrl: "",
        username: "alice",
        password: "same-token",
        authType: AuthType.TOKEN,
        isServerConfigured: true,
      });
    });
  });

  it("requires a clean session when identical credentials authenticate another primary server", async () => {
    expect(
      await useAppStore
        .getState()
        .actions.saveServerUrls({
          primaryUrl: "https://new.test",
          fallbackUrl: "",
        }),
    ).toBe(true);
    expect(mocks.end).toHaveBeenCalledOnce();
    expect(mocks.reset).toHaveBeenCalledOnce();
    expect(useAppStore.getState().data.primaryUrl).toBe("https://new.test");
  });

  it("keeps the account for fallback-only edits", async () => {
    expect(
      await useAppStore
        .getState()
        .actions.saveServerUrls({
          primaryUrl: "https://old.test/",
          fallbackUrl: "https://backup.test",
        }),
    ).toBe(true);
    expect(mocks.reset).not.toHaveBeenCalled();
    expect(mocks.end).not.toHaveBeenCalled();
  });

  it("retains the old account and its data when the new address fails authentication", async () => {
    mocks.reachable = false;
    expect(
      await useAppStore
        .getState()
        .actions.saveServerUrls({
          primaryUrl: "https://new.test",
          fallbackUrl: "",
        }),
    ).toBe(false);
    expect(mocks.reset).not.toHaveBeenCalled();
    expect(useAppStore.getState().data.primaryUrl).toBe("https://old.test");
  });
});
