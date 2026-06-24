import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";
import { Share2, Settings, WifiOff } from "lucide-react";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetDescription,
} from "@/app/components/ui/sheet";
import { ScrollArea } from "@/app/components/ui/scroll-area";
import { Button } from "@/app/components/ui/button";
import { useCoordinationStore } from "@/coordination/store";
import { useAppSettings } from "@/store/app.store";
import { usePlayerBreakpoint } from "@/app/hooks/use-player-breakpoint";
import { ROUTES } from "@/routes/routesList";
import { useDevicePlaybackModels } from "./use-device-playback-models";
import {
  ThisDeviceSection,
  LiveDevicesSection,
  OfflineSnapshotsSection,
} from "./sections";
import type { DevicePlaybackActions } from "./use-device-playback-actions";

interface DevicePanelProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  actions: DevicePlaybackActions;
}

export function DevicePanel({ open, onOpenChange, actions }: DevicePanelProps) {
  const { t } = tTranslationHelper();
  const navigate = useNavigate();
  const isMobile = usePlayerBreakpoint();
  const { setOpenDialog, setCurrentPage } = useAppSettings();

  const isConnected = useCoordinationStore((state) => state.isConnected);
  const deviceId = useCoordinationStore((state) => state.deviceId);
  const models = useDevicePlaybackModels();

  const handleGoToSettings = () => {
    onOpenChange(false);
    if (isMobile) {
      navigate(ROUTES.MOBILE.SETTINGS);
    } else {
      setOpenDialog(true);
      setCurrentPage("cross-device");
    }
  };

  const side = isMobile ? "bottom" : "right";

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        side={side}
        className="flex flex-col h-full w-full sm:max-w-md p-0 border-l border-border/40 bg-background/95 backdrop-blur-xl"
      >
        <SheetHeader className="p-6 pb-4 border-b border-border/20">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Share2 className="w-5 h-5 text-primary" />
              <SheetTitle className="text-lg font-bold">
                {t("settings.crossDevice.title", { defaultValue: "Devices" })}
              </SheetTitle>
            </div>
            <Button
              variant="ghost"
              size="icon"
              onClick={handleGoToSettings}
              className="h-8 w-8 rounded-lg hover:bg-accent/50"
              title={t("sidebar.settings", { defaultValue: "Settings" })}
            >
              <Settings className="w-4 h-4 text-muted-foreground hover:text-foreground transition-colors" />
            </Button>
          </div>
          <SheetDescription className="text-xs text-muted-foreground text-left mt-1.5">
            {t("settings.crossDevice.description", {
              defaultValue: "Manage active devices and continue playback.",
            })}
          </SheetDescription>
        </SheetHeader>

        <div className="flex-1 overflow-hidden">
          {!isConnected || !deviceId ? (
            <div className="flex flex-col items-center justify-center h-full p-8 text-center gap-4">
              <div className="p-4 rounded-full bg-muted/50 border border-border/30">
                <WifiOff className="w-8 h-8 text-muted-foreground/60" />
              </div>
              <div className="flex flex-col gap-1">
                <h3 className="font-semibold text-sm text-foreground">
                  {t("settings.crossDevice.disconnected", {
                    defaultValue: "Not connected",
                  })}
                </h3>
                <p className="text-xs text-muted-foreground max-w-xs">
                  {t("settings.crossDevice.error.missingFields", {
                    defaultValue: "Connect your device in Settings to sync and control playback across devices.",
                  })}
                </p>
              </div>
              <Button
                variant="outline"
                size="sm"
                onClick={handleGoToSettings}
                className="mt-2 text-xs font-semibold gap-1.5"
              >
                <Settings className="w-3.5 h-3.5" />
                {t("settings.crossDevice.connect", { defaultValue: "Configure Settings" })}
              </Button>
            </div>
          ) : (
            <ScrollArea className="h-full">
              <div className="flex flex-col gap-6 p-6">
                <ThisDeviceSection
                  model={models.thisDevice}
                  isControlling={actions.isControlling}
                  controlledDeviceName={actions.controlledDeviceName}
                  onExitControl={actions.exitRemoteControl}
                />

                <LiveDevicesSection
                  models={models.liveDevices}
                  onControl={actions.enterRemoteControl}
                  onContinue={actions.requestHandoff}
                />

                <OfflineSnapshotsSection
                  models={models.offlineSnapshots}
                  onContinue={actions.requestHandoff}
                />
              </div>
            </ScrollArea>
          )}
        </div>
      </SheetContent>
    </Sheet>
  );
}

// Local helper to map t() translation or fallback gracefully
function tTranslationHelper() {
  const { t } = useTranslation();
  return { t };
}
