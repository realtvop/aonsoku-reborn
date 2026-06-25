import { WebPlugin } from "@capacitor/core";
import type {
  AonsokuNativeCoordinationPlugin,
  CoordinationConfigOptions,
  CoordinationStateResult,
  CoordinationTokenOptions,
} from "./definitions";

/// Web stub for the coordination plugin. The web runtime uses the TypeScript
/// CoordinationWsClient directly; this stub rejects all calls so that the
/// native bridge path is only taken when actually running on a native device.
export class AonsokuNativeCoordinationWeb
  extends WebPlugin
  implements AonsokuNativeCoordinationPlugin
{
  async storeTokens(): Promise<void> {
    throw new Error("coordination: native plugin not available on web");
  }
  async loadTokens(): Promise<CoordinationTokenOptions | null> {
    return null;
  }
  async clearTokens(): Promise<void> {
    // No-op on web
  }
  async storeConfig(): Promise<void> {
    throw new Error("coordination: native plugin not available on web");
  }
  async loadConfig(): Promise<CoordinationConfigOptions | null> {
    return null;
  }
  async request(): Promise<never> {
    throw new Error("coordination: native plugin not available on web");
  }
  async connect(): Promise<void> {
    throw new Error("coordination: native plugin not available on web");
  }
  async disconnect(): Promise<void> {
    // No-op on web
  }
  async getState(): Promise<CoordinationStateResult> {
    return { state: "disconnected", deviceId: null };
  }
  async publishSnapshot(): Promise<void> {
    throw new Error("coordination: native plugin not available on web");
  }
  async sendCommand(): Promise<void> {
    throw new Error("coordination: native plugin not available on web");
  }
  async requestHandoffCandidate(): Promise<void> {
    throw new Error("coordination: native plugin not available on web");
  }
  async sendTargetReady(): Promise<void> {
    throw new Error("coordination: native plugin not available on web");
  }
  async sendRelinquishAck(): Promise<void> {
    throw new Error("coordination: native plugin not available on web");
  }
  async requestSnapshots(): Promise<void> {
    throw new Error("coordination: native plugin not available on web");
  }
  async addListener(
    eventName: string,
    _listenerFunc: (data: unknown) => void,
  ): Promise<import("@capacitor/core").PluginListenerHandle> {
    // The web runtime uses CoordinationWsClient directly; no native events.
    return await Promise.reject(
      new Error(
        `coordination: native plugin not available on web (${eventName})`,
      ),
    );
  }
  async removeAllListeners(): Promise<void> {
    // No-op on web
  }
}
