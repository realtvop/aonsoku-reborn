import { useEffect, useState } from "react";
import type { NativeDebugSnapshot } from "../../main/native/debug/types";
import { debugClient } from "./debug-client";

const REFRESH_INTERVAL_MS = 2000;

export function NativeDebugApp() {
  const [snapshot, setSnapshot] = useState<NativeDebugSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setInterval> | null = null;

    async function refresh() {
      try {
        const next = await debugClient.getSnapshot();
        if (!cancelled) {
          setSnapshot(next);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(String(e instanceof Error ? e.message : e));
      }
    }

    refresh();
    timer = setInterval(refresh, REFRESH_INTERVAL_MS);

    return () => {
      cancelled = true;
      if (timer) clearInterval(timer);
    };
  }, []);

  return (
    <div className="bg-background text-foreground h-screen w-screen overflow-hidden font-mono text-sm">
      <div className="border-border border-b px-4 py-2">
        <span className="text-foreground font-semibold">
          Native Player Debug
        </span>
        {snapshot ? (
          <span className="text-muted-foreground ml-2">
            {snapshot.audio
              ? snapshot.audio.isPlaying
                ? "playing"
                : "paused"
              : "idle"}
            {" · "}
            vol {(snapshot.volume * 100).toFixed(0)}%
          </span>
        ) : error ? (
          <span className="text-destructive ml-2">{error}</span>
        ) : (
          <span className="text-muted-foreground ml-2">loading…</span>
        )}
      </div>
      <pre className="overflow-auto p-4 text-xs leading-relaxed">
        {snapshot ? JSON.stringify(snapshot, null, 2) : ""}
      </pre>
    </div>
  );
}
