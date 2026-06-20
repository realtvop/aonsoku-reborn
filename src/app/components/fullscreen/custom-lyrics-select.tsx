import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, Music2, Search } from "lucide-react";
import { FormEvent, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import { Button } from "@/app/components/ui/button";
import { Input } from "@/app/components/ui/input";
import { Label } from "@/app/components/ui/label";
import { ScrollArea } from "@/app/components/ui/scroll-area";
import { cn } from "@/lib/utils";
import type { CustomLyricsCandidate } from "@/service/lyrics";
import {
  getCustomLyricsCandidateKey,
  getCustomLyricsSongKey,
  getSelectedCustomLyrics,
} from "@/service/lyrics";
import { subsonic } from "@/service/subsonic";
import {
  useLyricsSettings,
  usePlayerActions,
  usePlayerSonglist,
} from "@/store/player.store";
import { queryKeys } from "@/utils/queryKeys";

function getLyricsPreview(lyrics?: string) {
  return lyrics?.trim() || "";
}

interface CustomLyricsSelectProps {
  onBack: () => void;
}

export function CustomLyricsSelect({ onBack }: CustomLyricsSelectProps) {
  const { t } = useTranslation();
  const queryClient = useQueryClient();
  const { currentSong } = usePlayerSonglist();
  const { setAreLyricsAligned } = usePlayerActions();
  const {
    customServerEnabled,
    customServerUrl,
    selectedCustomLyrics,
    setSelectedCustomLyrics,
  } = useLyricsSettings();

  const { artist, title, album, duration, path } = currentSong || {};
  const songData =
    artist && title ? { artist, title, album, duration, path } : null;
  const songKey = songData ? getCustomLyricsSongKey(songData) : "";
  const selectedLyrics = getSelectedCustomLyrics(selectedCustomLyrics, songKey);
  const [searchTitle, setSearchTitle] = useState("");
  const [searchArtist, setSearchArtist] = useState("");
  const [submittedSearch, setSubmittedSearch] = useState({
    title: "",
    artist: "",
  });

  useEffect(() => {
    setAreLyricsAligned(true);
  }, [setAreLyricsAligned]);

  useEffect(() => {
    const nextTitle = title || "";
    const nextArtist = artist || "";

    setSearchTitle(nextTitle);
    setSearchArtist(nextArtist);
    setSubmittedSearch({
      title: nextTitle,
      artist: nextArtist,
    });
  }, [artist, title]);

  const canSearch =
    submittedSearch.title.trim().length > 0 ||
    submittedSearch.artist.trim().length > 0;
  const querySongData =
    songData && canSearch
      ? {
          title: submittedSearch.title.trim() || undefined,
          artist: submittedSearch.artist.trim() || undefined,
        }
      : null;

  const { data: candidates = [], isLoading } = useQuery({
    queryKey: [
      ...queryKeys.lyrics.customCandidates,
      submittedSearch.artist,
      submittedSearch.title,
      customServerEnabled,
      customServerUrl,
    ],
    queryFn: () =>
      querySongData
        ? subsonic.lyrics.getCustomLyricsCandidates(querySongData)
        : Promise.resolve([]),
    enabled:
      !!querySongData &&
      customServerEnabled &&
      customServerUrl.trim().length > 0,
    staleTime: 5 * 60 * 1000,
  });

  function handleSearch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmittedSearch({
      title: searchTitle.trim(),
      artist: searchArtist.trim(),
    });
  }

  async function handleSelect(candidate: CustomLyricsCandidate, index: number) {
    if (!songData) return;

    const candidateKey = getCustomLyricsCandidateKey(candidate, index);
    const lyrics = candidate.lyrics?.trim();
    if (!lyrics) return;

    try {
      await setSelectedCustomLyrics(songKey, {
        key: candidateKey,
        id: candidate.id,
        title: candidate.title || submittedSearch.title || songData.title,
        artist: candidate.artist || submittedSearch.artist || songData.artist,
        lyrics,
      });
    } catch {
      toast.error(t("lyrics.customSelect.saveError"));
      return;
    }

    queryClient.invalidateQueries({ queryKey: queryKeys.lyrics.plain });
    onBack();
  }

  const customServerReady = customServerEnabled && customServerUrl.trim();

  return (
    <div
      className="flex h-full min-h-0 flex-col overflow-hidden px-2 text-foreground"
      data-vaul-no-drag
      onClick={(event) => event.stopPropagation()}
    >
      <div className="flex shrink-0 items-center gap-3 px-2 pb-3">
        <div className="min-w-0">
          <h2 className="truncate text-xl font-bold tracking-tight">
            {t("lyrics.customSelect.title")}
          </h2>
          <p className="truncate text-sm text-foreground/60">
            {currentSong
              ? t("lyrics.customSelect.subtitle", {
                  title: currentSong.title,
                  artist: currentSong.artist,
                })
              : t("player.noSongPlaying")}
          </p>
        </div>
      </div>

      {currentSong && customServerReady && (
        <div className="mb-3 ml-2 mr-6 shrink-0 rounded-2xl border border-border bg-muted/30 p-3 backdrop-blur-xl">
          <form
            className="grid gap-3 sm:grid-cols-[1fr_1fr_auto]"
            onSubmit={handleSearch}
          >
            <div className="grid gap-1.5">
              <Label
                htmlFor="fullscreen-custom-lyrics-title"
                className="text-xs text-foreground/60"
              >
                {t("lyrics.customSelect.searchTitle")}
              </Label>
              <Input
                id="fullscreen-custom-lyrics-title"
                value={searchTitle}
                className="border-border bg-muted/30 backdrop-blur-md focus-visible:border-border/60 focus-visible:ring-0 focus-visible:ring-offset-0"
                onChange={(event) => setSearchTitle(event.target.value)}
              />
            </div>
            <div className="grid gap-1.5">
              <Label
                htmlFor="fullscreen-custom-lyrics-artist"
                className="text-xs text-foreground/60"
              >
                {t("lyrics.customSelect.searchArtist")}
              </Label>
              <Input
                id="fullscreen-custom-lyrics-artist"
                value={searchArtist}
                className="border-border bg-muted/30 backdrop-blur-md focus-visible:border-border/60 focus-visible:ring-0 focus-visible:ring-offset-0"
                onChange={(event) => setSearchArtist(event.target.value)}
              />
            </div>
            <Button
              type="submit"
              className="self-end gap-1.5 rounded-full bg-foreground text-[var(--btn-text-inv)] hover:bg-foreground/90"
              disabled={!searchTitle.trim() && !searchArtist.trim()}
            >
              <Search className="size-4" />
              {t("lyrics.customSelect.search")}
            </Button>
          </form>
          {selectedLyrics && (
            <p className="mt-3 truncate text-xs text-foreground/55">
              {t("lyrics.customSelect.currentSelection", {
                title: selectedLyrics.title || currentSong.title,
                artist: selectedLyrics.artist || currentSong.artist,
              })}
            </p>
          )}
        </div>
      )}

      <div className="min-h-0 flex-1 px-2 pb-3">
        {!currentSong && (
          <EmptyState
            className="mr-4"
            message={t("lyrics.customSelect.noSong")}
          />
        )}

        {currentSong && !customServerReady && (
          <EmptyState
            className="mr-4"
            message={t("lyrics.customSelect.serverDisabled")}
          />
        )}

        {currentSong && customServerReady && isLoading && (
          <EmptyState
            className="mr-4"
            message={t("fullscreen.loadingLyrics")}
          />
        )}

        {currentSong &&
          customServerReady &&
          !isLoading &&
          candidates.length === 0 && (
            <EmptyState
              className="mr-4"
              message={t("lyrics.customSelect.empty")}
            />
          )}

        {candidates.length > 0 && (
          <ScrollArea
            type="always"
            className="h-full min-w-0 pr-4"
            thumbClassName="secondary-thumb-bar"
            onWheel={(event) => event.stopPropagation()}
            onTouchMove={(event) => event.stopPropagation()}
          >
            <div className="grid min-w-0 gap-3 pb-4">
              {candidates.map((candidate, index) => {
                const candidateKey = getCustomLyricsCandidateKey(
                  candidate,
                  index,
                );
                const selected = candidateKey === selectedLyrics?.key;
                const preview = getLyricsPreview(candidate.lyrics);

                return (
                  <div
                    key={candidateKey}
                    className={cn(
                      "min-w-0 overflow-hidden rounded-2xl border border-border bg-muted/30 backdrop-blur-xl transition-colors hover:bg-muted/50",
                      selected && "border-foreground/30 bg-foreground/10",
                    )}
                  >
                    <div className="flex min-w-0 flex-col items-start justify-between gap-3 p-4 sm:flex-row">
                      <div className="min-w-0 space-y-1">
                        <h3 className="truncate text-base font-semibold">
                          {candidate.title || currentSong.title}
                        </h3>
                        <p className="truncate text-sm text-foreground/60">
                          {candidate.artist || currentSong.artist}
                        </p>
                      </div>
                      <Button
                        size="sm"
                        variant="ghost"
                        className={cn(
                          "w-full shrink-0 gap-1.5 rounded-full sm:w-auto",
                          selected
                            ? "bg-foreground/15 hover:bg-foreground/20"
                            : "bg-foreground text-[var(--btn-text-inv)] hover:bg-foreground/90",
                        )}
                        onClick={() => handleSelect(candidate, index)}
                      >
                        {selected && <Check className="size-4" />}
                        {selected
                          ? t("lyrics.customSelect.selected")
                          : t("lyrics.customSelect.select")}
                      </Button>
                    </div>
                    <div className="min-w-0 px-4 pb-4 pt-0">
                      {candidate.id && (
                        <p className="mb-2 text-xs text-foreground/45">
                          {t("lyrics.customSelect.lyricsId", {
                            id: candidate.id,
                          })}
                        </p>
                      )}
                      <ScrollArea
                        type="always"
                        className="h-52 min-w-0 rounded-xl border border-border bg-muted/40 p-3"
                        thumbClassName="secondary-thumb-bar"
                        onWheel={(event) => event.stopPropagation()}
                        onTouchMove={(event) => event.stopPropagation()}
                      >
                        <pre className="min-h-56 min-w-0 whitespace-pre-wrap break-words pr-3 font-sans text-sm leading-6 text-foreground/75">
                          {preview || t("lyrics.customSelect.noPreview")}
                        </pre>
                      </ScrollArea>
                    </div>
                  </div>
                );
              })}
            </div>
          </ScrollArea>
        )}
      </div>
    </div>
  );
}

function EmptyState({
  className,
  message,
}: {
  className?: string;
  message: string;
}) {
  return (
    <div
      className={cn(
        "flex h-full min-h-48 flex-col items-center justify-center gap-3 rounded-2xl border border-border bg-muted/30 p-6 text-center text-foreground/60 backdrop-blur-xl",
        className,
      )}
    >
      <Music2 className="size-8" />
      <p>{message}</p>
    </div>
  );
}
