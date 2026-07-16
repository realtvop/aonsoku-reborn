import { useTranslation } from "react-i18next";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/app/components/ui/alert-dialog";
import { useOptions } from "@/app/hooks/use-options";
import { usePlaylistPlaybackConfirmation } from "@/store/playlists.store";
import { resolvePlaylistSongs } from "./playback";

export function PlaylistPlaybackConfirmationDialog() {
  const { t } = useTranslation();
  const { play, playNext } = useOptions();
  const { open, playlist, reset, setOpen } = usePlaylistPlaybackConfirmation();

  async function handleChoice(choice: "replace" | "next") {
    const selectedPlaylist = playlist;
    reset();
    if (!selectedPlaylist) return;

    const songs = await resolvePlaylistSongs(selectedPlaylist);
    if (!songs) return;

    const sourceId = { playlistId: selectedPlaylist.id };
    if (choice === "replace") {
      play(songs, sourceId, selectedPlaylist.name);
    } else {
      playNext(songs, sourceId);
    }
  }

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>
            {t("playlist.playbackConfirmation.title")}
          </AlertDialogTitle>
          <AlertDialogDescription>
            {t("playlist.playbackConfirmation.description", {
              name: playlist?.name ?? "",
            })}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter className="gap-2 sm:space-x-0">
          <AlertDialogCancel>{t("generic.cancel")}</AlertDialogCancel>
          <AlertDialogAction
            className="bg-secondary text-secondary-foreground hover:bg-secondary/80"
            onClick={() => handleChoice("next")}
          >
            {t("playlist.playbackConfirmation.playNext")}
          </AlertDialogAction>
          <AlertDialogAction onClick={() => handleChoice("replace")}>
            {t("playlist.playbackConfirmation.replace")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
