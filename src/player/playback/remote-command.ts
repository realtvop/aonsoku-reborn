import type { PlaybackRemoteCommandEvent } from "./types";

export interface PlaybackRemoteCommandContext {
  isPlaying: () => boolean;
  togglePlayPause: () => void;
  stop: () => void;
  playNextSong: () => void;
  playPrevSong: () => void;
  seek: (position: number) => void;
  starCurrentSong: () => void;
  toggleShuffle: () => void;
}

export function handlePlaybackRemoteCommand(
  event: PlaybackRemoteCommandEvent,
  context: PlaybackRemoteCommandContext,
) {
  switch (event.command) {
    case "play":
      if (!context.isPlaying()) {
        context.togglePlayPause();
      }
      return;
    case "pause":
      if (context.isPlaying()) {
        context.togglePlayPause();
      }
      return;
    case "stop":
      context.stop();
      return;
    case "togglePlayPause":
      context.togglePlayPause();
      return;
    case "next":
      context.playNextSong();
      return;
    case "previous":
      context.playPrevSong();
      return;
    case "seek":
      context.seek(Math.max(0, event.position ?? 0));
      return;
    case "like":
      context.starCurrentSong();
      return;
    case "shuffle":
      context.toggleShuffle();
      return;
  }
}
