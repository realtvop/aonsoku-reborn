import { motion, useAnimationControls } from "framer-motion";
import { ReactNode, useEffect } from "react";
import { useTextOverflow } from "@/app/hooks/use-text-overflow";

interface ScrollingTitleProps {
  children: ReactNode;
}

const SCROLL_SPEED = 30;
const INITIAL_DELAY = 2;
const PAUSE_DURATION = 3;
const TEXT_GAP = 80;
const FADE_WIDTH = 20;

const MASK_STYLE = {
  left: -FADE_WIDTH,
  right: 0,
  maskImage: `linear-gradient(90deg, transparent 0px, rgb(0, 0, 0) ${FADE_WIDTH}px, rgb(0, 0, 0) calc(100% - ${FADE_WIDTH}px), transparent 100%)`,
} as const;

function createScrollAnimation(scrollDistance: number) {
  const duration = scrollDistance / SCROLL_SPEED;
  return {
    x: [0, -scrollDistance],
    transition: {
      duration,
      ease: "linear",
    } as const,
  };
}

export function ScrollingTitle({ children }: ScrollingTitleProps) {
  const { containerRef, textRef, overflow, calculateOverflow } =
    useTextOverflow();
  const controls = useAnimationControls();

  // biome-ignore lint/correctness/useExhaustiveDependencies: need children to reset animation on content change
  useEffect(() => {
    controls.set({ x: 0 });
    calculateOverflow();
  }, [children, controls, calculateOverflow]);

  useEffect(() => {
    if (!overflow.isOverflowing || overflow.width <= 0) return;

    const scrollDistance = overflow.width + TEXT_GAP;
    const animation = createScrollAnimation(scrollDistance);
    let isCancelled = false;
    const timeoutIds: ReturnType<typeof setTimeout>[] = [];

    async function runAnimation() {
      await new Promise<void>((resolve) => {
        timeoutIds.push(setTimeout(resolve, INITIAL_DELAY * 1000));
      });

      while (!isCancelled) {
        await controls.start({
          x: animation.x,
          transition: animation.transition,
        });

        if (isCancelled) break;

        controls.set({ x: 0 });

        await new Promise<void>((resolve) => {
          timeoutIds.push(setTimeout(resolve, PAUSE_DURATION * 1000));
        });

        if (isCancelled) break;
      }
    }

    runAnimation();

    return () => {
      isCancelled = true;
      timeoutIds.forEach(clearTimeout);
      controls.stop();
      controls.set({ x: 0 });
    };
  }, [overflow.isOverflowing, overflow.width, controls]);

  if (!overflow.isOverflowing) {
    return (
      <div
        ref={containerRef}
        className="w-full min-w-0 overflow-hidden"
        data-testid="scrolling-title"
      >
        <div ref={textRef} className="inline-block whitespace-nowrap">
          {children}
        </div>
      </div>
    );
  }

  return (
    <div
      ref={containerRef}
      className="relative w-full min-w-0 overflow-hidden"
      style={{
        minHeight: overflow.height > 0 ? `${overflow.height}px` : undefined,
      }}
      data-testid="scrolling-title"
    >
      <div
        className="absolute inset-y-0 overflow-hidden"
        style={MASK_STYLE}
        aria-hidden
      >
        <motion.div
          animate={controls}
          className="inline-flex whitespace-nowrap"
          style={{ marginLeft: FADE_WIDTH }}
        >
          <div ref={textRef}>{children}</div>
          <div style={{ paddingLeft: TEXT_GAP }} aria-hidden>
            {children}
          </div>
        </motion.div>
      </div>
    </div>
  );
}
