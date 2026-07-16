import {
  useContext,
  useEffect,
  useLayoutEffect,
  useRef,
  type ReactNode,
} from "react";
import {
  UNSAFE_LocationContext,
  useLocation,
  useMatches,
  useOutlet,
} from "react-router-dom";

/**
 * KeepAliveOutlet — a drop-in replacement for `<Outlet />` that keeps
 * previously-visited route subtrees mounted (but hidden) so that returning to
 * them is instant: already-loaded images, scroll position, and component
 * state are preserved instead of being re-fetched / re-created on every
 * navigation.
 *
 * Why context freezing is needed:
 * React Router provides the current `LocationContext` globally. A cached
 * page that is rendered hidden while the user is on a different route would
 * otherwise read the *active* route's location from `useLocation()` /
 * `useSearchParams()`, causing it to silently refetch with the wrong URL and
 * lose the very images we wanted to keep. To prevent that, every cached
 * subtree is re-wrapped in a frozen `UNSAFE_LocationContext.Provider` whose
 * value is the location the page had when it was last active. The per-route
 * `RouteContext` (params / matches) is already embedded in the element
 * returned by `useOutlet()`, so freezing `LocationContext` is sufficient to
 * make all router hooks inside a cached page return that page's own values.
 *
 * The active page is always rendered with its fresh outlet (and a
 * `LocationContext` value equal to the current global one), so it behaves
 * exactly like a plain `<Outlet />`. Hidden pages are kept in the tree with a
 * stable key and only their `display` is toggled, so React never unmounts
 * them across active ⇄ hidden transitions — preserving image `<img>` src/blob
 * URLs and component instances.
 *
 * Scroll handling:
 * The window scroll position is recorded per cached route and restored when
 * the user returns to it (0 for first visits). This replaces the
 * route-change "scroll to top" behavior: cached pages keep their position,
 * fresh pages still start at the top.
 */

interface KeepAliveOutletProps {
  /** Route ids that should never be cached (always remount, e.g. error page). */
  exclude?: string[];
  /** Route ids that are never evicted (pinned), e.g. the home page. */
  pin?: string[];
  /** Maximum number of simultaneously cached pages (LRU eviction). */
  max?: number;
}

interface CacheEntry {
  id: string;
  /** The `useOutlet()` element captured while this route was last active. */
  element: ReactNode | null;
  /** Frozen `LocationContext` value for this route (its own location). */
  locCtx: LocationContextValue;
}

type LocationContextValue = NonNullable<
  React.ContextType<typeof UNSAFE_LocationContext>
>;

const DEFAULT_MAX = 10;

export function KeepAliveOutlet({
  exclude = [],
  pin = [],
  max = DEFAULT_MAX,
}: KeepAliveOutletProps) {
  const outlet = useOutlet();
  const location = useLocation();
  const matches = useMatches();
  const leaf = matches[matches.length - 1];
  const currentId = (leaf?.id as string | undefined) ?? location.pathname;
  const currentLocCtx = useContext(UNSAFE_LocationContext);

  const cacheRef = useRef<CacheEntry[]>([]);
  const scrollRef = useRef<Map<string, number>>(new Map());
  const prevIdRef = useRef<string | null>(null);

  const cacheable =
    outlet != null && currentId != null && !exclude.includes(currentId);

  // Update / create the cache entry for the active route.
  // Mutating a ref during render is safe here: it is idempotent and only
  // advances state that is also reflected in the returned JSX below.
  if (cacheable && currentLocCtx != null) {
    const existing = cacheRef.current.find((e) => e.id === currentId);
    if (existing) {
      existing.element = outlet;
      existing.locCtx = currentLocCtx;
      // LRU: move to the tail so the oldest non-pinned entry is evicted first.
      const idx = cacheRef.current.indexOf(existing);
      if (idx >= 0 && idx !== cacheRef.current.length - 1) {
        cacheRef.current.splice(idx, 1);
        cacheRef.current.push(existing);
      }
    } else {
      cacheRef.current.push({
        id: currentId,
        element: outlet,
        locCtx: currentLocCtx,
      });
    }
    // Evict oldest non-pinned entries while over the cap. Pinned entries are
    // never evicted, so the home page (and any other pinned route) is retained.
    while (cacheRef.current.length > max) {
      const evictIdx = cacheRef.current.findIndex((e) => !pin.includes(e.id));
      if (evictIdx < 0) break;
      cacheRef.current.splice(evictIdx, 1);
    }
  }

  // Continuously record the active page's scroll position so it is already
  // up to date by the time the user navigates away.
  useEffect(() => {
    if (!cacheable) return;
    const save = () => scrollRef.current.set(currentId, window.scrollY);
    save();
    window.addEventListener("scroll", save, { passive: true });
    return () => window.removeEventListener("scroll", save);
  }, [currentId, cacheable]);

  // On route change, restore the newly-active page's scroll position
  // (before paint to avoid a flash). First visits scroll to the top.
  useLayoutEffect(() => {
    const prevId = prevIdRef.current;
    if (prevId != null && prevId !== currentId) {
      scrollRef.current.set(prevId, window.scrollY);
    }
    if (cacheable) {
      window.scrollTo(0, scrollRef.current.get(currentId) ?? 0);
    } else {
      window.scrollTo(0, 0);
    }
    prevIdRef.current = currentId;
  }, [currentId, cacheable]);

  // Excluded (or empty) routes render fresh, with no caching.
  if (!cacheable) {
    return <>{outlet}</>;
  }

  return (
    <>
      {cacheRef.current.map((entry) => {
        const active = entry.id === currentId;
        return (
          <UNSAFE_LocationContext.Provider key={entry.id} value={entry.locCtx}>
            <div
              style={active ? { display: "contents" } : { display: "none" }}
              aria-hidden={!active}
            >
              {entry.element}
            </div>
          </UNSAFE_LocationContext.Provider>
        );
      })}
    </>
  );
}
