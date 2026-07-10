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
import { useIsCoverCached } from "@/store/cache-index.store";
import { CoverArt } from "@/types/coverArtType";
import {
  getDefaultArtUrl,
  resolveCacheKeys,
  useCoverArtUrlFromSongPreference,
} from "@/utils/coverArt";

type LazyLoadImageProps = ComponentPropsWithoutRef<typeof LazyLoadImage>;

interface UseCoverArtCacheLookupOptions {
  coverArtId?: string;
  coverArtType?: CoverArt;
  albumId?: string;
  cacheArtSize?: string;
  autoCache?: boolean;
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
  const isPrimaryCached = useIsCoverCached(primaryCacheKey ?? "__none__");
  const [cachedUrl, setCachedUrl] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const pendingAutoCache = useRef<string | null>(null);
  const prevObjectUrl = useRef<string | null>(null);

  // biome-ignore lint/correctness/useExhaustiveDependencies: intentional — reset on primaryCacheKey change
  useEffect(() => {
    pendingAutoCache.current = null;
  }, [primaryCacheKey]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: isPrimaryCached triggers re-run when auto-cache completes; primaryCacheKey derives from cacheKeys
  useEffect(() => {
    if (cacheKeys.length === 0) {
      setCachedUrl(null);
      setIsLoading(false);
      return;
    }

    let cancelled = false;
    let objectUrl: string | null = null;
    setIsLoading(true);

    async function loadCache() {
      for (const key of cacheKeys) {
        try {
          const url = await cacheManager.getCachedCoverUrl(key, cacheArtSize);
          if (url) {
            if (cancelled) {
              URL.revokeObjectURL(url);
              return;
            }
            objectUrl = url;
            setCachedUrl(url);
            setIsLoading(false);
            return;
          }
        } catch (err) {
          console.warn(`[useCoverArtCacheLookup] cache error: key=${key}`, err);
        }
      }

      if (!cancelled) {
        setCachedUrl(null);
        setIsLoading(false);
        if (
          autoCache &&
          !isOffline &&
          primaryCacheKey &&
          pendingAutoCache.current !== primaryCacheKey
        ) {
          pendingAutoCache.current = primaryCacheKey;
          cacheManager
            .cacheCover(primaryCacheKey, cacheArtSize)
            .catch((err) => {
              console.warn(
                `[useCoverArtCacheLookup] auto-cache failed: ${primaryCacheKey}`,
                err,
              );
            });
        }
      }
    }

    loadCache();

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
    isPrimaryCached,
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

  return { cachedUrl, isOffline, isLoading };
}

export function useCachedCoverUrl(
  coverArtId: string | undefined,
  coverArtType: CoverArt | undefined,
  albumId: string | undefined,
  fallbackUrl: string,
  cacheArtSize = "700",
): string {
  const { cachedUrl, isOffline } = useCoverArtCacheLookup({
    coverArtId,
    coverArtType,
    albumId,
    cacheArtSize,
  });

  if (cachedUrl) return cachedUrl;
  if (isOffline) return getDefaultArtUrl(coverArtType);
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
}

export function CachedImage({
  coverArtId,
  coverArtType = "album",
  coverArtSize = "300",
  cacheArtSize,
  albumId,
  src: directSrc,
  autoCache = true,
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
  const [prevSrc, setPrevSrc] = useState<string | null>(null);

  const cacheKeys = useMemo(
    () => resolveCacheKeys(coverArtId, coverArtType, albumId),
    [coverArtId, coverArtType, albumId],
  );
  const primaryCacheKey = cacheKeys[0];

  // biome-ignore lint/correctness/useExhaustiveDependencies: intentional — reset on primaryCacheKey change
  useEffect(() => {
    setFailedNetworkSrc(null);
    setCachedSrcFailed(false);
  }, [primaryCacheKey]);

  const defaultArtUrl = getDefaultArtUrl(coverArtType);

  const showCachedImage = cachedSrc && !cachedSrcFailed;

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

  let resolvedSrc = showCachedImage ? cachedSrc : (directSrc ?? generatedSrc);

  if ((isOffline && !showCachedImage) || resolvedSrc === failedNetworkSrc) {
    resolvedSrc = defaultArtUrl;
  }

  // Reset loaded status synchronously during render on source change to prevent layout/placeholder flashes
  if (resolvedSrc !== prevSrc) {
    setPrevSrc(resolvedSrc);
    setIsLoaded(false);
  }

  const handleLoad = (e: React.SyntheticEvent<HTMLImageElement>) => {
    setIsLoaded(true);
    onLoad?.(e as never);
  };

  const handleError: React.ReactEventHandler<HTMLImageElement> = (e) => {
    const currentSrc = resolvedSrc;
    if (currentSrc) {
      if (currentSrc === cachedSrc) {
        setCachedSrcFailed(true);
      } else if (
        currentSrc !== defaultArtUrl &&
        currentSrc !== failedNetworkSrc
      ) {
        setFailedNetworkSrc(currentSrc);
      }
    }
    onError?.(e as never);
  };

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
      src={resolvedSrc}
      onError={handleError}
      onLoad={handleLoad}
      className={`${props.className ?? ""} bg-skeleton transition-opacity duration-300`}
      style={{ ...props.style, opacity: isLoaded ? 1 : 0 }}
    />
  );
}
