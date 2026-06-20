import {
  AlertTriangle,
  Check,
  Info,
  Keyboard,
  LogOut,
  RefreshCw,
  Settings,
  User,
  WifiOff,
} from "lucide-react";
import { useState } from "react";
import { useHotkeys } from "react-hotkeys-hook";
import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";

import { AboutDialog } from "@/app/components/about/dialog";
import { SyncPopoverContent } from "@/app/components/header/sync-progress-bar";

import { ShortcutsDialog } from "@/app/components/shortcuts/dialog";
import {
  Avatar,
  AvatarFallback,
  AvatarImage,
} from "@/app/components/ui/avatar";
import {
  Drawer,
  DrawerClose,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
  DrawerTrigger,
} from "@/app/components/ui/drawer";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuTrigger,
} from "@/app/components/ui/dropdown-menu";
import { useAvatarUrl } from "@/app/hooks/use-avatar-url";
import { useIsMobile } from "@/app/hooks/use-mobile";
import { useSwUpdate } from "@/app/hooks/use-sw-update";
import { LogoutObserver } from "@/app/observers/logout-observer";
import { cn } from "@/lib/utils";
import { ROUTES } from "@/routes/routesList";
import {
  settingsKeys,
  shortcutDialogKeys,
  stringifyShortcut,
} from "@/shortcuts";
import { useAppData, useAppSettings, useAppStore } from "@/store/app.store";
import {
  useCacheStore,
  useIsOnline,
  useLastSyncedAt,
  useLibraryCaching,
  useSyncState,
} from "@/store/cache.store";

import { isMacOS } from "@/utils/desktop";

type SyncBadgeVariant = "offline" | "error" | "syncing" | "done" | null;

function useSyncBadgeVariant(): SyncBadgeVariant {
  const isOnline = useIsOnline();
  const libraryCaching = useLibraryCaching();
  const phase = useCacheStore((s) => s.status.syncState.phase);
  const isSyncing = useCacheStore((s) => s.status.syncState.isSyncing);

  if (!isOnline) return "offline";
  if (!libraryCaching) return null;

  if (phase === "error") return "error";
  if (isSyncing) return "syncing";
  if (phase === "done") return "done";

  return null;
}

function SyncStatusBadge({ variant }: { variant: SyncBadgeVariant }) {
  const { t } = useTranslation();

  if (!variant) return null;

  const ariaLabels: Record<Exclude<SyncBadgeVariant, null>, string> = {
    offline: t("offline.mode"),
    error: t("settings.storage.sync.phases.error"),
    syncing: t("settings.storage.sync.syncNow"),
    done: t("settings.storage.sync.phases.done"),
  };

  return (
    <span
      role="status"
      aria-label={ariaLabels[variant]}
      className={cn(
        "absolute -bottom-0.5 -right-0.5 flex h-3.5 w-3.5 items-center justify-center rounded-full border-2 border-background",
        variant === "offline" && "bg-red-500",
        variant === "error" && "bg-amber-500",
        variant === "syncing" && "bg-blue-500",
        variant === "done" && "bg-emerald-500",
      )}
    >
      {variant === "syncing" && (
        <RefreshCw className="h-2 w-2 text-white animate-spin" />
      )}
      {variant === "error" && <AlertTriangle className="h-2 w-2 text-white" />}
      {variant === "offline" && <WifiOff className="h-2 w-2 text-white" />}
      {variant === "done" && <Check className="h-2 w-2 text-white" />}
    </span>
  );
}

function SyncSection({ variant }: { variant: "mobile" | "desktop" }) {
  const isOnline = useIsOnline();
  const libraryCaching = useLibraryCaching();
  const syncState = useSyncState();
  const lastSyncedAt = useLastSyncedAt();
  const { t } = useTranslation();

  if (!isOnline) {
    const content = (
      <>
        <WifiOff className="h-4 w-4" />
        <span className="text-xs font-medium">{t("offline.mode")}</span>
      </>
    );
    if (variant === "mobile") {
      return (
        <div className="px-4 py-3 border-t">
          <div className="flex items-center gap-2 text-red-500">{content}</div>
          <p className="text-[10px] text-muted-foreground mt-1">
            {t("offline.disconnected")}
          </p>
        </div>
      );
    }
    return (
      <>
        <div className="px-2 py-2">
          <div className="flex items-center gap-2 text-red-500">{content}</div>
          <p className="text-[10px] text-muted-foreground mt-0.5">
            {t("offline.disconnected")}
          </p>
        </div>
        <DropdownMenuSeparator />
      </>
    );
  }

  if (!libraryCaching) return null;

  if (variant === "mobile") {
    return (
      <div className="px-4 py-3 border-t">
        <SyncPopoverContent syncState={syncState} lastSyncedAt={lastSyncedAt} />
      </div>
    );
  }

  return (
    <>
      <div className="px-2 py-2">
        <SyncPopoverContent syncState={syncState} lastSyncedAt={lastSyncedAt} />
      </div>
      <DropdownMenuSeparator />
    </>
  );
}

export function UserDropdown() {
  const { username, url, lockUser } = useAppData();
  const avatarUrl = useAvatarUrl(username);
  const setLogoutDialogState = useAppStore(
    (state) => state.actions.setLogoutDialogState,
  );
  const { t } = useTranslation();
  const navigate = useNavigate();
  const isMobile = useIsMobile();
  const { status: swStatus, applyUpdate } = useSwUpdate();
  const { setOpenDialog } = useAppSettings();

  const [shortcutsOpen, setShortcutsOpen] = useState(false);
  const [aboutOpen, setAboutOpen] = useState(false);

  const [drawerOpen, setDrawerOpen] = useState(false);

  const badgeVariant = useSyncBadgeVariant();

  function handleSettingsClick() {
    if (isMobile) {
      setDrawerOpen(false);
      navigate(ROUTES.MOBILE.SETTINGS);
    } else {
      setOpenDialog(true);
    }
  }

  useHotkeys("shift+ctrl+q", () => setLogoutDialogState(true));
  useHotkeys("mod+/", () => setShortcutsOpen((prev) => !prev));

  const alignPosition = isMacOS ? "end" : "center";


  return (
    <>
      <LogoutObserver />

      <ShortcutsDialog open={shortcutsOpen} onOpenChange={setShortcutsOpen} />
      <AboutDialog open={aboutOpen} onOpenChange={setAboutOpen} />


      {isMobile ? (
        <Drawer open={drawerOpen} onOpenChange={setDrawerOpen}>
          <DrawerTrigger className="user-dropdown-trigger">
            <div className="relative w-8 h-8 rounded-full">
              <Avatar className="w-8 h-8 rounded-full cursor-pointer">
                <AvatarImage src={avatarUrl ?? undefined} alt={username} />
                <AvatarFallback className="text-sm bg-transparent hover-supported:bg-accent rounded-full">
                  <User className="w-4 h-4" />
                </AvatarFallback>
              </Avatar>
              <SyncStatusBadge variant={badgeVariant} />
            </div>
          </DrawerTrigger>
          <DrawerContent className="h-[calc(100dvh-env(safe-area-inset-top)-12px)] rounded-t-[24px]">
            <DrawerHeader className="text-left">
              <div className="flex items-center gap-3">
                <div className="relative">
                  <Avatar className="w-10 h-10 rounded-full">
                    <AvatarImage src={avatarUrl ?? undefined} alt={username} />
                    <AvatarFallback className="text-sm bg-muted">
                      <User className="w-5 h-5" />
                    </AvatarFallback>
                  </Avatar>
                  <SyncStatusBadge variant={badgeVariant} />
                </div>
                <div className="flex flex-col space-y-1 overflow-hidden">
                  <DrawerTitle className="text-sm font-medium leading-none truncate">
                    {username}
                  </DrawerTitle>
                  <DrawerDescription className="text-xs leading-none truncate">
                    {url}
                  </DrawerDescription>
                </div>
              </div>
            </DrawerHeader>

            <div className="border-t" />
            <SyncSection variant="mobile" />
            <div className="border-t" />

            <div className="flex flex-col gap-1.5 px-4 pb-2">

              <DrawerClose asChild>
                <button
                  onClick={handleSettingsClick}
                  className="flex items-center gap-3 rounded-md px-3 py-4 text-sm hover-supported:bg-accent w-full text-left"
                >
                  <Settings className="h-4 w-4" />
                  <span>{t("settings.label")}</span>
                </button>
              </DrawerClose>
              <DrawerClose asChild>
                <button
                  onClick={() => setAboutOpen(true)}
                  className="flex items-center gap-3 rounded-md px-3 py-4 text-sm hover-supported:bg-accent w-full text-left"
                >
                  <Info className="h-4 w-4" />
                  <span>{t("menu.about")}</span>
                </button>
              </DrawerClose>
              {swStatus === "waiting" && (
                <DrawerClose asChild>
                  <button
                    onClick={() => applyUpdate()}
                    className="flex items-center gap-3 rounded-md px-3 py-4 text-sm text-primary font-medium hover-supported:bg-accent w-full text-left"
                  >
                    <RefreshCw className="h-4 w-4" />
                    <span>{t("update.sw.refresh")}</span>
                  </button>
                </DrawerClose>
              )}
              {!lockUser && (
                <DrawerClose asChild>
                  <button
                    onClick={() => setLogoutDialogState(true)}
                    className="flex items-center gap-3 rounded-md px-3 py-4 text-sm text-destructive hover-supported:bg-accent w-full text-left"
                  >
                    <LogOut className="h-4 w-4" />
                    <span>{t("menu.serverLogout")}</span>
                  </button>
                </DrawerClose>
              )}
            </div>
          </DrawerContent>
        </Drawer>
      ) : (
        <DropdownMenu>
          <DropdownMenuTrigger className="user-dropdown-trigger">
            <div className="relative w-8 h-8 rounded-full">
              <Avatar className="w-8 h-8 rounded-full cursor-pointer items-center justify-center">
                <AvatarImage
                  src={avatarUrl ?? undefined}
                  alt={username}
                  className="w-6 h-6 rounded-full"
                />
                <AvatarFallback className="text-sm bg-transparent hover-supported:bg-accent">
                  <User className="w-4 h-4" />
                </AvatarFallback>
              </Avatar>
              <SyncStatusBadge variant={badgeVariant} />
            </div>
          </DropdownMenuTrigger>
          <DropdownMenuContent align={alignPosition} className="min-w-72">
            <DropdownMenuLabel className="font-normal">
              <div className="flex items-center justify-between">
                <div className="flex flex-col space-y-2">
                  <p className="text-sm font-medium leading-none">{username}</p>
                  <p className="text-xs leading-none text-muted-foreground">
                    {url}
                  </p>
                </div>
                {!lockUser && (
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      setLogoutDialogState(true);
                    }}
                    className="p-1.5 rounded-md hover-supported:bg-accent text-muted-foreground hover-supported:text-foreground"
                    title={t("menu.serverLogout")}
                  >
                    <LogOut className="h-4 w-4" />
                  </button>
                )}
              </div>
            </DropdownMenuLabel>
            <DropdownMenuSeparator />
            <SyncSection variant="desktop" />
            <DropdownMenuItem onClick={() => setShortcutsOpen(true)}>
              <Keyboard className="mr-2 h-4 w-4" />
              <span>{t("shortcuts.modal.title")}</span>
              <DropdownMenuShortcut>
                {stringifyShortcut(shortcutDialogKeys)}
              </DropdownMenuShortcut>
            </DropdownMenuItem>

            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={handleSettingsClick}>
              <Settings className="mr-2 h-4 w-4" />
              <span>{t("settings.label")}</span>
              <DropdownMenuShortcut>
                {stringifyShortcut(settingsKeys)}
              </DropdownMenuShortcut>
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={() => setAboutOpen(true)}>
              <Info className="mr-2 h-4 w-4" />
              <span>{t("menu.about")}</span>
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      )}
    </>
  );
}
