import type { NativeQueueSong } from "@aonsoku/audio-contract";
import type { NativeDebugSnapshot } from "../../../main/native/debug/types";
import { formatTime } from "./format";

interface Props {
  snapshot: NativeDebugSnapshot | null;
  onControl: (control: "playPause" | "next" | "previous") => void;
}

export function PlaybackTab({ snapshot, onControl }: Props) {
  const audio = snapshot?.audio ?? null;

  if (!audio) {
    return (
      <Empty text="No playback state (native audio idle or unavailable)" />
    );
  }

  const current: NativeQueueSong | null = audio.isInUserQueue
    ? (audio.userQueue[0] ?? null)
    : (audio.contextQueue.songs[audio.contextQueue.currentIndex] ?? null);

  const progress =
    audio.duration > 0 ? (audio.currentTime / audio.duration) * 100 : 0;

  return (
    <div className="space-y-6 p-4">
      <Section title="NOW PLAYING">
        <Row
          k="Track"
          v={current ? `${current.title} — ${current.artist || ""}` : "(idle)"}
        />
        <Row
          k="Time"
          v={`${formatTime(audio.currentTime)} / ${formatTime(audio.duration)}`}
        />
        <Row
          k="Mode"
          v={`repeat:${audio.loopState} shuffle:${audio.isShuffleActive ? "on" : "off"}${audio.contextQueue.sourceName ? ` · ${audio.contextQueue.sourceName}` : ""}`}
        />
        <div className="mt-2">
          <div className="bg-muted h-1.5 w-full overflow-hidden rounded-full">
            <div
              className="bg-primary h-full transition-[width]"
              style={{ width: `${Math.min(100, Math.max(0, progress))}%` }}
            />
          </div>
        </div>
        <Controls
          isPlaying={audio.isPlaying}
          onPrev={() => onControl("previous")}
          onPlayPause={() => onControl("playPause")}
          onNext={() => onControl("next")}
        />
      </Section>

      <Section title={`QUEUE (${audio.contextQueue.songs.length})`}>
        {audio.contextQueue.songs.length === 0 ? (
          <Empty text="empty" inline />
        ) : (
          <QueueList
            songs={audio.contextQueue.songs}
            currentId={audio.isInUserQueue ? null : audio.currentSongId}
          />
        )}
      </Section>

      {audio.userQueue.length > 0 && (
        <Section title={`USER QUEUE (${audio.userQueue.length})`}>
          <QueueList songs={audio.userQueue} currentId={null} />
        </Section>
      )}
    </div>
  );
}

function Controls({
  isPlaying,
  onPrev,
  onPlayPause,
  onNext,
}: {
  isPlaying: boolean;
  onPrev: () => void;
  onPlayPause: () => void;
  onNext: () => void;
}) {
  const btn =
    "border-border bg-background hover:bg-muted text-foreground rounded border px-3 py-1 text-base leading-none transition-colors";
  return (
    <div className="mt-3 flex items-center gap-3">
      <button type="button" className={btn} onClick={onPrev}>
        ⏮
      </button>
      <button type="button" className={btn} onClick={onPlayPause}>
        {isPlaying ? "⏸" : "▶"}
      </button>
      <button type="button" className={btn} onClick={onNext}>
        ⏭
      </button>
    </div>
  );
}

function QueueList({
  songs,
  currentId,
}: {
  songs: NativeQueueSong[];
  currentId: string | null;
}) {
  return (
    <ul className="space-y-0.5">
      {songs.map((song) => {
        const isCurrent = song.id === currentId;
        return (
          <li
            key={song.id}
            className={`flex items-baseline gap-2 rounded px-2 py-0.5 ${
              isCurrent ? "text-primary" : "text-foreground"
            }`}
          >
            <span className="w-3 shrink-0">{isCurrent ? "▶" : ""}</span>
            <span className="flex-1 truncate text-xs">{song.title}</span>
            <span className="text-muted-foreground text-xs tabular-nums">
              {formatTime(song.duration)}
            </span>
          </li>
        );
      })}
    </ul>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section>
      <h2 className="text-muted-foreground mb-2 text-xs font-bold tracking-wider">
        {title}
      </h2>
      <div className="space-y-1">{children}</div>
    </section>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex gap-3 text-xs">
      <span className="text-muted-foreground w-20 shrink-0">{k}</span>
      <span className="text-foreground flex-1 break-all">{v}</span>
    </div>
  );
}

function Empty({ text, inline }: { text: string; inline?: boolean }) {
  return (
    <p
      className={`text-muted-foreground text-xs ${inline ? "" : "p-4 text-center"}`}
    >
      {text}
    </p>
  );
}
