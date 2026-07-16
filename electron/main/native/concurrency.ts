/**
 * Bounded-concurrency limiter for the Electron main process.
 *
 * The main process runs every IPC handler, `protocol.handle` callback, and
 * `fetch` resolution on a single Node event loop. When the renderer opens a
 * large grid, dozens of `aonsoku-media://getCoverArt` requests can fire at
 * once and saturate the undici connection pool for the Subsonic origin,
 * starving metadata IPC and even local reads. This limiter caps the number
 * of in-flight image-proxy fetches so the connection pool always has room for
 * metadata/stream traffic.
 *
 * Mirrors the `AsyncLimiter` in `src/service/cache/cache-manager.ts` but lives
 * in the main-process tree so it has no renderer-side dependencies.
 */
export class AsyncLimiter {
  private active = 0;
  private readonly queue: Array<() => void> = [];

  constructor(private readonly limit: number) {}

  run<T>(task: () => Promise<T>): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const start = () => {
        this.active += 1;
        task()
          .then(resolve, reject)
          .finally(() => {
            this.active -= 1;
            this.queue.shift()?.();
          });
      };

      if (this.active < this.limit) {
        start();
      } else {
        this.queue.push(start);
      }
    });
  }

  get pending(): number {
    return this.queue.length;
  }

  get inflight(): number {
    return this.active;
  }
}
