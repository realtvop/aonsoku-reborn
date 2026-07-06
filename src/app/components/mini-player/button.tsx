import clsx from "clsx";
import { PictureInPicture2Icon } from "lucide-react";
import { memo, useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/app/components/ui/button";
import { useRemotePlaybackProjection } from "@/app/components/remote-control/use-remote-playback-projection";
import { SimpleTooltip } from "@/app/components/ui/simple-tooltip";
import { usePlayerCurrentList, usePlayerStore } from "@/store/player.store";
import { usePipWindowOpen } from "@/store/player/selectors";
import { hasElectronBridge } from "@/utils/desktop";
import { MiniPlayer } from "./player";
import { MiniPlayerPortal } from "./portal";
import { InternalMiniPlayerProvider } from "./provider";

const MemoMiniPlayerPortal = memo(MiniPlayerPortal);
const MemoMiniPlayer = memo(MiniPlayer);

function MiniPlayerButtonWeb() {
  const { t } = useTranslation();
  const currentList = usePlayerCurrentList();
  const remoteProjection = useRemotePlaybackProjection();
  const pipWindowOpen = usePipWindowOpen();
  const documentPictureInPicture = window.documentPictureInPicture;
  const [pipWindow, setPipWindow] = useState<Window | null>(
    documentPictureInPicture?.window ?? null,
  );

  useEffect(() => {
    if (!pipWindowOpen) return;
    if (pipWindow) return;
    if (!documentPictureInPicture) return;

    let cancelled = false;

    documentPictureInPicture
      .requestWindow({ width: 300, height: 300 })
      .then((newWindow) => {
        if (cancelled) {
          newWindow.close();
          return;
        }

        const handlePageHide = () => {
          setPipWindow(null);
          usePlayerStore.getState().actions.closePipWindow();
        };

        newWindow.addEventListener("pagehide", handlePageHide);
        setPipWindow(newWindow);
      })
      .catch(() => {
        usePlayerStore.getState().actions.closePipWindow();
      });

    return () => {
      cancelled = true;
    };
  }, [pipWindowOpen, pipWindow, documentPictureInPicture]);

  useEffect(() => {
    if (!pipWindowOpen && pipWindow) {
      pipWindow.close();
      setPipWindow(null);
    }
  }, [pipWindowOpen, pipWindow]);

  useEffect(() => {
    const existingWindow = documentPictureInPicture?.window;
    if (existingWindow) {
      setPipWindow(existingWindow);
      usePlayerStore.getState().actions.openPipWindow();
    }
  }, [documentPictureInPicture]);

  const handleClick = useCallback(() => {
    if (pipWindowOpen) {
      usePlayerStore.getState().actions.closePipWindow();
    } else {
      usePlayerStore.getState().actions.openPipWindow();
    }
  }, [pipWindowOpen]);

  const disabled = !remoteProjection.active && currentList.length === 0;

  const buttonTooltip = pipWindowOpen
    ? t("player.tooltips.miniPlayer.close")
    : t("player.tooltips.miniPlayer.open");

  return (
    <>
      <SimpleTooltip text={buttonTooltip}>
        <Button
          variant="ghost"
          size="icon"
          onClick={handleClick}
          className={clsx(
            "relative rounded-full",
            pipWindowOpen &&
              "text-primary hover-supported:text-primary player-button-active",
          )}
          disabled={disabled}
          unfocusable
        >
          <PictureInPicture2Icon className="w-4 h-4" />
        </Button>
      </SimpleTooltip>
      <MemoMiniPlayerPortal pipWindow={pipWindow}>
        <InternalMiniPlayerProvider>
          <MemoMiniPlayer />
        </InternalMiniPlayerProvider>
      </MemoMiniPlayerPortal>
    </>
  );
}

function MiniPlayerButtonDesktop() {
  const { t } = useTranslation();
  const currentList = usePlayerCurrentList();
  const remoteProjection = useRemotePlaybackProjection();
  const pipWindowOpen = usePipWindowOpen();
  const [isMiniPlayerOpen, setIsMiniPlayerOpen] = useState(false);

  useEffect(() => {
    if (!hasElectronBridge()) return;

    window.api.isMiniPlayerOpen().then((open) => {
      setIsMiniPlayerOpen(open);
    });

    window.api.miniPlayerStatusListener((isOpen: boolean) => {
      setIsMiniPlayerOpen(isOpen);
      if (isOpen) {
        usePlayerStore.getState().actions.openPipWindow();
      } else {
        usePlayerStore.getState().actions.closePipWindow();
      }
    });

    return () => {
      window.api.removeMiniPlayerStatusListener();
    };
  }, []);

  const handleClick = useCallback(() => {
    if (!hasElectronBridge()) return;

    if (pipWindowOpen || isMiniPlayerOpen) {
      window.api.closeMiniPlayer();
      usePlayerStore.getState().actions.closePipWindow();
    } else {
      window.api.openMiniPlayer();
      usePlayerStore.getState().actions.openPipWindow();
    }
  }, [pipWindowOpen, isMiniPlayerOpen]);

  const disabled = !remoteProjection.active && currentList.length === 0;

  const buttonTooltip =
    pipWindowOpen || isMiniPlayerOpen
      ? t("player.tooltips.miniPlayer.close")
      : t("player.tooltips.miniPlayer.open");

  return (
    <SimpleTooltip text={buttonTooltip}>
      <Button
        variant="ghost"
        size="icon"
        onClick={handleClick}
        className={clsx(
          "relative rounded-full",
          (pipWindowOpen || isMiniPlayerOpen) &&
            "text-primary hover-supported:text-primary player-button-active",
        )}
        disabled={disabled}
        unfocusable
      >
        <PictureInPicture2Icon className="w-4 h-4" />
      </Button>
    </SimpleTooltip>
  );
}

export function MiniPlayerButton() {
  if (hasElectronBridge()) {
    return <MiniPlayerButtonDesktop />;
  }

  if (!window.documentPictureInPicture) return null;

  return <MiniPlayerButtonWeb />;
}
