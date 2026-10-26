import { beforeEach, describe, expect, it, vi } from "vitest";

const os = vi.hoisted(() => ({ available: true, backend: "keychain" }));
vi.mock("electron", () => ({
  safeStorage: {
    isEncryptionAvailable: () => os.available,
    getSelectedStorageBackend: () => os.backend,
    encryptString: (value: string) => Buffer.from(`encrypted:${value}`),
    decryptString: (value: Buffer) => {
      const text = value.toString();
      if (!text.startsWith("encrypted:"))
        throw new Error("unreadable keychain");
      return text.slice(10);
    },
  },
}));

import { ProtectedValue } from "./protected-value";

function fixture(legacy?: { token: string }) {
  const disk = { legacy, encrypted: undefined as string | undefined };
  const create = () =>
    new ProtectedValue<{ token: string }>({
      readEncrypted: () => disk.encrypted,
      writeEncrypted: (value) => {
        disk.encrypted = value;
      },
      clearEncrypted: () => {
        disk.encrypted = undefined;
      },
      readLegacy: () => disk.legacy,
      clearLegacy: () => {
        disk.legacy = undefined;
      },
    });
  return { disk, create };
}

describe("protected desktop secrets", () => {
  beforeEach(() => {
    os.available = true;
    os.backend = "keychain";
  });

  it("migrates plaintext and restores only encrypted data across instances", () => {
    const { disk, create } = fixture({ token: "secret" });
    expect(create().get()).toEqual({ token: "secret" });
    expect(disk.legacy).toBeUndefined();
    expect(disk.encrypted).not.toContain("secret");
    expect(create().get()).toEqual({ token: "secret" });
    create().clear();
    expect(create().get()).toBeNull();
  });

  it.each(["unavailable", "basic_text"])(
    "uses memory only with %s encryption",
    (mode) => {
      os.available = mode !== "unavailable";
      os.backend = mode === "basic_text" ? "basic_text" : "keychain";
      const { disk, create } = fixture({ token: "old-secret" });
      const value = create();
      expect(value.get()).toEqual({ token: "old-secret" });
      value.set({ token: "new-secret" });
      expect(disk).toEqual({ legacy: undefined, encrypted: undefined });
      expect(value.get()).toEqual({ token: "new-secret" });
      expect(create().get()).toBeNull();
    },
  );

  it("fails closed without deleting ciphertext when the keychain is locked", () => {
    const { disk, create } = fixture();
    create().set({ token: "secret" });
    const ciphertext = disk.encrypted;
    os.available = false;
    expect(create().get()).toBeNull();
    expect(disk.encrypted).toBe(ciphertext);
    os.available = true;
    expect(create().get()).toEqual({ token: "secret" });
  });
});
