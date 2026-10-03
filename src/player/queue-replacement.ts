import type { PlaybackReplacementRequest } from "@/store/playback-replacement.store";
import type { ISong } from "@/types/responses/song";
import { shuffleWithGapAvoidance } from "@/utils/songListFunctions";

export function shouldConfirmQueueReplacement({
  isPlaying,
  userQueueLength,
  isInUserQueue,
  bypassQueueConfirmation = false,
}: {
  isPlaying: boolean;
  userQueueLength: number;
  isInUserQueue: boolean;
  bypassQueueConfirmation?: boolean;
}): boolean {
  const remaining = userQueueLength - (isInUserQueue ? 1 : 0);
  return isPlaying && remaining > 0 && !bypassQueueConfirmation;
}

export function getReplacementPlayNextSongs(
  request: PlaybackReplacementRequest,
  shuffle: (songs: ISong[]) => ISong[] = (songs) =>
    shuffleWithGapAvoidance(songs, []),
): ISong[] {
  if (request.kind === "song") return [request.song];
  if (request.songs.length === 0) return [];
  if (request.shuffle) return shuffle([...request.songs]);

  const index = Math.max(
    0,
    Math.min(request.index ?? 0, request.songs.length - 1),
  );
  return request.songs.slice(index);
}
