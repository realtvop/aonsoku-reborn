import type { NativeCachedCoverImageFile } from "@aonsoku/capacitor-native/data";
import {
  type AonsokuNativeDataPlugin,
  getNativeDataAvailability,
} from "@/native/data";

export interface NativeImageCacheAdapter {
  downloadCoverImage(
    coverArtId: string,
    size: string,
  ): Promise<NativeCachedCoverImageFile | null>;
  downloadAvatar(
    username: string,
    size: string,
  ): Promise<NativeCachedCoverImageFile | null>;
  storeCoverImage(
    coverArtId: string,
    data: Blob,
    contentType: string,
    coverSize: string,
  ): Promise<NativeCachedCoverImageFile | null>;
  resolveCoverImage(
    coverArtId: string,
  ): Promise<NativeCachedCoverImageFile | null>;
  getCoverImageSize(
    coverArtId: string,
  ): Promise<{ sizeBytes: number | null; coverSize: string | null }>;
  deleteCoverImage(coverArtId: string): Promise<boolean>;
  clearCoverImages(): Promise<void>;
}

class WebNullNativeImageCacheAdapter implements NativeImageCacheAdapter {
  async downloadCoverImage(): Promise<NativeCachedCoverImageFile | null> {
    return null;
  }

  async downloadAvatar(): Promise<NativeCachedCoverImageFile | null> {
    return null;
  }

  async storeCoverImage(): Promise<NativeCachedCoverImageFile | null> {
    return null;
  }

  async resolveCoverImage(): Promise<NativeCachedCoverImageFile | null> {
    return null;
  }

  async getCoverImageSize(): Promise<{
    sizeBytes: number | null;
    coverSize: string | null;
  }> {
    return { sizeBytes: null, coverSize: null };
  }

  async deleteCoverImage(): Promise<boolean> {
    return false;
  }

  async clearCoverImages(): Promise<void> {}
}

function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onloadend = () => {
      const result = reader.result as string;
      // Remove data URL prefix (e.g., "data:image/jpeg;base64,")
      const base64 = result.split(",")[1] ?? result;
      resolve(base64);
    };
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}

export class IosNativeImageCacheAdapter implements NativeImageCacheAdapter {
  constructor(private readonly plugin: AonsokuNativeDataPlugin) {}

  async downloadCoverImage(
    coverArtId: string,
    size: string,
  ): Promise<NativeCachedCoverImageFile | null> {
    const result = await this.plugin.downloadCoverImage({ coverArtId, size });
    return result.file;
  }

  async downloadAvatar(
    username: string,
    size: string,
  ): Promise<NativeCachedCoverImageFile | null> {
    const result = await this.plugin.downloadAvatar({ username, size });
    return result.file;
  }

  async storeCoverImage(
    coverArtId: string,
    data: Blob,
    contentType: string,
    coverSize: string,
  ): Promise<NativeCachedCoverImageFile | null> {
    const dataBase64 = await blobToBase64(data);
    const result = await this.plugin.storeCoverImage({
      coverArtId,
      dataBase64,
      contentType,
      coverSize,
    });
    return result.file;
  }

  async resolveCoverImage(
    coverArtId: string,
  ): Promise<NativeCachedCoverImageFile | null> {
    const result = await this.plugin.resolveCoverImage({ coverArtId });
    return result.file;
  }

  async getCoverImageSize(
    coverArtId: string,
  ): Promise<{ sizeBytes: number | null; coverSize: string | null }> {
    const result = await this.plugin.getCoverImageSize({ coverArtId });
    return {
      sizeBytes: result.sizeBytes,
      coverSize: result.coverSize,
    };
  }

  async deleteCoverImage(coverArtId: string): Promise<boolean> {
    const result = await this.plugin.deleteCoverImage({ coverArtId });
    return result.deleted;
  }

  async clearCoverImages(): Promise<void> {
    await this.plugin.clearCoverImages();
  }
}

let nativeImageCacheAdapter: NativeImageCacheAdapter | null = null;

export function getNativeImageCacheAdapter(): NativeImageCacheAdapter {
  if (nativeImageCacheAdapter) return nativeImageCacheAdapter;

  const availability = getNativeDataAvailability();
  if (availability.available) {
    if (!(nativeImageCacheAdapter instanceof IosNativeImageCacheAdapter)) {
      nativeImageCacheAdapter = new IosNativeImageCacheAdapter(
        availability.plugin,
      );
    }
    return nativeImageCacheAdapter;
  }

  // Plugin registration may not be visible during early app startup. Do not
  // permanently cache the null adapter or later native calls become no-ops.
  return new WebNullNativeImageCacheAdapter();
}

export function isNativeImageCacheAdapterAvailable(): boolean {
  return getNativeDataAvailability().available;
}

export function _resetNativeImageCacheAdapter(): void {
  nativeImageCacheAdapter = null;
}

export function _setNativeImageCacheAdapterForTests(
  adapter: NativeImageCacheAdapter | null,
): void {
  nativeImageCacheAdapter = adapter;
}
