import { describe, expect, it } from "vitest";
import {
  EASE_IN_QUAD,
  EASE_OUT_QUAD,
  getScrollKeyframes,
  getScrollMetrics,
  getScrollPosition,
  getSettleDuration,
  getTravelTime,
  planScroll,
  RAMP_DURATION,
  snapToDevicePixels,
} from "./motion";

function speedAt(plan: ReturnType<typeof planScroll>, time: number) {
  const step = 1e-4;
  return (
    (getScrollPosition(plan, time + step) -
      getScrollPosition(plan, time - step)) /
    (step * 2)
  );
}

describe("getScrollMetrics", () => {
  it("scales speed sub-linearly and spacing linearly with the font size", () => {
    const small = getScrollMetrics(14);
    const large = getScrollMetrics(30);

    expect(small.speed).toBeCloseTo(29.93, 2);
    expect(large.speed).toBeCloseTo(43.82, 2);
    expect(large.speed / small.speed).toBeLessThan(30 / 14);
    expect(small.gap).toBe(35);
    expect(large.gap).toBe(75);
  });

  it("keeps the fade width within readable bounds", () => {
    expect(getScrollMetrics(8).fade).toBe(10);
    expect(getScrollMetrics(14).fade).toBe(14);
    expect(getScrollMetrics(40).fade).toBe(24);
  });

  it("falls back to 16px for an unusable font size", () => {
    expect(getScrollMetrics(Number.NaN)).toEqual(getScrollMetrics(16));
  });
});

describe("snapToDevicePixels", () => {
  it("rounds up to whole device pixels", () => {
    expect(snapToDevicePixels(100.2, 1)).toBe(101);
    expect(snapToDevicePixels(100.2, 2)).toBe(100.5);
    expect(snapToDevicePixels(100, 2)).toBe(100);
    expect(snapToDevicePixels(100.1, 1.5) * 1.5).toBeCloseTo(151, 10);
  });

  it("ignores floating-point noise just above a whole pixel", () => {
    expect(snapToDevicePixels(100 + 1e-9, 1)).toBe(100);
  });
});

describe("planScroll", () => {
  it("adds one ramp to the cruise time", () => {
    const plan = planScroll(240, 30);

    expect(plan).toEqual({
      distance: 240,
      speed: 30,
      ramp: RAMP_DURATION,
      duration: 240 / 30 + RAMP_DURATION,
    });
  });

  it("meets in the middle when the distance is too short to cruise", () => {
    const plan = planScroll(10, 30);

    expect(plan.speed).toBeLessThan(30);
    expect(plan.duration).toBeCloseTo(plan.ramp * 2, 10);
    expect(getScrollPosition(plan, plan.duration / 2)).toBeCloseTo(5, 10);
    expect(getScrollPosition(plan, plan.duration)).toBeCloseTo(10, 10);
  });

  it("returns an empty plan for a zero distance", () => {
    expect(planScroll(0, 30).duration).toBe(0);
  });
});

describe("getScrollPosition", () => {
  const plan = planScroll(300, 30);

  it("starts and ends at rest", () => {
    expect(getScrollPosition(plan, 0)).toBe(0);
    expect(getScrollPosition(plan, plan.duration)).toBeCloseTo(300, 10);
    expect(speedAt(plan, 1e-3)).toBeCloseTo(0, 1);
    expect(speedAt(plan, plan.duration - 1e-3)).toBeCloseTo(0, 1);
  });

  it("never jumps in speed between the ramps and the cruise", () => {
    expect(speedAt(plan, plan.ramp)).toBeCloseTo(30, 2);
    expect(speedAt(plan, plan.duration - plan.ramp)).toBeCloseTo(30, 2);
    expect(speedAt(plan, plan.duration / 2)).toBeCloseTo(30, 3);
  });

  it("moves forward monotonically", () => {
    let previous = -1;
    for (let time = 0; time <= plan.duration; time += 0.05) {
      const position = getScrollPosition(plan, time);
      expect(position).toBeGreaterThan(previous);
      previous = position;
    }
  });
});

describe("getScrollKeyframes", () => {
  it("places the keyframes on the planned curve", () => {
    const plan = planScroll(300, 30);
    const keyframes = getScrollKeyframes(plan);

    expect(keyframes.map(({ easing }) => easing)).toEqual([
      EASE_IN_QUAD,
      "linear",
      EASE_OUT_QUAD,
      undefined,
    ]);
    for (const { offset, position } of keyframes) {
      expect(position).toBeCloseTo(
        getScrollPosition(plan, offset * plan.duration),
        10,
      );
    }
    expect(keyframes[keyframes.length - 1]).toEqual({
      offset: 1,
      position: 300,
    });
  });

  it("drops the cruise segment for short distances", () => {
    const keyframes = getScrollKeyframes(planScroll(10, 30));

    expect(keyframes).toEqual([
      { offset: 0, position: 0, easing: EASE_IN_QUAD },
      { offset: 0.5, position: 5, easing: EASE_OUT_QUAD },
      { offset: 1, position: 10 },
    ]);
  });
});

describe("getTravelTime", () => {
  it("inverts the position curve inside and past the ramp", () => {
    const plan = planScroll(300, 30);

    for (const distance of [0, 4, 12, 20, 100]) {
      expect(
        getScrollPosition(plan, getTravelTime(plan, distance)),
      ).toBeCloseTo(distance, 8);
    }
  });

  it("never exceeds half of the cycle", () => {
    const plan = planScroll(10, 30);

    expect(getTravelTime(plan, 50)).toBeCloseTo(plan.duration / 2, 10);
  });
});

describe("getSettleDuration", () => {
  it("is quick for short hops and capped for long ones", () => {
    expect(getSettleDuration(0)).toBe(0.3);
    expect(getSettleDuration(-60)).toBeCloseTo(0.4, 10);
    expect(getSettleDuration(10_000)).toBe(0.75);
  });
});
