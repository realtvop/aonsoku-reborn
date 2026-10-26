import type { AonsokuNativePreferencesPlugin } from "@aonsoku/capacitor-native/preferences";
import { AonsokuStore } from "../../core/store";
import { ProtectedValue } from "../../core/protected-value";

type PreferencesStore = {
  encryptedPreferences?: string;
  preferences?: Record<string, string>;
  queueState?: string;
  playHistory?: string[];
};

export class DesktopNativePreferencesService
  implements AonsokuNativePreferencesPlugin
{
  private readonly store = new AonsokuStore<PreferencesStore>({
    name: "native-preferences",
    defaults: {
      playHistory: [],
    },
  });
  // The renderer's app/player preferences can contain authentication tokens
  // and custom-lyrics passwords, so protecting only native-credentials is insufficient.
  private readonly preferences = new ProtectedValue<Record<string, string>>({
    readEncrypted: () => this.store.get("encryptedPreferences"),
    writeEncrypted: (value) => this.store.set("encryptedPreferences", value),
    clearEncrypted: () => this.store.delete("encryptedPreferences"),
    readLegacy: () => this.store.get("preferences"),
    clearLegacy: () => this.store.delete("preferences"),
  });

  async getAllPreferences(): Promise<{ preferences: Record<string, string> }> {
    return { preferences: { ...(this.preferences.get() ?? {}) } };
  }

  async setPreferences(options: {
    preferences: Record<string, string>;
  }): Promise<void> {
    const current = this.preferences.get() ?? {};
    this.preferences.set({
      ...current,
      ...options.preferences,
    });
  }

  async setPreference(options: { key: string; value: string }): Promise<void> {
    const current = this.preferences.get() ?? {};
    this.preferences.set({
      ...current,
      [options.key]: options.value,
    });
  }

  async deletePreference(options: { key: string }): Promise<void> {
    const current = { ...(this.preferences.get() ?? {}) };
    delete current[options.key];
    this.preferences.set(current);
  }

  async getQueueState(): Promise<{ state: string | null }> {
    return { state: this.store.get("queueState") ?? null };
  }

  async setQueueState(options: { state: string }): Promise<void> {
    this.store.set("queueState", options.state);
  }

  async getPlayHistory(options?: {
    limit?: number;
  }): Promise<{ history: string[] }> {
    const history = this.store.get("playHistory") ?? [];
    const limit = options?.limit;
    return {
      history:
        typeof limit === "number" && limit > 0
          ? history.slice(0, limit)
          : [...history],
    };
  }

  async addToPlayHistory(options: {
    song: string;
    maxSize?: number;
  }): Promise<void> {
    const maxSize = options.maxSize ?? 100;
    const current = this.store.get("playHistory") ?? [];
    this.store.set("playHistory", [options.song, ...current].slice(0, maxSize));
  }

  async clearPlayHistory(): Promise<void> {
    this.store.set("playHistory", []);
  }

  async addListener(): Promise<{ remove: () => Promise<void> }> {
    return { remove: async () => {} };
  }

  async removeAllListeners(): Promise<void> {}
}
