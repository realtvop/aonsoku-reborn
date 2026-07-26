import { lazy, Suspense, useEffect } from "react";

import { RouterProvider } from "react-router-dom";

import { Linux } from "@/app/components/controls/linux";
import { useNetworkStatusObserver } from "@/app/hooks/use-network-status";

import { AndroidBackButtonObserver } from "@/app/observers/android-back-button-observer";
import { CoordinationObserver } from "@/app/observers/coordination-observer";
import { KeyboardObserver } from "@/app/observers/keyboard-observer";
import { LangObserver } from "@/app/observers/lang-observer";
import { LibraryMigrationObserver } from "@/app/observers/library-migration-observer";
import { MediaSessionObserver } from "@/app/observers/media-session-observer";
import { MetadataSyncObserver } from "@/app/observers/metadata-sync-observer";
import { MiniPlayerSyncObserver } from "@/app/observers/mini-player-sync-observer";
import { NativeAuthObserver } from "@/app/observers/native-auth-observer";
import { NativeRemoteCommandObserver } from "@/app/observers/native-remote-command-observer";
import { NetworkMonitorObserver } from "@/app/observers/network-monitor";
import { NowPlayingLikeObserver } from "@/app/observers/now-playing-like-observer";
import { SmartDownloadObserver } from "@/app/observers/smart-download-observer";
import { ThemeObserver } from "@/app/observers/theme-observer";
import { ToastContainer } from "@/app/observers/toast-container";
import { VolumeHUDObserver } from "@/app/observers/volume-hud-observer";
import { router } from "@/routes/router";
import { cacheManager } from "@/service/cache";
import { useAppStore } from "@/store/app.store";
import { useCacheIndexActions } from "@/store/cache-index.store";

import { isDesktop, isLinux } from "@/utils/desktop";

const SettingsDialog = lazy(() =>
  import("@/app/components/settings/dialog").then((module) => ({
    default: module.SettingsDialog,
  })),
);

function DeferredSettingsDialog() {
  const openDialog = useAppStore((state) => state.settings.openDialog);

  if (!openDialog) return null;

  return (
    <Suspense fallback={null}>
      <SettingsDialog />
    </Suspense>
  );
}

function App() {
  const { loadFromIDB } = useCacheIndexActions();

  useEffect(() => {
    loadFromIDB().then(() => {
      cacheManager.migrateCoverCacheKeys().catch((err) => {
        console.error("[migration] migrateCoverCacheKeys failed:", err);
      });
    });
  }, [loadFromIDB]);

  useNetworkStatusObserver();

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
      <NativeRemoteCommandObserver />

      <CoordinationObserver />
      <VolumeHUDObserver />
      <NowPlayingLikeObserver />
      <LibraryMigrationObserver />
      <NetworkMonitorObserver />
      <MetadataSyncObserver />
      <SmartDownloadObserver />
      <DeferredSettingsDialog />
      <RouterProvider router={router} />
      <ToastContainer />
      {isDesktop() && isLinux && <Linux />}
    </>
  );
}

export default App;
