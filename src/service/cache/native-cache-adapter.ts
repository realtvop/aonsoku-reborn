import { getRuntime } from "@/utils/capabilities";
import {
  getNativeAudioPluginAvailability,
  type NativeAudioPlugin,
} from "@/native/audio";
import type { NativeCacheAdapter, NativeCachedAudioFile } from "./contracts";

class WebNullNativeCacheAdapter implements NativeCacheAdapter {
  async storeAudioFile(
    _songId: string,
    _data: Blob,
    _contentType: string,
  ): Promise<NativeCachedAudioFile> {
    throw new Error("NativeCacheAdapter is not available on web platform");
  }

  async resolveAudioFile(
    _songId: string,
  ): Promise<NativeCachedAudioFile | null> {
    return null;
  }

  async getAudioFileSize(_songId: string): Promise<number | null> {
    return null;
  }

  async deleteAudioFile(_songId: string): Promise<boolean> {
    return false;
  }

  async evictAudioFile(_songId: string): Promise<boolean> {
    return false;
  }

  async clearAudioFiles(): Promise<void> {}
}

async function arrayBufferToBase64(buffer: ArrayBuffer): Promise<string> {
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = "";

  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    const chunk = bytes.subarray(offset, offset + chunkSize);
    binary += String.fromCharCode(...chunk);

    if (offset % (chunkSize * 16) === 0) {
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
  }

  return btoa(binary);
}

export class IosNativeCacheAdapter implements NativeCacheAdapter {
  constructor(private readonly plugin: NativeAudioPlugin) {}

  async storeAudioFile(
    songId: string,
    data: Blob,
    contentType: string,
  ): Promise<NativeCachedAudioFile> {
    const dataBase64 = await arrayBufferToBase64(await data.arrayBuffer());
    return this.plugin.storeAudioFile({
      songId,
      dataBase64,
      contentType,
    });
  }

  async resolveAudioFile(
    songId: string,
  ): Promise<NativeCachedAudioFile | null> {
    const result = await this.plugin.resolveAudioFile({ songId });
    return result.file ?? null;
  }

  async getAudioFileSize(songId: string): Promise<number | null> {
    const result = await this.plugin.getAudioFileSize({ songId });
    return result.sizeBytes ?? null;
  }

  async deleteAudioFile(songId: string): Promise<boolean> {
    const result = await this.plugin.deleteAudioFile({ songId });
    return result.deleted;
  }

  async evictAudioFile(songId: string): Promise<boolean> {
    return this.deleteAudioFile(songId);
  }

  async clearAudioFiles(): Promise<void> {
    await this.plugin.clearAudioFiles();
  }
}

let nativeCacheAdapter: NativeCacheAdapter | null = null;

export function getNativeCacheAdapter(): NativeCacheAdapter {
  if (nativeCacheAdapter) return nativeCacheAdapter;

  const runtime = getRuntime();
  if (
    runtime === "capacitor-ios" ||
    runtime === "capacitor-android" ||
    runtime === "electron"
  ) {
    const availability = getNativeAudioPluginAvailability();
    const useNativeCache = availability.available;
    nativeCacheAdapter = useNativeCache
      ? new IosNativeCacheAdapter(availability.plugin)
      : new WebNullNativeCacheAdapter();
    return nativeCacheAdapter;
  }

  nativeCacheAdapter = new WebNullNativeCacheAdapter();
  return nativeCacheAdapter;
}

export function isNativeCacheAdapterAvailable(): boolean {
  const availability = getNativeAudioPluginAvailability();
  return availability.available;
}

export async function storeNativeAudioFileIfAvailable(
  songId: string,
  data: Blob,
  contentType: string,
): Promise<NativeCachedAudioFile | null> {
  if (!isNativeCacheAdapterAvailable()) return null;
  return getNativeCacheAdapter().storeAudioFile(songId, data, contentType);
}

export async function evictNativeAudioFileIfAvailable(
  songId: string,
): Promise<boolean> {
  if (!isNativeCacheAdapterAvailable()) return false;
  return getNativeCacheAdapter().evictAudioFile(songId);
}

export async function clearNativeAudioFilesIfAvailable(): Promise<void> {
  if (!isNativeCacheAdapterAvailable()) return;
  await getNativeCacheAdapter().clearAudioFiles();
}

export function _resetNativeCacheAdapter(): void {
  nativeCacheAdapter = null;
}

export function _setNativeCacheAdapterForTests(
  adapter: NativeCacheAdapter | null,
): void {
  nativeCacheAdapter = adapter;
}
