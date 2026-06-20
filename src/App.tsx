import { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { RouterProvider } from "react-router-dom";
import { toast } from "react-toastify";
import { Linux } from "@/app/components/controls/linux";
import { SettingsDialog } from "@/app/components/settings/dialog";
import { useNetworkStatusObserver } from "@/app/hooks/use-network-status";
import { LanControlObserver } from "@/app/observers/lan-control-observer";
import { CoordinationObserver } from "@/app/observers/coordination-observer";
import { LangObserver } from "@/app/observers/lang-observer";
import { LibraryMigrationObserver } from "@/app/observers/library-migration-observer";
import { MediaSessionObserver } from "@/app/observers/media-session-observer";
import { MetadataSyncObserver } from "@/app/observers/metadata-sync-observer";
import { MiniPlayerSyncObserver } from "@/app/observers/mini-player-sync-observer";
import { NetworkMonitorObserver } from "@/app/observers/network-monitor";
import { SmartDownloadObserver } from "@/app/observers/smart-download-observer";
import { ThemeObserver } from "@/app/observers/theme-observer";
import { AndroidBackButtonObserver } from "@/app/observers/android-back-button-observer";
import { KeyboardObserver } from "@/app/observers/keyboard-observer";
import { NativeAuthObserver } from "@/app/observers/native-auth-observer";
import { VolumeHUDObserver } from "@/app/observers/volume-hud-observer";
import { NowPlayingLikeObserver } from "@/app/observers/now-playing-like-observer";
import { ToastContainer } from "@/app/observers/toast-container";
import { router } from "@/routes/router";
import { cacheManager } from "@/service/cache";
import { useCacheIndexActions } from "@/store/cache-index.store";
import {
  tryAutoConnect,
  useLanControlClientStore,
} from "@/store/lanControlClient.store";
import { isDesktop, isLinux } from "@/utils/desktop";

function App() {
  const { t } = useTranslation();
  const status = useLanControlClientStore((state) => state.status);
  const { loadFromIDB } = useCacheIndexActions();

  useEffect(() => {
    loadFromIDB().then(() => {
      cacheManager.migrateCoverCacheKeys().catch((err) => {
        console.error("[migration] migrateCoverCacheKeys failed:", err);
      });
    });
  }, [loadFromIDB]);

  useNetworkStatusObserver();

  // Try to auto-connect on mount
  useEffect(() => {
    tryAutoConnect();
  }, []);

  // Show toast when auto-connect fails
  useEffect(() => {
    const checkAutoConnectFailed = setTimeout(() => {
      if (status === "error") {
        toast.info(t("lanControl.remote.autoConnectFailed"), {
          autoClose: 5000,
        });
      }
    }, 2000);

    return () => clearTimeout(checkAutoConnectFailed);
  }, [status, t]);

  // if (!isDesktop && window.innerHeight > window.innerWidth) return <Mobile />; // Support tablets but not phones

  return (
    <>
      <MediaSessionObserver />
      <MiniPlayerSyncObserver />
      <LangObserver />
      <ThemeObserver />
      <KeyboardObserver />
      <AndroidBackButtonObserver />
      <NativeAuthObserver />
      <LanControlObserver />
      <CoordinationObserver />
      <VolumeHUDObserver />
      <NowPlayingLikeObserver />
      <LibraryMigrationObserver />
      <NetworkMonitorObserver />
      <MetadataSyncObserver />
      <SmartDownloadObserver />
      <SettingsDialog />
      <RouterProvider router={router} />
      <ToastContainer />
      {isDesktop() && isLinux && <Linux />}
    </>
  );
}

export default App;
