import {
  EASE_IN_QUAD,
  EASE_OUT_QUAD,
  getScrollKeyframes,
  getScrollMetrics,
  getScrollPosition,
  getSettleDuration,
  getTravelTime,
  planScroll,
  SETTLE_EASE,
  type ScrollPlan,
  snapToDevicePixels,
} from "./motion";

const FADE_START_PROPERTY = "--scrolling-text-fade-start";
const FADE_END_PROPERTY = "--scrolling-text-fade-end";
const PERIOD_PROPERTY = "--scrolling-text-period";
/** Overflow below this is sub-pixel rounding rather than truncated text. */
const OVERFLOW_TOLERANCE = 0.5;
const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)";

export interface ScrollingTextOptions {
  /** Seconds at rest before each scroll. */
  delay: number;
  /** Scrolls per text before it stays at rest. */
  loop: number;
  /** Return to rest and hold while hovered or focused. */
  pauseOnHover: boolean;
}

export interface ScrollingTextElements {
  root: HTMLElement;
  /** Holds the content and its repeat; the only element that moves. */
  track: HTMLElement;
  /** The original copy of the content, used for measuring. */
  content: HTMLElement;
}

type Phase = "idle" | "waiting" | "scrolling" | "settling";

interface ScrollLayout {
  /** Distance between the content and its repeat. */
  period: number;
  speed: number;
  fade: number;
}

function translate(position: number) {
  return `translate3d(${-position}px, 0, 0)`;
}

function getAlignment(textAlign: string) {
  if (textAlign === "center" || textAlign === "-webkit-center") {
    return "center";
  }
  if (textAlign === "right" || textAlign === "end") return "end";

  return "start";
}

/** Clicking a link also focuses it; only keyboard focus should hold. */
function isFocusVisible(target: EventTarget | null) {
  try {
    return Boolean((target as Element | null)?.matches(":focus-visible"));
  } catch {
    return true;
  }
}

/** Font size of the first visible text, wherever the caller styled it. */
function getTextFontSize(content: HTMLElement, view: Window) {
  const walker = content.ownerDocument.createTreeWalker(
    content,
    NodeFilter.SHOW_TEXT,
  );
  let node = walker.nextNode();

  while (node && !node.textContent?.trim()) {
    node = walker.nextNode();
  }

  const element = node?.parentElement ?? content;

  return Number.parseFloat(view.getComputedStyle(element).fontSize);
}

/**
 * Drives one ScrollingText. When the content overflows, it rests at the
 * start, then scrolls until the repeat takes the original's place, so every
 * cycle ends exactly where it began. The motion is a Web Animation of
 * `transform`, which browsers run off the main thread; the edge fade follows
 * it with two short animations of a registered custom property.
 */
export class ScrollingTextEngine {
  private readonly root: HTMLElement;
  private readonly track: HTMLElement;
  private readonly content: HTMLElement;
  private readonly view: Window & typeof globalThis;
  private readonly resizeObserver: ResizeObserver | null;
  private readonly reducedMotion: MediaQueryList | null;
  private options: ScrollingTextOptions | null = null;
  private layout: ScrollLayout | null = null;
  private text: string | null;
  private phase: Phase = "idle";
  private cyclesLeft = 0;
  private timer: number | undefined;
  private plan: ScrollPlan | null = null;
  private animations: Animation[] = [];
  private hovered = false;
  private focused = false;
  private destroyed = false;

  constructor({ root, track, content }: ScrollingTextElements) {
    this.root = root;
    this.track = track;
    this.content = content;
    // The mini player renders into a Picture-in-Picture document, so observe
    // and measure through the element's own window.
    this.view = (root.ownerDocument.defaultView ?? window) as Window &
      typeof globalThis;
    this.text = content.textContent;

    this.resizeObserver =
      typeof this.view.ResizeObserver === "function"
        ? new this.view.ResizeObserver(this.handleResize)
        : null;
    this.resizeObserver?.observe(root);
    this.resizeObserver?.observe(content);

    this.reducedMotion =
      typeof this.view.matchMedia === "function"
        ? this.view.matchMedia(REDUCED_MOTION_QUERY)
        : null;
    this.reducedMotion?.addEventListener("change", this.handleMotionPreference);

    root.addEventListener("pointerenter", this.handlePointerEnter);
    root.addEventListener("pointerleave", this.handlePointerLeave);
    root.addEventListener("focusin", this.handleFocusIn);
    root.addEventListener("focusout", this.handleFocusOut);

    this.setPhase("idle");
    this.measure();
  }

  configure(options: ScrollingTextOptions) {
    const previous = this.options;
    this.options = options;

    if (!previous || previous.loop !== options.loop) {
      this.cyclesLeft = options.loop;
    }
    if (previous && previous.delay !== options.delay) {
      if (this.phase === "waiting") this.stop();
    }

    this.applyHold();
  }

  /** Call after every render: restarts only when the text itself changed. */
  syncContent() {
    const text = this.content.textContent;
    if (text === this.text) return;

    this.text = text;
    this.stop();
    this.cyclesLeft = this.options?.loop ?? 0;
    this.measure();
    this.schedule();
  }

  destroy() {
    this.destroyed = true;
    this.stop();
    this.resizeObserver?.disconnect();
    this.reducedMotion?.removeEventListener(
      "change",
      this.handleMotionPreference,
    );
    this.root.removeEventListener("pointerenter", this.handlePointerEnter);
    this.root.removeEventListener("pointerleave", this.handlePointerLeave);
    this.root.removeEventListener("focusin", this.handleFocusIn);
    this.root.removeEventListener("focusout", this.handleFocusOut);
  }

  private get held() {
    return Boolean(
      this.options?.pauseOnHover && (this.hovered || this.focused),
    );
  }

  private canAnimate() {
    return (
      !this.destroyed &&
      this.layout !== null &&
      !this.reducedMotion?.matches &&
      typeof this.track.animate === "function"
    );
  }

  private measure() {
    if (this.destroyed) return;

    const rootStyle = this.view.getComputedStyle(this.root);
    const containerWidth = Number.parseFloat(rootStyle.width) || 0;
    const contentWidth =
      Number.parseFloat(this.view.getComputedStyle(this.content).width) || 0;
    const align = getAlignment(rootStyle.textAlign);

    if (this.root.dataset.align !== align) this.root.dataset.align = align;

    if (contentWidth - containerWidth <= OVERFLOW_TOLERANCE) {
      if (this.layout) {
        this.layout = null;
        this.stop();
        this.root.removeAttribute("data-overflowing");
      }
      return;
    }

    const metrics = getScrollMetrics(getTextFontSize(this.content, this.view));
    const period = snapToDevicePixels(
      contentWidth + metrics.gap,
      this.view.devicePixelRatio,
    );
    const previous = this.layout;
    this.layout = { period, speed: metrics.speed, fade: metrics.fade };

    if (previous?.period !== period) {
      this.root.style.setProperty(PERIOD_PROPERTY, `${period}px`);
    }
    if (previous?.fade !== metrics.fade) {
      this.root.style.setProperty(FADE_END_PROPERTY, `${metrics.fade}px`);
    }

    if (!previous) {
      this.root.setAttribute("data-overflowing", "");
      this.cyclesLeft = this.options?.loop ?? 0;
      this.schedule();
      return;
    }

    // The text itself changed size (a web font loaded, a breakpoint changed
    // the font size): a cycle in flight no longer lines up, so start over.
    const resized =
      previous.period !== period || previous.speed !== metrics.speed;
    if (resized && (this.phase === "scrolling" || this.phase === "settling")) {
      this.stop();
      this.schedule();
    }
  }

  private schedule() {
    if (
      this.phase !== "idle" ||
      !this.options ||
      this.held ||
      this.cyclesLeft <= 0 ||
      !this.canAnimate()
    ) {
      return;
    }

    this.setPhase("waiting");
    this.timer = this.view.setTimeout(() => {
      this.timer = undefined;
      this.setPhase("idle");
      this.startCycle();
    }, Math.max(0, this.options.delay) * 1000);
  }

  private startCycle() {
    const layout = this.layout;
    if (!layout || this.held || !this.canAnimate()) return;

    const plan = planScroll(layout.period, layout.speed);
    const duration = plan.duration * 1000;
    const fadeDuration = getTravelTime(plan, layout.fade) * 1000;
    const keyframes = getScrollKeyframes(plan).map(
      ({ offset, position, easing }) => ({
        offset,
        easing,
        transform: translate(position),
      }),
    );

    const motion = this.track.animate(keyframes, { duration });
    // The left fade grows as the text leaves the edge and shrinks as the
    // repeat arrives, so no glyph at rest is ever faded.
    const fadeIn = this.animateFade(0, layout.fade, {
      duration: fadeDuration,
      easing: EASE_IN_QUAD,
    });
    const fadeOut = this.animateFade(layout.fade, 0, {
      delay: duration - fadeDuration,
      duration: fadeDuration,
      easing: EASE_OUT_QUAD,
    });

    this.plan = plan;
    this.trackAnimations(motion, fadeIn, fadeOut);
    this.setPhase("scrolling");

    motion.onfinish = () => {
      // The repeat now sits where the original started, so dropping the
      // animation back to translate(0) is seamless.
      this.stop();
      this.cyclesLeft -= 1;
      this.schedule();
    };
  }

  /** Returns to rest by the shorter way: back to the start, or forward to the repeat. */
  private settle() {
    const layout = this.layout;
    const motion = this.animations[0];
    const elapsed = motion?.currentTime;

    if (!layout || !this.plan || typeof elapsed !== "number") {
      this.stop();
      return;
    }

    const position = getScrollPosition(this.plan, elapsed / 1000);
    const fade =
      Number.parseFloat(
        this.view
          .getComputedStyle(this.root)
          .getPropertyValue(FADE_START_PROPERTY),
      ) || 0;
    const target = position > layout.period / 2 ? layout.period : 0;
    const duration = getSettleDuration(target - position) * 1000;

    this.stop();

    const settle = this.track.animate(
      [{ transform: translate(position) }, { transform: translate(target) }],
      { duration, easing: SETTLE_EASE },
    );
    const fadeOut = this.animateFade(fade, 0, {
      duration,
      easing: SETTLE_EASE,
    });

    this.trackAnimations(settle, fadeOut);
    this.setPhase("settling");

    settle.onfinish = () => {
      this.stop();
      this.schedule();
    };
  }

  private animateFade(
    from: number,
    to: number,
    timing: KeyframeAnimationOptions,
  ) {
    try {
      return this.root.animate(
        [
          { [FADE_START_PROPERTY]: `${from}px` },
          { [FADE_START_PROPERTY]: `${to}px` },
        ],
        { ...timing, fill: "forwards" },
      );
    } catch {
      // Without animatable custom properties the text only loses its left
      // fade; the motion itself is unaffected.
      return null;
    }
  }

  private trackAnimations(...animations: Array<Animation | null>) {
    this.animations = animations.filter(
      (animation): animation is Animation => animation !== null,
    );
  }

  /** Cancels any motion and returns to rest without a transition. */
  private stop() {
    if (this.timer !== undefined) {
      this.view.clearTimeout(this.timer);
      this.timer = undefined;
    }

    for (const animation of this.animations) {
      animation.onfinish = null;
      animation.cancel();
    }

    this.animations = [];
    this.plan = null;
    this.setPhase("idle");
  }

  private applyHold() {
    if (!this.held) {
      this.schedule();
      return;
    }

    if (this.phase === "waiting") this.stop();
    if (this.phase === "scrolling") this.settle();
  }

  private setPhase(phase: Phase) {
    this.phase = phase;
    this.root.dataset.phase = phase;
  }

  private readonly handleResize = () => {
    this.measure();
  };

  private readonly handleMotionPreference = () => {
    if (this.reducedMotion?.matches) {
      this.stop();
    } else {
      this.schedule();
    }
  };

  private readonly handlePointerEnter = (event: PointerEvent) => {
    // Touch has no hover; a tap must not freeze the text.
    if (event.pointerType === "touch") return;

    this.hovered = true;
    this.applyHold();
  };

  private readonly handlePointerLeave = () => {
    if (!this.hovered) return;

    this.hovered = false;
    this.applyHold();
  };

  private readonly handleFocusIn = (event: FocusEvent) => {
    if (!isFocusVisible(event.target)) return;

    this.focused = true;
    this.applyHold();
  };

  private readonly handleFocusOut = (event: FocusEvent) => {
    if (!this.focused) return;
    if (this.root.contains(event.relatedTarget as Node | null)) return;

    this.focused = false;
    this.applyHold();
  };
}
