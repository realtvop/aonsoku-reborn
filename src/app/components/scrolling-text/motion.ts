/**
 * Motion math for ScrollingText. Lengths are CSS pixels, times are seconds,
 * and positions are distances travelled from rest towards the start edge.
 */

/** Cruise speed of 16px text. Larger text moves faster, but sub-linearly. */
const BASE_SPEED = 32;
const BASE_FONT_SIZE = 16;
/** Seconds spent accelerating away from rest and decelerating back to it. */
export const RAMP_DURATION = 0.8;
const GAP_EM = 2.5;
const MIN_FADE = 10;
const MAX_FADE = 24;
const MAX_SETTLE_DURATION = 0.75;
const EPSILON = 1e-6;

/**
 * Exact quadratic curves: y = x² and y = 2x - x². Their slope at the joint
 * with the cruise segment is 2, the ratio between the cruise speed and the
 * average speed of a ramp, so velocity stays continuous between segments.
 */
export const EASE_IN_QUAD = "cubic-bezier(0.33333, 0, 0.66667, 0.33333)";
export const EASE_OUT_QUAD = "cubic-bezier(0.33333, 0.66667, 0.66667, 1)";
/** Ease-out used to return to rest when the text is hovered. */
export const SETTLE_EASE = "cubic-bezier(0.33, 1, 0.68, 1)";

export interface ScrollMetrics {
  /** Cruise speed in px/s. */
  speed: number;
  /** Space between the end of the text and its repeat. */
  gap: number;
  /** Width of the edge fades. */
  fade: number;
}

export interface ScrollPlan {
  /** Distance travelled in one cycle: the text width plus the gap. */
  distance: number;
  /** Cruise speed in px/s, lower than requested for very short distances. */
  speed: number;
  /** Duration of each ramp. */
  ramp: number;
  /** Duration of the whole cycle. */
  duration: number;
}

export interface ScrollKeyframe {
  offset: number;
  position: number;
  /** Easing of the segment that starts at this keyframe. */
  easing?: string;
}

function clamp(value: number, min: number, max: number) {
  return Math.min(Math.max(value, min), max);
}

export function getScrollMetrics(fontSize: number): ScrollMetrics {
  const size = fontSize > 0 ? fontSize : BASE_FONT_SIZE;

  return {
    speed: BASE_SPEED * Math.sqrt(size / BASE_FONT_SIZE),
    gap: GAP_EM * size,
    fade: clamp(size, MIN_FADE, MAX_FADE),
  };
}

/**
 * Rounds a length up to whole device pixels so the repeat starts on the same
 * sub-pixel phase as the original and the loop restarts without a shimmer.
 */
export function snapToDevicePixels(length: number, devicePixelRatio: number) {
  const ratio = devicePixelRatio > 0 ? devicePixelRatio : 1;

  return Math.ceil(length * ratio - EPSILON) / ratio;
}

/**
 * Plans one cycle as a quadratic ease-in, a constant cruise and a quadratic
 * ease-out. A distance too short to reach cruise speed accelerates and
 * decelerates at the same rate, meeting in the middle.
 */
export function planScroll(
  distance: number,
  speed: number,
  ramp = RAMP_DURATION,
): ScrollPlan {
  if (distance <= 0 || speed <= 0 || ramp <= 0) {
    return { distance: 0, speed: 0, ramp: 0, duration: 0 };
  }

  if (distance >= speed * ramp) {
    return { distance, speed, ramp, duration: distance / speed + ramp };
  }

  const acceleration = speed / ramp;
  const halfDuration = Math.sqrt(distance / acceleration);

  return {
    distance,
    speed: acceleration * halfDuration,
    ramp: halfDuration,
    duration: halfDuration * 2,
  };
}

function getRampDistance(plan: ScrollPlan) {
  return (plan.speed * plan.ramp) / 2;
}

export function getScrollKeyframes(plan: ScrollPlan): ScrollKeyframe[] {
  const { distance, ramp, duration } = plan;
  const rampDistance = getRampDistance(plan);

  if (duration <= 0) {
    return [
      { offset: 0, position: 0 },
      { offset: 1, position: distance },
    ];
  }

  if (distance - rampDistance * 2 < EPSILON) {
    return [
      { offset: 0, position: 0, easing: EASE_IN_QUAD },
      { offset: 0.5, position: distance / 2, easing: EASE_OUT_QUAD },
      { offset: 1, position: distance },
    ];
  }

  const rampOffset = ramp / duration;

  return [
    { offset: 0, position: 0, easing: EASE_IN_QUAD },
    { offset: rampOffset, position: rampDistance, easing: "linear" },
    {
      offset: 1 - rampOffset,
      position: distance - rampDistance,
      easing: EASE_OUT_QUAD,
    },
    { offset: 1, position: distance },
  ];
}

/** Distance from rest at `time` seconds into the cycle. */
export function getScrollPosition(plan: ScrollPlan, time: number) {
  const { distance, speed, ramp, duration } = plan;

  if (duration <= 0) return distance;

  const t = clamp(time, 0, duration);
  const acceleration = speed / ramp;
  const remaining = duration - t;

  if (t < ramp) return (acceleration * t * t) / 2;
  if (remaining < ramp) {
    return distance - (acceleration * remaining * remaining) / 2;
  }

  return getRampDistance(plan) + (t - ramp) * speed;
}

/**
 * Seconds the text needs to travel `distance` px away from rest. The cycle
 * is symmetric, so this is also how long before the end it is that far from
 * arriving back at rest.
 */
export function getTravelTime(plan: ScrollPlan, distance: number) {
  const { speed, ramp } = plan;

  if (plan.duration <= 0) return 0;

  const target = clamp(distance, 0, plan.distance / 2);
  const rampDistance = getRampDistance(plan);

  if (target <= rampDistance) return Math.sqrt((2 * ramp * target) / speed);

  return ramp + (target - rampDistance) / speed;
}

/** Duration of the return to rest, quick for short hops and capped. */
export function getSettleDuration(distance: number) {
  return Math.min(MAX_SETTLE_DURATION, 0.3 + Math.abs(distance) / 600);
}
