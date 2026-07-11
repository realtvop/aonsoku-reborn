import { useCallback, useEffect, useMemo, useState } from "react";
import type {
  NativeDebugLogEntry,
  NativeDebugSnapshot,
} from "../../main/native/debug/types";
import { InfoTab } from "./components/info-tab";
import { LogsTab } from "./components/logs-tab";
import { PlaybackTab } from "./components/playback-tab";
import { debugClient } from "./debug-client";

const REFRESH_INTERVAL_MS = 2000;

type Tab = "playback" | "info" | "logs";

const TABS: { id: Tab; label: string }[] = [
  { id: "playback", label: "Playback" },
  { id: "info", label: "Info" },
  { id: "logs", label: "Logs" },
];

export function NativeDebugApp() {
  const [snapshot, setSnapshot] = useState<NativeDebugSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("playback");

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

  const onControl = useCallback(
    (control: "playPause" | "next" | "previous") => {
      debugClient.control(control).catch((e) => {
        setError(String(e instanceof Error ? e.message : e));
      });
    },
    [],
  );

  const onClearLogs = useCallback(() => {
    debugClient.clearLogs().catch(() => {});
  }, []);

  const logs = useMemo<NativeDebugLogEntry[]>(
    () => snapshot?.logs ?? [],
    [snapshot],
  );

  return (
    <div className="bg-background text-foreground flex h-screen w-screen flex-col overflow-hidden font-mono text-sm">
      <header className="border-border flex items-center gap-1 border-b px-2 py-2">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            onClick={() => setTab(t.id)}
            className={`rounded px-3 py-1 text-xs font-semibold transition-colors ${
              tab === t.id
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-muted hover:text-foreground"
            }`}
          >
            {t.label}
          </button>
        ))}
        <div className="ml-auto flex items-center gap-2">
          {error ? (
            <span className="text-destructive text-xs">{error}</span>
          ) : snapshot ? (
            <span className="text-muted-foreground text-xs">
              {snapshot.audio
                ? snapshot.audio.isPlaying
                  ? "playing"
                  : "paused"
                : "idle"}
              {" · "}
              vol {(snapshot.volume * 100).toFixed(0)}%
            </span>
          ) : (
            <span className="text-muted-foreground text-xs">loading…</span>
          )}
        </div>
      </header>

      <main className="flex-1 overflow-y-auto">
        {tab === "playback" && (
          <PlaybackTab snapshot={snapshot} onControl={onControl} />
        )}
        {tab === "info" && <InfoTab snapshot={snapshot} />}
        {tab === "logs" && <LogsTab entries={logs} onClear={onClearLogs} />}
      </main>
    </div>
  );
}
