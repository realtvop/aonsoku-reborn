import {
  type HTMLAttributes,
  type ReactNode,
  useLayoutEffect,
  useRef,
} from "react";
import { cn } from "@/lib/utils";
import { ScrollingTextEngine } from "./engine";

export interface ScrollingTextProps extends HTMLAttributes<HTMLDivElement> {
  children: ReactNode;
  /** Seconds the text rests at its start before each scroll. */
  delay?: number;
  /** Scrolls per text before it stays at rest; resets when the text changes. */
  loop?: number;
  /**
   * Return to the start and hold while hovered or focused, so links inside
   * stay still under the pointer.
   */
  pauseOnHover?: boolean;
}

function makeInert(node: HTMLDivElement | null) {
  if (node) node.inert = true;
}

/**
 * Single-line text that scrolls when it does not fit. It rests at the start,
 * eases into a steady scroll and eases out as its repeat takes the
 * original's place, with soft fades at the clipped edges. Typography set on
 * the children drives speed, spacing and fade width.
 */
export function ScrollingText({
  children,
  className,
  delay = 2.5,
  loop = Number.POSITIVE_INFINITY,
  pauseOnHover = false,
  ...props
}: ScrollingTextProps) {
  const rootRef = useRef<HTMLDivElement>(null);
  const trackRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const engineRef = useRef<ScrollingTextEngine | null>(null);

  useLayoutEffect(() => {
    const root = rootRef.current;
    const track = trackRef.current;
    const content = contentRef.current;
    if (!root || !track || !content) return;

    const engine = new ScrollingTextEngine({ root, track, content });
    engineRef.current = engine;

    return () => {
      engine.destroy();
      engineRef.current = null;
    };
  }, []);

  useLayoutEffect(() => {
    engineRef.current?.configure({ delay, loop, pauseOnHover });
  }, [delay, loop, pauseOnHover]);

  // Parents re-render often (the mini player on every progress tick), so the
  // engine compares the rendered text instead of restarting on each render.
  useLayoutEffect(() => {
    engineRef.current?.syncContent();
  });

  return (
    <div
      data-testid="scrolling-text"
      {...props}
      ref={rootRef}
      className={cn("scrolling-text", className)}
    >
      <div ref={trackRef} className="scrolling-text-track">
        <div className="scrolling-text-item">
          <div ref={contentRef} className="scrolling-text-content">
            {children}
          </div>
        </div>
        <div
          ref={makeInert}
          className="scrolling-text-item scrolling-text-clone"
          aria-hidden="true"
        >
          <div className="scrolling-text-content">{children}</div>
        </div>
      </div>
    </div>
  );
}
