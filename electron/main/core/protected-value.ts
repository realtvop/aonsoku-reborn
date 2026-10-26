import { safeStorage } from "electron";

interface Storage<T> {
  readEncrypted(): string | undefined;
  writeEncrypted(value: string): void;
  clearEncrypted(): void;
  readLegacy(): T | undefined;
  clearLegacy(): void;
}

/** Persist secrets only when the operating system provides secure encryption. */
export class ProtectedValue<T> {
  private memory: T | null = null;

  constructor(private readonly storage: Storage<T>) {}

  private canEncrypt(): boolean {
    return (
      safeStorage?.isEncryptionAvailable() === true &&
      safeStorage.getSelectedStorageBackend?.() !== "basic_text"
    );
  }

  get(): T | null {
    const legacy = this.storage.readLegacy();
    if (legacy !== undefined) {
      this.set(legacy);
      return legacy;
    }
    if (this.memory !== null) return this.memory;
    const encrypted = this.storage.readEncrypted();
    if (!encrypted || !this.canEncrypt()) return null;
    try {
      return JSON.parse(
        safeStorage.decryptString(Buffer.from(encrypted, "base64")),
      ) as T;
    } catch {
      return null;
    }
  }

  set(value: T): void {
    if (this.canEncrypt()) {
      const encrypted = safeStorage.encryptString(JSON.stringify(value));
      this.storage.writeEncrypted(encrypted.toString("base64"));
      this.memory = null;
    } else {
      this.memory = value;
      this.storage.clearEncrypted();
    }
    this.storage.clearLegacy();
  }

  clear(): void {
    this.memory = null;
    this.storage.clearLegacy();
    this.storage.clearEncrypted();
  }
}
