import type * as PackageAudio from "@aonsoku/capacitor-native/audio";
import type * as AudioContract from "@aonsoku/capacitor-native/audio/contract";
import type * as AppAudio from "@/native/audio";

type IsEqual<TLeft, TRight> = (<T>() => T extends TLeft ? 1 : 2) extends <
  T,
>() => T extends TRight ? 1 : 2
  ? true
  : false;

type Assert<TValue extends true> = TValue;

export type AppAudioPluginUsesContract = Assert<
  IsEqual<AppAudio.NativeAudioPlugin, AudioContract.NativeAudioPlugin>
>;

export type PackageAudioPluginUsesContract = Assert<
  IsEqual<
    PackageAudio.AonsokuNativeAudioPlugin,
    AudioContract.NativeAudioPlugin
  >
>;

export type AppAudioEventsUseContract = Assert<
  IsEqual<AppAudio.NativeAudioEvents, AudioContract.NativeAudioEvents>
>;

export type PackageAudioEventsUseContract = Assert<
  IsEqual<PackageAudio.NativeAudioEvents, AudioContract.NativeAudioEvents>
>;

export type DesktopBridgeApiUsesContract = Assert<
  IsEqual<PackageAudio.AonsokuAudioApi, AudioContract.AonsokuAudioApi>
>;
