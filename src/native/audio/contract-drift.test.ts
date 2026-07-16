import type * as AudioContract from "@aonsoku/audio-contract";
import type * as PackageAudio from "@aonsoku/capacitor-native/audio";
import { expect, it } from "vitest";
import type * as AppAudio from "@/native/audio";
import type { aonsokuNativeAudioBridge } from "../../../electron/preload/native-audio";

type IsEqual<TLeft, TRight> = (<T>() => T extends TLeft ? 1 : 2) extends <
  T,
>() => T extends TRight ? 1 : 2
  ? true
  : false;

type Assert<TValue extends true> = TValue;

export type AppAudioPluginUsesContract = Assert<
  IsEqual<AppAudio.NativeAudioPlugin, AudioContract.AonsokuAudioBridge>
>;

export type ElectronPreloadBridgeUsesContract = Assert<
  IsEqual<typeof aonsokuNativeAudioBridge, AudioContract.AonsokuAudioBridge>
>;

export type PackageAudioPluginUsesContract = Assert<
  PackageAudio.AonsokuNativeAudioPlugin extends AudioContract.AonsokuAudioBridge
    ? true
    : false
>;

export type AppAudioEventsUseContract = Assert<
  IsEqual<AppAudio.NativeAudioEvents, AudioContract.NativeAudioEvents>
>;

export type PackageAudioEventsUseContract = Assert<
  IsEqual<PackageAudio.NativeAudioEvents, AudioContract.NativeAudioEvents>
>;

export type DesktopBridgeApiUsesContract = Assert<
  IsEqual<AppAudio.AonsokuAudioApi, AudioContract.AonsokuAudioApi>
>;

export type DesktopBridgeEventsUseContract = Assert<
  IsEqual<AppAudio.AonsokuAudioBridge, AudioContract.AonsokuAudioBridge>
>;

it("keeps audio bridge types anchored to the shared contract", () => {
  expect(true).toBe(true);
});
