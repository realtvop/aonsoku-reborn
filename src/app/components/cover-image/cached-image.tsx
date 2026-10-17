import {
  ComponentPropsWithoutRef,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { LazyLoadImage } from "react-lazy-load-image-component";
import { cacheManager } from "@/service/cache";
import { useIsOfflineMode } from "@/store/cache.store";
import { useCoverCacheVersion } from "@/store/cache-index.store";
import { CoverArt } from "@/types/coverArtType";
import {
  resolveCacheKeys,
  useCoverArtUrlFromSongPreference,
} from "@/utils/coverArt";
import { DefaultCoverArt } from "./default-cover-art";

type LazyLoadImageProps = ComponentPropsWithoutRef<typeof LazyLoadImage>;

interface UseCoverArtCacheLookupOptions {
  coverArtId?: string;
  coverArtType?: CoverArt;
  albumId?: string;
  cacheArtSize?: string;
  autoCache?: boolean;
}

async function selectCachedCover(
  cacheKeys: string[],
  cacheArtSize: string,
  allowLowerResolution: boolean,
): Promise<{ key: string; url: string } | null> {
  async function findCachedUrl(allowLowerResolutionForLookup = false) {
    for (const key of cacheKeys) {
      try {
        const url = await cacheManager.getCachedCoverUrl(key, cacheArtSize, {
          allowLowerResolution: allowLowerResolutionForLookup,
        });
        if (url) return { key, url };
      } catch (err) {
        console.warn(`[useCoverArtCacheLookup] cache error: key=${key}`, err);
      }
    }
    return null;
  }

  // Check every candidate at the requested size before accepting a smaller
  // fallback. Online lookups stay strict so auto-cache can fetch an upgrade.
  const exactUrl = await findCachedUrl();
  return exactUrl ?? (allowLowerResolution ? await findCachedUrl(true) : null);
}

export async function selectCachedCoverUrl(
  cacheKeys: string[],
  cacheArtSize: string,
  allowLowerResolution: boolean,
): Promise<string | null> {
  return (
    (await selectCachedCover(cacheKeys, cacheArtSize, allowLowerResolution))
      ?.url ?? null
  );
}

function useCoverArtCacheLookup({
  coverArtId,
  coverArtType,
  albumId,
  cacheArtSize = "700",
  autoCache = true,
}: UseCoverArtCacheLookupOptions) {
  const cacheKeys = useMemo(
    () => resolveCacheKeys(coverArtId, coverArtType, albumId),
    [coverArtId, coverArtType, albumId],
  );
  const primaryCacheKey = cacheKeys[0];
  const isOffline = useIsOfflineMode();
  const cacheVersion = useCoverCacheVersion(cacheKeys);
  const [cachedUrl, setCachedUrl] = useState<string | null>(null);
  const [cachedKey, setCachedKey] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const pendingAutoCache = useRef<string | null>(null);
  const prevObjectUrl = useRef<string | null>(null);

  // biome-ignore lint/correctness/useExhaustiveDependencies: intentional — reset on primaryCacheKey change
  useEffect(() => {
    pendingAutoCache.current = null;
  }, [primaryCacheKey]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: cacheVersion triggers re-run when relevant cover content changes; primaryCacheKey derives from cacheKeys
  useEffect(() => {
    if (cacheKeys.length === 0) {
      setCachedUrl(null);
      setCachedKey(null);
      setIsLoading(false);
      return;
    }

    let cancelled = false;
    let objectUrl: string | null = null;
    setIsLoading(true);

    async function loadCache(allowAutoCache = autoCache, showLoading = true) {
      if (showLoading) setIsLoading(true);
      const selected = await selectCachedCover(
        cacheKeys,
        cacheArtSize,
        isOffline,
      );
      if (selected) {
        const { key, url } = selected;
        if (cancelled) {
          URL.revokeObjectURL(url);
          return;
        }
        objectUrl = url;
        setCachedUrl(url);
        setCachedKey(key);
        setIsLoading(false);
        return;
      }

      if (!cancelled) {
        setCachedUrl(null);
        setCachedKey(null);
        setIsLoading(false);
        if (
          allowAutoCache &&
          !isOffline &&
          primaryCacheKey &&
          pendingAutoCache.current !== primaryCacheKey
        ) {
          pendingAutoCache.current = primaryCacheKey;
          cacheManager
            .cacheCover(primaryCacheKey, cacheArtSize)
            .then(() => {
              if (!cancelled) {
                loadCache(false, false).catch(() => {});
              }
            })
            .catch((err) => {
              pendingAutoCache.current = null;
              console.warn(
                `[useCoverArtCacheLookup] auto-cache failed: ${primaryCacheKey}`,
                err,
              );
            });
        }
      }
    }

    loadCache().catch(() => {});

    return () => {
      cancelled = true;
      if (objectUrl) {
        if (prevObjectUrl.current && prevObjectUrl.current !== objectUrl) {
          URL.revokeObjectURL(prevObjectUrl.current);
        }
        prevObjectUrl.current = objectUrl;
      }
    };
  }, [
    cacheKeys,
    isOffline,
    cacheVersion,
    primaryCacheKey,
    cacheArtSize,
    autoCache,
  ]);

  useEffect(() => {
    return () => {
      if (prevObjectUrl.current) {
        URL.revokeObjectURL(prevObjectUrl.current);
      }
    };
  }, []);

  return { cachedKey, cachedUrl, isOffline, isLoading };
}

export function useCachedCoverUrl(
  coverArtId: string | undefined,
  coverArtType: CoverArt | undefined,
  albumId: string | undefined,
  fallbackUrl: string,
  cacheArtSize = "700",
): string | undefined {
  const { cachedUrl, isOffline } = useCoverArtCacheLookup({
    coverArtId,
    coverArtType,
    albumId,
    cacheArtSize,
  });

  if (cachedUrl) return cachedUrl;
  if (isOffline) return undefined;
  return fallbackUrl;
}

interface CachedImageProps extends Omit<LazyLoadImageProps, "src"> {
  coverArtId?: string;
  coverArtType?: CoverArt;
  coverArtSize?: string;
  cacheArtSize?: string;
  albumId?: string;
  src?: string;
  autoCache?: boolean;
  onFallback?: () => void;
}

const COVER_IMAGE_RETRY_DELAYS_MS = [1_000, 4_000, 12_000] as const;

export function CachedImage({
  coverArtId,
  coverArtType = "album",
  coverArtSize = "300",
  cacheArtSize,
  albumId,
  src: directSrc,
  autoCache = true,
  onFallback,
  onError,
  onLoad,
  ...props
}: CachedImageProps) {
  const generatedSrc = useCoverArtUrlFromSongPreference({
    coverArt: coverArtId,
    coverArtType,
    albumId,
    size: coverArtSize,
  });
  const {
    cachedKey,
    cachedUrl: cachedSrc,
    isOffline,
    isLoading,
  } = useCoverArtCacheLookup({
    coverArtId,
    coverArtType,
    albumId,
    cacheArtSize: cacheArtSize ?? coverArtSize,
    autoCache,
  });
  const [failedNetworkSrc, setFailedNetworkSrc] = useState<string | null>(null);
  const [cachedSrcFailed, setCachedSrcFailed] = useState(false);
  const [isLoaded, setIsLoaded] = useState(false);
  const [prevSrc, setPrevSrc] = useState<string | undefined>(undefined);
  const [retryNonce, setRetryNonce] = useState(0);
  const [retryAttempt, setRetryAttempt] = useState(0);
  const retryTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const invalidatingCachedSrc = useRef<string | null>(null);
  const rejectedCachedKey = useRef<string | null>(null);
  const cacheRecoveryScope = useRef(0);

  const cacheKeys = useMemo(
    () => resolveCacheKeys(coverArtId, coverArtType, albumId),
    [coverArtId, coverArtType, albumId],
  );
  const primaryCacheKey = cacheKeys[0];

  // biome-ignore lint/correctness/useExhaustiveDependencies: reset local failure state when the effective cover or connectivity changes
  useEffect(() => {
    cacheRecoveryScope.current++;
    invalidatingCachedSrc.current = null;
    rejectedCachedKey.current = null;
    setFailedNetworkSrc(null);
    setCachedSrcFailed(false);
    setRetryAttempt(0);
    setRetryNonce(0);
    if (retryTimer.current) {
      clearTimeout(retryTimer.current);
      retryTimer.current = null;
    }
  }, [primaryCacheKey, isOffline]);

  useEffect(() => {
    if (!cachedSrc) return;
    if (cachedKey && rejectedCachedKey.current === cachedKey) return;
    setCachedSrcFailed(false);
    setFailedNetworkSrc(null);
    setRetryAttempt(0);
  }, [cachedKey, cachedSrc]);

  useEffect(() => {
    return () => {
      cacheRecoveryScope.current++;
      if (retryTimer.current) clearTimeout(retryTimer.current);
    };
  }, []);

  const showCachedImage = cachedSrc && !cachedSrcFailed;

  let resolvedSrc = showCachedImage ? cachedSrc : (directSrc ?? generatedSrc);
  const showDefaultFallback =
    !isLoading &&
    (!resolvedSrc ||
      (isOffline && !showCachedImage) ||
      resolvedSrc === failedNetworkSrc);
  if (showDefaultFallback) {
    resolvedSrc = undefined;
  }

  useEffect(() => {
    if (showDefaultFallback) {
      onFallback?.();
    }
  }, [onFallback, showDefaultFallback]);

  // Reset loaded status synchronously during render on source change to prevent layout/placeholder flashes
  if (resolvedSrc !== prevSrc) {
    setPrevSrc(resolvedSrc);
    setIsLoaded(false);
  }

  const handleLoad = (e: React.SyntheticEvent<HTMLImageElement>) => {
    setIsLoaded(true);
    setRetryAttempt(0);
    if (retryTimer.current) {
      clearTimeout(retryTimer.current);
      retryTimer.current = null;
    }
    onLoad?.(e as never);
  };

  const handleError: React.ReactEventHandler<HTMLImageElement> = (e) => {
    const currentSrc = resolvedSrc;
    if (currentSrc) {
      if (currentSrc === cachedSrc) {
        if (
          cachedKey &&
          invalidatingCachedSrc.current !== currentSrc &&
          rejectedCachedKey.current !== cachedKey
        ) {
          const recoveryScope = cacheRecoveryScope.current;
          invalidatingCachedSrc.current = currentSrc;
          cacheManager
            .invalidateCachedCover(cachedKey, currentSrc)
            .then((invalidated) => {
              if (invalidated && cacheRecoveryScope.current === recoveryScope) {
                rejectedCachedKey.current = cachedKey;
                setCachedSrcFailed(true);
              }
            })
            .catch((err) => {
              if (cacheRecoveryScope.current === recoveryScope) {
                rejectedCachedKey.current = cachedKey;
                setCachedSrcFailed(true);
              }
              console.warn(
                `[CachedImage] failed to invalidate corrupt cache: key=${cachedKey}`,
                err,
              );
            })
            .finally(() => {
              if (invalidatingCachedSrc.current === currentSrc) {
                invalidatingCachedSrc.current = null;
              }
            });
        }
      } else if (currentSrc !== failedNetworkSrc) {
        setFailedNetworkSrc(currentSrc);
        if (
          retryAttempt < COVER_IMAGE_RETRY_DELAYS_MS.length &&
          !retryTimer.current
        ) {
          const nextAttempt = retryAttempt + 1;
          retryTimer.current = setTimeout(() => {
            retryTimer.current = null;
            setFailedNetworkSrc(null);
            setRetryAttempt(nextAttempt);
            setRetryNonce((nonce) => nonce + 1);
          }, COVER_IMAGE_RETRY_DELAYS_MS[retryAttempt]);
        }
      }
    }
    onError?.(e as never);
  };

  // Render a grey background skeleton during lookup if coverArtId is provided
  if (isLoading && coverArtId) {
    return (
      <div
        className={`${props.className ?? ""} bg-skeleton`}
        style={{
          width: props.width,
          height: props.height,
          ...props.style,
        }}
        data-testid="cached-image-skeleton"
      />
    );
  }

  if (showDefaultFallback) {
    return (
      // eslint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions
      <div
        className={
          (props as Record<string, unknown>).wrapperClassName as
            | string
            | undefined
        }
        style={props.style}
        onClick={props.onClick}
      >
        <DefaultCoverArt
          coverArtType={coverArtType}
          className={`${props.className ?? ""} transition-opacity duration-300`}
          width={props.width}
          height={props.height}
        />
      </div>
    );
  }

  if (showCachedImage) {
    return (
      // eslint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions
      <div
        className={
          (props as Record<string, unknown>).wrapperClassName as
            | string
            | undefined
        }
        style={props.style}
        onClick={props.onClick}
      >
        <img
          alt={props.alt}
          className={`${props.className ?? ""} bg-skeleton transition-opacity duration-300`}
          crossOrigin={props.crossOrigin}
          data-testid={props["data-testid"]}
          decoding="async"
          height={props.height}
          id={props.id}
          loading={props.loading ?? "lazy"}
          onError={handleError}
          onLoad={handleLoad}
          key={`${cachedSrc}:${retryNonce}`}
          src={cachedSrc}
          style={{ ...props.style, opacity: isLoaded ? 1 : 0 }}
          title={props.title}
          width={props.width}
        />
      </div>
    );
  }

  return (
    <LazyLoadImage
      {...props}
      key={`${resolvedSrc}:${retryNonce}`}
      src={resolvedSrc}
      onError={handleError}
      onLoad={handleLoad}
      className={`${props.className ?? ""} bg-skeleton transition-opacity duration-300`}
      style={{ ...props.style, opacity: isLoaded ? 1 : 0 }}
    />
  );
}
