import { describe, expect, it, vi } from "vitest";
import { AsyncLimiter } from "./concurrency";

describe("AsyncLimiter", () => {
  it("runs tasks immediately up to the concurrency limit", async () => {
    const limiter = new AsyncLimiter(3);
    const started: number[] = [];
    let resolveFirst!: () => void;
    const first = new Promise<void>((resolve) => {
      resolveFirst = resolve;
    });

    const tasks = Array.from({ length: 3 }, (_, i) =>
      limiter.run(async () => {
        started.push(i);
        if (i === 0) await first;
      }),
    );

    // Give the microtask queue a tick so the synchronous start runs.
    await Promise.resolve();
    expect(started).toEqual([0, 1, 2]);
    expect(limiter.inflight).toBe(3);
    expect(limiter.pending).toBe(0);

    resolveFirst();
    await Promise.all(tasks);
    expect(limiter.inflight).toBe(0);
  });

  it("queues tasks beyond the limit and releases slots on settle", async () => {
    const limiter = new AsyncLimiter(2);
    const order: string[] = [];

    const make = (id: string, ms: number) =>
      limiter.run(async () => {
        order.push(`start:${id}`);
        await new Promise((r) => setTimeout(r, ms));
        order.push(`end:${id}`);
      });

    const all = Promise.all([
      make("a", 10),
      make("b", 10),
      make("c", 10),
      make("d", 10),
    ]);

    await Promise.resolve();
    expect(limiter.inflight).toBe(2);
    expect(limiter.pending).toBe(2);

    await all;
    expect(order).toEqual([
      "start:a",
      "start:b",
      "end:a",
      "start:c",
      "end:b",
      "start:d",
      "end:c",
      "end:d",
    ]);
    expect(limiter.inflight).toBe(0);
    expect(limiter.pending).toBe(0);
  });

  it("releases the slot when a task rejects", async () => {
    const limiter = new AsyncLimiter(1);
    const onReject = vi.fn();

    await limiter
      .run(async () => {
        throw new Error("boom");
      })
      .catch(onReject);

    expect(onReject).toHaveBeenCalledOnce();
    expect(limiter.inflight).toBe(0);

    // Slot is free for the next task.
    const result = await limiter.run(async () => "ok");
    expect(result).toBe("ok");
  });
});
