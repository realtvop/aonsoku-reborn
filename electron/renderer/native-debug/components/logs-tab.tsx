import { useMemo, useState } from "react";
import type {
  NativeDebugLogEntry,
  NativeDebugLogLevel,
} from "../../../main/native/debug/types";
import { formatLogTime, formatLogTimeFull } from "./format";

const ALL_LEVELS: NativeDebugLogLevel[] = ["debug", "info", "warn", "error"];

const LEVEL_COLOR: Record<NativeDebugLogLevel, string> = {
  debug: "text-muted-foreground",
  info: "text-foreground",
  warn: "text-yellow-500",
  error: "text-red-500",
};

const LEVEL_BG: Record<NativeDebugLogLevel, string> = {
  debug: "bg-muted text-muted-foreground",
  info: "bg-blue-500/15 text-blue-400",
  warn: "bg-yellow-500/15 text-yellow-500",
  error: "bg-red-500/15 text-red-500",
};

interface Props {
  entries: NativeDebugLogEntry[];
  onClear: () => void;
}

export function LogsTab({ entries, onClear }: Props) {
  const [search, setSearch] = useState("");
  const [activeLevels, setActiveLevels] = useState<Set<NativeDebugLogLevel>>(
    () => new Set(ALL_LEVELS),
  );
  const [activeSources, setActiveSources] = useState<Set<string>>(new Set());
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [selectMode, setSelectMode] = useState(false);

  const allSources = useMemo(
    () =>
      Array.from(
        new Set(entries.map((e) => e.source).filter((s) => s !== "")),
      ).sort(),
    [entries],
  );

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return entries.filter((e) => {
      if (!activeLevels.has(e.level)) return false;
      if (
        activeSources.size > 0 &&
        e.source !== "" &&
        !activeSources.has(e.source)
      )
        return false;
      if (q) {
        const hay = `${e.source} ${e.message}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }, [entries, activeLevels, activeSources, search]);

  function toggleLevel(level: NativeDebugLogLevel) {
    setActiveLevels((prev) => {
      const next = new Set(prev);
      if (next.has(level)) next.delete(level);
      else next.add(level);
      return next;
    });
  }

  function toggleSource(source: string) {
    setActiveSources((prev) => {
      const next = new Set(prev);
      if (next.has(source)) next.delete(source);
      else next.add(source);
      return next;
    });
  }

  function toggleSelected(idx: number) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(idx)) next.delete(idx);
      else next.add(idx);
      return next;
    });
  }

  function copySelected() {
    const text = Array.from(selected)
      .sort((a, b) => a - b)
      .map((i) => filtered[i])
      .filter(Boolean)
      .map((e) => {
        const src = e.source ? `[${e.source}] ` : "";
        return `${formatLogTimeFull(e.timestamp)} ${e.level.toUpperCase()} ${src}${e.message}`;
      })
      .join("\n");
    navigator.clipboard.writeText(text).catch(() => {});
  }

  function selectAll() {
    setSelected(new Set(filtered.keys()));
  }

  return (
    <div className="flex h-full flex-col">
      <div className="border-border space-y-2 border-b p-3">
        <input
          type="text"
          placeholder="Search logs…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="border-border bg-background text-foreground placeholder:text-muted-foreground w-full rounded border px-2 py-1 text-xs outline-none focus:border-primary"
        />
        <div className="flex flex-wrap items-center gap-1.5">
          {ALL_LEVELS.map((level) => (
            <Chip
              key={level}
              label={level.toUpperCase()}
              active={activeLevels.has(level)}
              onClick={() => toggleLevel(level)}
            />
          ))}
          <div className="border-border mx-1 h-4 w-px" />
          {allSources.map((source) => (
            <Chip
              key={source}
              label={source}
              active={activeSources.size === 0 || activeSources.has(source)}
              onClick={() => toggleSource(source)}
            />
          ))}
        </div>
      </div>

      <div className="flex-1 overflow-y-auto">
        {filtered.length === 0 ? (
          <p className="text-muted-foreground p-4 text-xs">no entries</p>
        ) : (
          <ul>
            {filtered.map((entry, i) => {
              const isSelected = selected.has(i);
              return (
                <li
                  key={`${entry.timestamp}-${i}`}
                  onClick={() => selectMode && toggleSelected(i)}
                  className={`border-border cursor-default border-b px-3 py-1.5 text-xs leading-relaxed ${
                    selectMode ? "cursor-pointer" : ""
                  } ${isSelected ? "bg-primary/15" : ""}`}
                >
                  <div className="flex items-center gap-2">
                    {selectMode && (
                      <span className="w-3 shrink-0">
                        {isSelected ? "☑" : "☐"}
                      </span>
                    )}
                    <span
                      className={`rounded px-1 text-[10px] font-bold ${LEVEL_BG[entry.level]}`}
                    >
                      {entry.level.toUpperCase()}
                    </span>
                    <span className="text-muted-foreground tabular-nums">
                      {formatLogTime(entry.timestamp)}
                    </span>
                    {entry.source && (
                      <span className="text-muted-foreground">
                        @{entry.source}
                      </span>
                    )}
                  </div>
                  <div className={`mt-0.5 pl-5 ${LEVEL_COLOR[entry.level]}`}>
                    {entry.message}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </div>

      <div className="border-border flex items-center gap-2 border-t p-2">
        <span className="text-muted-foreground text-xs">
          {filtered.length}/{entries.length}
        </span>
        <div className="ml-auto flex items-center gap-2">
          {selectMode && (
            <button
              type="button"
              onClick={selectAll}
              className="border-border hover:bg-muted rounded border px-2 py-1 text-xs"
            >
              All
            </button>
          )}
          <button
            type="button"
            onClick={() => {
              setSelectMode((s) => !s);
              setSelected(new Set());
            }}
            className="border-border hover:bg-muted rounded border px-2 py-1 text-xs"
          >
            {selectMode ? "Cancel" : "Select"}
          </button>
          <button
            type="button"
            disabled={selected.size === 0}
            onClick={copySelected}
            className="border-border hover:bg-muted rounded border px-2 py-1 text-xs disabled:opacity-40"
          >
            Copy{selected.size > 0 ? ` (${selected.size})` : ""}
          </button>
          <button
            type="button"
            onClick={onClear}
            className="border-border hover:bg-muted rounded border px-2 py-1 text-xs"
          >
            Clear
          </button>
        </div>
      </div>
    </div>
  );
}

function Chip({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`rounded-full px-2 py-0.5 text-[10px] font-semibold transition-colors ${
        active
          ? "bg-primary text-primary-foreground"
          : "bg-muted text-muted-foreground hover:text-foreground"
      }`}
    >
      {label}
    </button>
  );
}
