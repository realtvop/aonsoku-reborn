import type { AonsokuNativeCoordinationPlugin } from "@aonsoku/capacitor-native/coordination";
import { ipcRenderer } from "electron";

const CHANNEL = "aonsoku-native-coordination";
const EVENT_CHANNEL = "aonsoku-native-coordination-event";
type Listener = (payload: never) => void;
const listeners = new Map<string, Set<Listener>>();
ipcRenderer.on(EVENT_CHANNEL, (_event, name, payload) => {
  for (const listener of listeners.get(name) ?? []) listener(payload);
});
const invoke = <T>(method: string, ...args: unknown[]): Promise<T> =>
  ipcRenderer.invoke(CHANNEL, method, args);

const bridge = {
  storeTokens: (o: unknown) => invoke("storeTokens", o),
  loadTokens: () => invoke("loadTokens"),
  clearTokens: () => invoke("clearTokens"),
  storeConfig: (o: unknown) => invoke("storeConfig", o),
  loadConfig: () => invoke("loadConfig"),
  request: (o: unknown) => invoke("request", o),
  connect: (o: unknown) => invoke("connect", o),
  disconnect: () => invoke("disconnect"),
  getState: () => invoke("getState"),
  publishSnapshot: (o: unknown) => invoke("publishSnapshot", o),
  sendCommand: (o: unknown) => invoke("sendCommand", o),
  sendActiveControlCommand: (o: unknown) =>
    invoke("sendActiveControlCommand", o),
  requestHandoffCandidate: (...args: unknown[]) =>
    invoke("requestHandoffCandidate", ...args),
  requestHandoffCandidateFromCache: (o: unknown) =>
    invoke("requestHandoffCandidateFromCache", o),
  sendTargetReady: (...args: unknown[]) => invoke("sendTargetReady", ...args),
  sendRelinquishAck: (o: unknown) => invoke("sendRelinquishAck", o),
  sendControlSessionBegin: (o: unknown) => invoke("sendControlSessionBegin", o),
  sendControlSessionEnd: () => invoke("sendControlSessionEnd"),
  requestSnapshots: () => invoke("requestSnapshots"),
  addListener: async (name: string, listener: Listener) => {
    const set = listeners.get(name) ?? new Set<Listener>();
    set.add(listener);
    listeners.set(name, set);
    return { remove: async () => set.delete(listener) };
  },
  removeAllListeners: async () => listeners.clear(),
};
export const aonsokuNativeCoordination =
  bridge as unknown as AonsokuNativeCoordinationPlugin;
