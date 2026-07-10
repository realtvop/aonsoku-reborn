import type { AonsokuNativePreferencesPlugin } from "@aonsoku/capacitor-native/preferences";
import { AonsokuStore } from "../../core/store";

type PreferencesStore = {
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
      preferences: {},
      playHistory: [],
    },
  });

  async getAllPreferences(): Promise<{ preferences: Record<string, string> }> {
    return { preferences: { ...(this.store.get("preferences") ?? {}) } };
  }

  async setPreferences(options: {
    preferences: Record<string, string>;
  }): Promise<void> {
    const current = this.store.get("preferences") ?? {};
    this.store.set("preferences", {
      ...current,
      ...options.preferences,
    });
  }

  async setPreference(options: {
    key: string;
    value: string;
  }): Promise<void> {
    const current = this.store.get("preferences") ?? {};
    this.store.set("preferences", {
      ...current,
      [options.key]: options.value,
    });
  }

  async deletePreference(options: { key: string }): Promise<void> {
    const current = { ...(this.store.get("preferences") ?? {}) };
    delete current[options.key];
    this.store.set("preferences", current);
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
