import { memo, useEffect } from "react";
import { MainDrawerPage } from "@/app/components/drawer/page";
import { Player } from "@/app/components/player/player";
import { PlaylistPlaybackConfirmationDialog } from "@/app/components/playlist/playback-confirmation-dialog";
import { RemovePlaylistDialog } from "@/app/components/playlist/remove-dialog";
import { SettingsHotkeyProvider } from "@/app/components/settings/hotkey-provider";
import { SongInfoDialog } from "@/app/components/song/info-dialog";
import { BottomNavigation } from "@/app/layout/bottom-navigation";
import { Header } from "@/app/layout/header";
import { MiniSidebar } from "@/app/layout/mini-sidebar";
import { Sidebar } from "@/app/layout/sidebar";
import { FullscreenPlayerRouter } from "@/routes/fullscreenRouter";
import { useUiStore } from "@/store/ui.store";
import { MainRoutes } from "./main";

const MemoHeader = memo(Header);
const MemoMiniSidebar = memo(MiniSidebar);
const MemoSidebar = memo(Sidebar);
const MemoPlayer = memo(Player);
const MemoSongInfoDialog = memo(SongInfoDialog);
const MemoRemovePlaylistDialog = memo(RemovePlaylistDialog);
const MemoPlaylistPlaybackConfirmationDialog = memo(
  PlaylistPlaybackConfirmationDialog,
);
const MemoMainDrawerPage = memo(MainDrawerPage);
const MemoBottomNavigation = memo(BottomNavigation);

function CSSVariableSync() {
  const sidebarWidth = useUiStore((state) => state.sidebar.width);
  const rightPanelWidth = useUiStore((state) => state.rightPanel.width);

  useEffect(() => {
    document.documentElement.style.setProperty(
      "--sidebar-base-width",
      `${sidebarWidth}px`,
    );
  }, [sidebarWidth]);

  useEffect(() => {
    document.documentElement.style.setProperty(
      "--right-panel-base-width",
      `${rightPanelWidth}px`,
    );
  }, [rightPanelWidth]);

  return null;
}

export default function BaseLayout() {
  return (
    <div className="min-h-screen w-screen">
      <CSSVariableSync />
      <SettingsHotkeyProvider />
      <MemoHeader />
      <MemoMiniSidebar />
      <MemoSidebar />
      <MemoPlayer />
      <MemoBottomNavigation />
      {/* Routes */}
      <MainRoutes />
      <MemoSongInfoDialog />
      <MemoRemovePlaylistDialog />
      <MemoPlaylistPlaybackConfirmationDialog />
      <MemoMainDrawerPage />
      <FullscreenPlayerRouter />
    </div>
  );
}
