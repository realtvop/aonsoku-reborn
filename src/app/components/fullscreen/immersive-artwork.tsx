import { App } from "@capacitor/app";
import { Capacitor } from "@capacitor/core";
import { useReducedMotion } from "framer-motion";
import { type ReactNode, useEffect, useRef, useState } from "react";
import { type DynamicCoverHandle, dynamicCover } from "@/native/artwork";
import { renderArtworkRegion } from "./artwork-region-renderer";

const rank = { static: 0, camera: 1, depth: 2 };

// A wide, continuous Perlin smootherstep (6t^5 - 15t^4 + 10t^3) transition across 20%
// ensuring zero slope/knee at both the opaque central core (60%) and the outer perimeter.
// This prevents any visible transition boundary even on static freeze-frames during pause.
const edgeFade =
  "transparent 0%, rgba(0,0,0,0.01) 2%, rgba(0,0,0,0.06) 4%, rgba(0,0,0,0.2) 7%, rgba(0,0,0,0.5) 10%, rgba(0,0,0,0.8) 13%, rgba(0,0,0,0.94) 16%, rgba(0,0,0,0.99) 18%, black 20%, black 80%, rgba(0,0,0,0.99) 82%, rgba(0,0,0,0.94) 84%, rgba(0,0,0,0.8) 87%, rgba(0,0,0,0.5) 90%, rgba(0,0,0,0.2) 93%, rgba(0,0,0,0.06) 96%, rgba(0,0,0,0.01) 98%, transparent 100%";
const edgeMask = `linear-gradient(to right, ${edgeFade}), linear-gradient(to bottom, ${edgeFade})`;

// Defocus cushion mask directly behind the foreground feather zone (-inset-[12%])
const cushionFade =
  "transparent 0%, rgba(0,0,0,0.12) 4%, rgba(0,0,0,0.45) 10%, rgba(0,0,0,0.85) 18%, black 26%, black 74%, rgba(0,0,0,0.85) 82%, rgba(0,0,0,0.45) 90%, rgba(0,0,0,0.12) 96%, transparent 100%";
const cushionMask = `linear-gradient(to right, ${cushionFade}), linear-gradient(to bottom, ${cushionFade})`;

/**
 * Mirror perimeter size ratio relative to the outer container.
 * Adjust this value to manually control the width of the mirrored perimeter:
 * - 0.15 = 15% mirror width
 * - 0.20 = 20% mirror width (matches the 20% edgeMask feathering zone exactly,
 *               leaving the central 60% cover 100% opaque and pristine)
 * - 0.25 = 25% wide mirror
 */
export const DYNAMIC_ARTWORK_MIRROR_RATIO = 0.04;

/**
 * Visual scale multiplier for the dynamic artwork presentation.
 * Adjust this value to manually resize the dynamic cover:
 * - 1.0  = 100% (original base size)
 * - 1.15 = 115% (current enlarged presentation, compensates for outer edge feathering)
 * - 1.25 = 125% (extra large)
 */
export const DYNAMIC_ARTWORK_SCALE = 1.15;

type Demand = Awaited<ReturnType<typeof dynamicCover.requestGeneration>>;

/** A square display mask over leased files. It never requests pixel dimensions. */
export function ImmersiveArtwork({
  coverArtId,
  active,
  playing,
  children,
  halo,
  scale = DYNAMIC_ARTWORK_SCALE,
  mirrorRatio = DYNAMIC_ARTWORK_MIRROR_RATIO,
}: {
  coverArtId: string;
  active: boolean;
  playing: boolean;
  children: ReactNode;
  halo: ReactNode;
  scale?: number;
  mirrorRatio?: number;
}) {
  const element = useRef<HTMLDivElement>(null);
  const [intersects, setIntersects] = useState(true);
  const [foreground, setForeground] = useState(
    document.visibilityState !== "hidden",
  );
  const [resumeRevision, setResumeRevision] = useState(0);
  const reduced = useReducedMotion() ?? false;
  const mode = playing && !reduced ? "dynamic" : "static";
  const modeRef = useRef<"dynamic" | "static">(mode);
  modeRef.current = mode;
  const [clips, setClips] = useState<DynamicCoverHandle[]>([]);
  const [displayId, setDisplayId] = useState<string>();
  const [nativeMotion, setNativeMotion] = useState({
    mode: "static",
    allowed: false,
  });
  const display = useRef<DynamicCoverHandle | undefined>(undefined);
  const leases = useRef(new Set<DynamicCoverHandle>());
  const currentCover = useRef(coverArtId);
  currentCover.current = coverArtId;
  const visible = active && intersects && foreground;

  useEffect(() => {
    let disposed = false;
    let nativeActive = true;
    const update = () => {
      if (disposed) return;
      const foreground = nativeActive && document.visibilityState !== "hidden";
      setForeground(foreground);
      // WebKit may pause media without changing our last rendered visibility.
      // An explicit resume must retry playback even if canMove stays true.
      if (foreground) setResumeRevision((revision) => revision + 1);
    };
    document.addEventListener("visibilitychange", update);
    window.addEventListener("pageshow", update);
    window.addEventListener("focus", update);
    const appStateHandle = Capacitor.isNativePlatform()
      ? App.addListener("appStateChange", ({ isActive }) => {
          nativeActive = isActive;
          update();
        }).catch((error: unknown) => {
          console.warn("[ImmersiveArtwork] App state listener failed", error);
        })
      : undefined;
    const observer =
      typeof IntersectionObserver !== "undefined"
        ? new IntersectionObserver(([entry]) => {
            setIntersects(entry.isIntersecting);
          })
        : undefined;
    if (element.current) observer?.observe(element.current);
    return () => {
      disposed = true;
      document.removeEventListener("visibilitychange", update);
      window.removeEventListener("pageshow", update);
      window.removeEventListener("focus", update);
      appStateHandle?.then((handle) => handle?.remove()).catch(() => {});
      observer?.disconnect();
    };
  }, []);

  useEffect(() => {
    if (!visible || !coverArtId) return;
    let canceled = false;
    let timer: ReturnType<typeof setTimeout>;
    let demand: Demand;
    let requestedMode: string | undefined;
    let candidate: DynamicCoverHandle | undefined;
    const release = (clip: DynamicCoverHandle) => {
      leases.current.delete(clip);
      clip.release().catch(() => {});
    };
    const poll = async () => {
      try {
        const mode = modeRef.current;
        const result = await dynamicCover.acquire({
          coverArtId,
          format: "any",
          mode,
        });
        if (canceled) {
          if (result.status === "ready") await result.release();
          return;
        }
        setNativeMotion({
          mode,
          allowed:
            result.motionAllowed ??
            (result.status === "ready" && result.stage !== "static"),
        });
        if (result.status === "ready") {
          const current =
            candidate && leases.current.has(candidate)
              ? candidate
              : display.current;
          if (
            current?.assetId === result.assetId ||
            (current && rank[result.stage] < rank[current.stage])
          ) {
            await result.release();
          } else {
            if (candidate && candidate !== display.current) release(candidate);
            candidate = result;
            leases.current.add(result);
            setClips(display.current ? [display.current, result] : [result]);
          }
        }
        // Explicit intent is separate from acquire. The native producer checks
        // existing assets before deciding whether any work is actually needed.
        if (!demand || requestedMode !== mode) {
          const next = await dynamicCover.requestGeneration({
            coverArtId,
            mode,
          });
          if (canceled) {
            await next?.release();
            return;
          }
          const old = demand;
          demand = next;
          requestedMode = mode;
          await old?.release();
        }
      } catch {
        // Original artwork remains usable while the native host is unavailable.
      } finally {
        if (!canceled) timer = setTimeout(poll, 1000);
      }
    };
    poll();
    return () => {
      canceled = true;
      clearTimeout(timer);
      demand?.release().catch(() => {});
      for (const clip of leases.current) release(clip);
      display.current = undefined;
      setDisplayId(undefined);
      setClips([]);
    };
  }, [visible, coverArtId]);

  const canMove =
    visible &&
    playing &&
    !reduced &&
    nativeMotion.mode === "dynamic" &&
    nativeMotion.allowed;
  // biome-ignore lint/correctness/useExhaustiveDependencies: Resume events and clip mounts must retry even when canMove is unchanged.
  useEffect(() => {
    // Include the resume signal and actual elements: neither an unchanged
    // permission nor an unchanged asset ID proves the video is still playing.
    const cleanups: (() => void)[] = [];
    for (const video of element.current?.querySelectorAll("video") ?? []) {
      if (!canMove || video.dataset.stage === "static") {
        video.pause();
        continue;
      }
      let disposed = false;
      let pending = false;
      let attempts = 0;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const delays = [300, 1000, 2500];
      const retry = () => {
        if (disposed || timer || attempts > delays.length) return;
        timer = setTimeout(
          () => {
            timer = undefined;
            play();
          },
          delays[Math.max(0, attempts - 1)],
        );
      };
      const play = () => {
        if (disposed || pending || !video.paused || attempts > delays.length)
          return;
        pending = true;
        attempts += 1;
        video
          .play()
          .catch((error: unknown) => {
            if (!disposed && attempts > delays.length) {
              console.warn("[ImmersiveArtwork] Video resume failed", error);
            }
          })
          .finally(() => {
            pending = false;
            if (video.paused) retry();
          });
      };
      const didPlay = () => {
        attempts = 0;
        clearTimeout(timer);
        timer = undefined;
      };
      video.addEventListener("canplay", play);
      video.addEventListener("pause", retry);
      video.addEventListener("playing", didPlay);
      play();
      cleanups.push(() => {
        disposed = true;
        clearTimeout(timer);
        video.removeEventListener("canplay", play);
        video.removeEventListener("pause", retry);
        video.removeEventListener("playing", didPlay);
      });
    }
    return () => {
      for (const cleanup of cleanups) cleanup();
    };
  }, [canMove, clips, resumeRevision]);

  function ready(clip: DynamicCoverHandle, video: HTMLVideoElement) {
    if (!leases.current.has(clip) || clip.coverArtId !== currentCover.current)
      return;
    const old = display.current;
    display.current = clip;
    setDisplayId(clip.leaseId);
    setClips([clip]);
    // Updating clips runs the playback effect after this element is mounted.
    if (!canMove || clip.stage === "static") video.pause();
    if (old && old !== clip) {
      leases.current.delete(old);
      old.release().catch(() => {});
    }
  }

  const canvasRef = useRef<HTMLCanvasElement>(null);
  const sourceRef = useRef<HTMLDivElement>(null);
  const [composed, setComposed] = useState(false);

  useEffect(() => {
    if (!visible || !canvasRef.current || !sourceRef.current) return;
    return renderArtworkRegion(
      canvasRef.current,
      sourceRef.current,
      mirrorRatio,
      () => setComposed(true),
    );
  }, [visible, mirrorRatio]);

  const centerInset = `${(mirrorRatio * 100).toFixed(4)}%`;

  return (
    <div
      ref={element}
      className="relative isolate size-full aspect-square transition-transform duration-500 ease-out"
      style={{
        transform: `scale(${scale})`,
        transformOrigin: "center center",
      }}
    >
      {/* Defocus cushion directly under the artwork feather zone */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute -inset-[12%] z-[1] select-none"
        style={{
          maskImage: cushionMask,
          maskComposite: "intersect",
          WebkitMaskImage: cushionMask,
          WebkitMaskComposite: "source-in",
        }}
      >
        <div className="size-full blur-2xl opacity-95 scale-106">{halo}</div>
      </div>

      {/* Layer 2: Foreground artwork with wide, dreamy transition into the blur */}
      <div
        className="relative z-[2] size-full overflow-hidden"
        style={{
          maskImage: edgeMask,
          maskComposite: "intersect",
          WebkitMaskImage: edgeMask,
          WebkitMaskComposite: "source-in",
        }}
      >
        {/* Central content and all reflections share the same composed frame. */}
        <canvas
          ref={canvasRef}
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 size-full select-none z-[3]"
        />

        {/* Media/placeholder sources remain mounted for loading and decoding. */}
        <div
          ref={sourceRef}
          className="pointer-events-auto absolute overflow-hidden z-[2]"
          style={{ inset: centerInset, opacity: composed ? 0 : 1 }}
        >
          {children}
          {clips
            .filter((clip) => clip.coverArtId === coverArtId)
            .map((clip) => (
              <video
                key={clip.leaseId}
                src={clip.src}
                muted
                playsInline
                loop
                preload="auto"
                aria-hidden="true"
                data-stage={clip.stage}
                data-lease-id={clip.leaseId}
                className="pointer-events-none absolute inset-0 size-full object-cover transition-opacity duration-1000 ease-in-out"
                style={{ opacity: displayId === clip.leaseId ? 1 : 0 }}
                onLoadedData={(event) => ready(clip, event.currentTarget)}
                onError={() => {
                  leases.current.delete(clip);
                  clip.release().catch(() => {});
                  if (display.current === clip) {
                    display.current = undefined;
                    setDisplayId(undefined);
                  }
                  setClips((items) => items.filter((item) => item !== clip));
                }}
              />
            ))}
        </div>
      </div>
    </div>
  );
}
