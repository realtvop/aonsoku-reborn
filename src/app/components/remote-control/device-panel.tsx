import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";
import { MonitorSpeaker, Settings, WifiOff } from "lucide-react";
import { Popover, PopoverContent } from "@/app/components/ui/popover";
import * as PopoverPrimitive from "@radix-ui/react-popover";
import {
  Drawer,
  DrawerTrigger,
  DrawerContent,
  DrawerHeader,
  DrawerTitle,
  DrawerDescription,
} from "@/app/components/ui/drawer";
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
  trigger: React.ReactNode;
}

export function DevicePanel({ open, onOpenChange, actions, trigger }: DevicePanelProps) {
  const isMobile = usePlayerBreakpoint();
  const [activeSnapPoint, setActiveSnapPoint] = useState<string | number>(0.5);

  useEffect(() => {
    if (isMobile) {
      if (open) {
        setActiveSnapPoint(0.5);
        window.dispatchEvent(new CustomEvent("device-panel-opened"));
      } else {
        window.dispatchEvent(new CustomEvent("device-panel-closed"));
      }
    }
    return () => {
      if (isMobile) {
        window.dispatchEvent(new CustomEvent("device-panel-closed"));
      }
    };
  }, [open, isMobile]);

  if (isMobile) {
    return (
      <Drawer
        open={open}
        onOpenChange={onOpenChange}
        snapPoints={[0.5, 1]}
        activeSnapPoint={activeSnapPoint}
        setActiveSnapPoint={setActiveSnapPoint}
      >
        <DrawerTrigger asChild>
          {trigger}
        </DrawerTrigger>
        <DrawerContent className="h-[calc(100dvh-env(safe-area-inset-top)-12px)] rounded-t-[24px]">
          <DevicePanelContent onOpenChange={onOpenChange} actions={actions} />
        </DrawerContent>
      </Drawer>
    );
  }

  return (
    <Popover open={open} onOpenChange={onOpenChange}>
      <PopoverPrimitive.Anchor asChild>
        <div className="inline-block">
          {trigger}
        </div>
      </PopoverPrimitive.Anchor>
      <PopoverContent
        align="end"
        side="top"
        sideOffset={12}
        className="w-[380px] h-[500px] p-0 rounded-2xl border border-border/40 bg-background/95 backdrop-blur-xl shadow-2xl flex flex-col overflow-hidden animate-in fade-in zoom-in-95 duration-200"
      >
        <DevicePanelContent onOpenChange={onOpenChange} actions={actions} />
      </PopoverContent>
    </Popover>
  );
}

interface DevicePanelContentProps {
  onOpenChange: (open: boolean) => void;
  actions: DevicePlaybackActions;
}

function DevicePanelContent({ onOpenChange, actions }: DevicePanelContentProps) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const isMobile = usePlayerBreakpoint();
  const { setOpenDialog, setCurrentPage } = useAppSettings();

  const isConnected = useCoordinationStore((state) => state.isConnected);
  const deviceId = useCoordinationStore((state) => state.deviceId);
  const models = useDevicePlaybackModels();

  const sectionsContent = (
    <div className="flex flex-col gap-5 p-5">
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
  );

  const handleGoToSettings = () => {
    onOpenChange(false);
    if (isMobile) {
      navigate(ROUTES.MOBILE.SETTINGS);
    } else {
      setOpenDialog(true);
      setCurrentPage("cross-device");
    }
  };

  return (
    <div className="flex flex-col h-full w-full overflow-hidden text-left">
      {/* Custom Header (Reusable across Sheet and Popover) */}
      {isMobile ? (
        <>
          <DrawerHeader className="text-left pb-4 flex-shrink-0">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <MonitorSpeaker className="w-5 h-5 text-primary animate-pulse" />
                <DrawerTitle className="text-sm font-bold text-foreground">
                  {t("settings.crossDevice.title", { defaultValue: "Devices" })}
                </DrawerTitle>
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
            <DrawerDescription className="text-xs text-muted-foreground text-left mt-0.5">
              {t("settings.crossDevice.description", {
                defaultValue: "Manage active devices and continue playback.",
              })}
            </DrawerDescription>
          </DrawerHeader>
          <div className="border-t border-border/20" />
        </>
      ) : (
        <div className="p-5 pb-4 border-b border-border/20 flex flex-col gap-1 flex-shrink-0">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <MonitorSpeaker className="w-5 h-5 text-primary animate-pulse" />
              <h2 className="text-sm font-bold text-foreground">
                {t("settings.crossDevice.title", { defaultValue: "Devices" })}
              </h2>
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
          <p className="text-xs text-muted-foreground text-left mt-0.5">
            {t("settings.crossDevice.description", {
              defaultValue: "Manage active devices and continue playback.",
            })}
          </p>
        </div>
      )}

      {/* Main List Scroll Area */}
      <div className="flex-1 overflow-hidden">
        {!isConnected || !deviceId ? (
          <div className="flex flex-col items-center justify-center h-full p-8 text-center gap-4">
            <div className="p-4 rounded-full bg-muted/50 border border-border/30">
              <WifiOff className="w-8 h-8 text-muted-foreground/60" />
            </div>
            <div className="flex flex-col gap-1">
              <h3 className="font-semibold text-xs text-foreground">
                {t("settings.crossDevice.disconnected", {
                  defaultValue: "Not connected",
                })}
              </h3>
              <p className="text-[11px] text-muted-foreground max-w-xs leading-relaxed">
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
        ) : isMobile ? (
          <div className="h-full overflow-y-auto">
            {sectionsContent}
          </div>
        ) : (
          <ScrollArea className="h-full">
            {sectionsContent}
          </ScrollArea>
        )}
      </div>
    </div>
  );
}
