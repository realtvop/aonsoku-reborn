import type { AonsokuNativeDataPlugin } from "@aonsoku/capacitor-native/data";
import { ipcRenderer } from "electron";

const DESKTOP_NATIVE_DATA_CHANNEL = "aonsoku-native-data";
const DESKTOP_NATIVE_DATA_EVENT_CHANNEL = "aonsoku-native-data-event";

function invoke<T>(method: string, options?: unknown): Promise<T> {
  return ipcRenderer.invoke(DESKTOP_NATIVE_DATA_CHANNEL, method, options);
}

type Listener = (payload: never) => void;
const listeners = new Map<string, Set<Listener>>();
ipcRenderer.on(DESKTOP_NATIVE_DATA_EVENT_CHANNEL, (_event, name, payload) => {
  for (const listener of listeners.get(name) ?? []) listener(payload);
});

const bridge = {
  initialize: () => invoke("initialize"),
  importBulk: (options: unknown) => invoke("importBulk", options),
  syncAll: (options?: unknown) => invoke("syncAll", options),
  syncIncremental: () => invoke("syncIncremental"),
  cancelSync: () => invoke("cancelSync"),
  getSyncState: () => invoke("getSyncState"),
  getArtists: (options: unknown) => invoke("getArtists", options),
  getArtist: (options: unknown) => invoke("getArtist", options),
  getAlbums: (options: unknown) => invoke("getAlbums", options),
  getAlbum: (options: unknown) => invoke("getAlbum", options),
  getSongs: (options: unknown) => invoke("getSongs", options),
  getPlaylists: (options?: unknown) => invoke("getPlaylists", options),
  getPlaylist: (options: unknown) => invoke("getPlaylist", options),
  getGenres: () => invoke("getGenres"),
  getFavorites: (options: unknown) => invoke("getFavorites", options),
  search: (options: unknown) => invoke("getSearch", options),
  getLyrics: (options: unknown) => invoke("getLyrics", options),
  storeLyrics: (options: unknown) => invoke("storeLyrics", options),
  getCacheStats: () => invoke("getCacheStats"),
  isDataAvailableOffline: () => invoke("isDataAvailableOffline"),
  storeCoverImage: (options: unknown) => invoke("storeCoverImage", options),
  resolveCoverImage: (options: unknown) => invoke("resolveCoverImage", options),
  getCoverImageSize: (options: unknown) => invoke("getCoverImageSize", options),
  deleteCoverImage: (options: unknown) => invoke("deleteCoverImage", options),
  clearCoverImages: () => invoke("clearCoverImages"),
  downloadCoverImage: (options: unknown) =>
    invoke("downloadCoverImage", options),
  downloadAvatar: (options: unknown) => invoke("downloadAvatar", options),
  addListener: async (eventName: string, listener: Listener) => {
    const eventListeners = listeners.get(eventName) ?? new Set<Listener>();
    eventListeners.add(listener);
    listeners.set(eventName, eventListeners);
    return { remove: async () => eventListeners.delete(listener) };
  },
  removeAllListeners: async () => listeners.clear(),
};

export const aonsokuNativeData = bridge as unknown as AonsokuNativeDataPlugin;
