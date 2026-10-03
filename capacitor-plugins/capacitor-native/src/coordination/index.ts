import { registerPlugin } from "@capacitor/core";
import {
  type AonsokuNativeCoordinationPlugin,
  COORDINATION_PLUGIN_NAME,
} from "./definitions";
import { AonsokuNativeCoordinationWeb } from "./web";

export const AonsokuNativeCoordination =
  registerPlugin<AonsokuNativeCoordinationPlugin>(COORDINATION_PLUGIN_NAME, {
    web: () => new AonsokuNativeCoordinationWeb(),
  });

export { AonsokuNativeCoordinationWeb } from "./web";
export { COORDINATION_PLUGIN_NAME };
export type {
  AonsokuNativeCoordinationPlugin,
  CoordinationAckEvent,
  CoordinationCommandOptions,
  CoordinationConfigOptions,
  CoordinationConnectOptions,
  CoordinationHandoffOptions,
  CoordinationHttpRequestOptions,
  CoordinationHttpResponse,
  CoordinationSnapshotOptions,
  CoordinationStateResult,
  CoordinationTokenOptions,
} from "./definitions";
