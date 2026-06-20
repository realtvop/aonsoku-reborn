import { registerPlugin } from "@capacitor/core";
import {
  COORDINATION_PLUGIN_NAME,
  type AonsokuNativeCoordinationPlugin,
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
  CoordinationConnectOptions,
  CoordinationStateResult,
  CoordinationSnapshotOptions,
  CoordinationCommandOptions,
  CoordinationHandoffOptions,
  CoordinationTokenOptions,
  CoordinationConfigOptions,
};
