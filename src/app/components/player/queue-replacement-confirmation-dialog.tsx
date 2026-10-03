import { useEffect } from "react";
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
import { useCoordinationStore } from "@/coordination/store";
import { getReplacementPlayNextSongs } from "@/player/queue-replacement";
import { usePlaybackReplacementStore } from "@/store/playback-replacement.store";
import { usePlayerActions, usePlayerStore } from "@/store/player.store";

export function QueueReplacementConfirmationDialog() {
  const { t } = useTranslation();
  const { playSong, setNextOnQueue, setSongList } = usePlayerActions();
  const { open, request, reset, setOpen, takeRequest } =
    usePlaybackReplacementStore();
  const remoteActive = usePlayerStore((state) => state.remoteControl.active);
  const controlledDeviceId = useCoordinationStore(
    (state) => state.controlledDeviceId,
  );
  const targetDeviceId = remoteActive ? controlledDeviceId : null;

  useEffect(() => {
    if (request && (request.targetDeviceId ?? null) !== targetDeviceId) {
      reset();
    }
  }, [request, reset, targetDeviceId]);

  function handleChoice(choice: "replace" | "next") {
    const currentTarget = usePlayerStore.getState().remoteControl.active
      ? useCoordinationStore.getState().controlledDeviceId
      : null;
    const pending = takeRequest(currentTarget);
    if (!pending) return;

    if (choice === "next") {
      const songs = getReplacementPlayNextSongs(pending);
      const sourceId =
        pending.kind === "songList" ? pending.sourceId : undefined;
      const sourceName =
        pending.kind === "songList" ? pending.sourceName : undefined;
      setNextOnQueue(songs, sourceId, sourceName);
      return;
    }

    if (pending.kind === "song") {
      playSong(pending.song, pending.sourceName, {
        bypassQueueConfirmation: true,
      });
    } else {
      setSongList(
        pending.songs,
        pending.index,
        pending.shuffle,
        pending.sourceId,
        pending.sourceName,
        { bypassQueueConfirmation: true },
      );
    }
  }

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>
            {t("queue.replacementConfirmation.title")}
          </AlertDialogTitle>
          <AlertDialogDescription>
            {t("queue.replacementConfirmation.description")}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter className="gap-2 sm:space-x-0">
          <AlertDialogCancel>{t("generic.cancel")}</AlertDialogCancel>
          <AlertDialogAction
            className="bg-secondary text-secondary-foreground hover:bg-secondary/80"
            onClick={() => handleChoice("next")}
          >
            {t("queue.replacementConfirmation.playNext")}
          </AlertDialogAction>
          <AlertDialogAction onClick={() => handleChoice("replace")}>
            {t("queue.replacementConfirmation.replace")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
