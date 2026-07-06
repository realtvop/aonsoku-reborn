import {
  Loader2,
  MonitorSpeaker,
  RefreshCw,
  Settings,
  WifiOff,
  Link,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";
import { Button } from "@/app/components/ui/button";
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
  DrawerTrigger,
} from "@/app/components/ui/drawer";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/app/components/ui/popover";
import { ScrollArea } from "@/app/components/ui/scroll-area";
import { usePlayerBreakpoint } from "@/app/hooks/use-player-breakpoint";
import { useCoordinationStore } from "@/coordination/store";
import { cn } from "@/lib/utils";
import { ROUTES } from "@/routes/routesList";
import { useAppSettings } from "@/store/app.store";
import { HandoffStatusRow } from "./handoff-status-row";
import {
  LiveDevicesSection,
  OfflineSnapshotsSection,
  ThisDeviceSection,
} from "./sections";
import type { DevicePlaybackActions } from "./use-device-playback-actions";
import { useDevicePlaybackModels } from "./use-device-playback-models";

interface DevicePanelProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  actions: DevicePlaybackActions;
  trigger: React.ReactNode;
}

export function DevicePanel({
  open,
  onOpenChange,
  actions,
  trigger,
}: DevicePanelProps) {
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
        backButtonPriority={10}
        snapPoints={[0.5, 1]}
        activeSnapPoint={activeSnapPoint}
        setActiveSnapPoint={setActiveSnapPoint}
      >
        <DrawerTrigger asChild>{trigger}</DrawerTrigger>
        <DrawerContent className="h-[calc(100dvh-env(safe-area-inset-top)-12px)] rounded-t-[24px]">
          <DevicePanelContent
            onOpenChange={onOpenChange}
            actions={actions}
            activeSnapPoint={activeSnapPoint}
          />
        </DrawerContent>
      </Drawer>
    );
  }

  return (
    <Popover open={open} onOpenChange={onOpenChange}>
      <PopoverTrigger asChild>{trigger}</PopoverTrigger>
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
  activeSnapPoint?: string | number;
}

function DevicePanelContent({
  onOpenChange,
  actions,
  activeSnapPoint,
}: DevicePanelContentProps) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const isMobile = usePlayerBreakpoint();
  const { setOpenDialog, setCurrentPage } = useAppSettings();

  const isConnected = useCoordinationStore((state) => state.isConnected);
  const connectionState = useCoordinationStore(
    (state) => state.connectionState,
  );
  const deviceId = useCoordinationStore((state) => state.deviceId);
  const loadState = useCoordinationStore((state) => state.loadState);
  const models = useDevicePlaybackModels();

  const scrollRef = useRef<HTMLDivElement>(null);
  const [hasOverflow, setHasOverflow] = useState(false);
  const [isRetrying, setIsRetrying] = useState(false);
  const isConnecting =
    isRetrying ||
    connectionState === "connecting" ||
    connectionState === "reconnecting";

  const handleGoToSettings = () => {
    onOpenChange(false);
    if (isMobile) {
      navigate(ROUTES.MOBILE.SETTINGS);
    } else {
      setOpenDialog(true);
      setCurrentPage("cross-device");
    }
  };


  useEffect(() => {
    if (!isMobile || activeSnapPoint !== 1) {
      setHasOverflow(false);
      return;
    }

    const checkOverflow = () => {
      if (scrollRef.current) {
        const { scrollHeight, clientHeight } = scrollRef.current;
        setHasOverflow(scrollHeight > clientHeight + 5);
      }
    };

    checkOverflow();
    window.addEventListener("resize", checkOverflow);

    const observer = new MutationObserver(checkOverflow);
    if (scrollRef.current) {
      observer.observe(scrollRef.current, { childList: true, subtree: true });
    }

    return () => {
      window.removeEventListener("resize", checkOverflow);
      observer.disconnect();
    };
  }, [isMobile, activeSnapPoint]);

  const sectionsContent = (
    <div className="flex flex-col gap-5 p-5">
      <HandoffStatusRow
        phase={actions.handoffPhase}
        error={actions.handoffError}
      />

      <ThisDeviceSection
        model={models.thisDevice}
        isControlling={actions.isControlling}
        onExitControl={actions.exitRemoteControl}
      />

      <LiveDevicesSection
        models={models.liveDevices}
        controlledDeviceName={actions.controlledDeviceName}
        onControl={actions.enterRemoteControl}
        onExitControl={actions.exitRemoteControl}
        onContinue={actions.requestHandoff}
      />

      <OfflineSnapshotsSection
        models={models.offlineSnapshots}
        onContinue={actions.requestHandoff}
      />
    </div>
  );

  const disconnectedConfiguredContent = (
    <div className="flex flex-col gap-5 p-5">
      <ThisDeviceSection
        model={models.thisDevice}
        isControlling={actions.isControlling}
        onExitControl={actions.exitRemoteControl}
      />

      <div className="flex flex-col gap-3 px-1">
        <div className="flex items-center gap-2 text-muted-foreground">
          <WifiOff className="w-4 h-4 flex-shrink-0" />
          <h3 className="font-semibold text-sm text-foreground">
            {t("settings.crossDevice.error.connectFailed", {
              defaultValue: "Connection failed",
            })}
          </h3>
        </div>
        <p className="text-xs text-muted-foreground leading-relaxed">
          {t("settings.crossDevice.error.disconnectedDescription", {
            defaultValue:
              "Remote devices are unavailable until the coordination server reconnects.",
          })}
        </p>
        <Button
          variant="outline"
          size="sm"
          onClick={async () => {
            if (isConnecting) return;
            setIsRetrying(true);
            try {
              await loadState();
            } finally {
              setIsRetrying(false);
            }
          }}
          disabled={isConnecting}
          className="self-start text-xs font-semibold gap-1.5"
        >
          {isConnecting ? (
            <Loader2 className="w-3.5 h-3.5 animate-spin" />
          ) : (
            <RefreshCw className="w-3.5 h-3.5" />
          )}
          {t("settings.crossDevice.retry", {
            defaultValue: "Retry",
          })}
        </Button>
      </div>
    </div>
  );

  const unconfiguredContent = (
    <div className="flex flex-col gap-5 p-5">
      <ThisDeviceSection
        model={models.thisDevice}
        isControlling={actions.isControlling}
        onExitControl={actions.exitRemoteControl}
      />

      <div className="flex flex-col gap-3 px-1">
        <div className="flex items-center gap-2 text-muted-foreground">
          <Link className="w-4 h-4 text-primary flex-shrink-0" />
          <h3 className="font-semibold text-sm text-foreground">
            {t("settings.crossDevice.error.unconfiguredTitle", {
              defaultValue: "Cross-device Playback",
            })}
          </h3>
        </div>
        <p className="text-xs text-muted-foreground leading-relaxed">
          {t("settings.crossDevice.error.unconfiguredDescription", {
            defaultValue: "Connect to coordination server",
          })}
        </p>
        <Button
          variant="outline"
          size="sm"
          onClick={handleGoToSettings}
          className="self-start text-xs font-semibold gap-1.5"
        >
          <Settings className="w-3.5 h-3.5" />
          {t("settings.crossDevice.connect", {
            defaultValue: "Configure Settings",
          })}
        </Button>
      </div>
    </div>
  );


  return (
    <div
      className={cn(
        "flex flex-col h-full w-full text-left",
        !isMobile && "overflow-hidden",
      )}
    >
      {/* Custom Header (Reusable across Sheet and Popover) */}
      {isMobile ? (
        <>
          <DrawerHeader className="text-left pb-4 flex-shrink-0">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <MonitorSpeaker className="w-5 h-5 text-primary" />
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
              <MonitorSpeaker className="w-5 h-5 text-primary" />
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
      <div className={cn("flex-1", isMobile ? "min-h-0" : "overflow-hidden")}>
        {!isConnected && deviceId ? (
          isMobile ? (
            <div
              ref={scrollRef}
              className={cn(
                "h-auto max-h-full",
                hasOverflow ? "overflow-y-auto" : "",
              )}
            >
              {disconnectedConfiguredContent}
            </div>
          ) : (
            <ScrollArea className="h-full">
              {disconnectedConfiguredContent}
            </ScrollArea>
          )
        ) : !deviceId ? (
          isMobile ? (
            <div
              ref={scrollRef}
              className={cn(
                "h-auto max-h-full",
                hasOverflow ? "overflow-y-auto" : "",
              )}
            >
              {unconfiguredContent}
            </div>
          ) : (
            <ScrollArea className="h-full">
              {unconfiguredContent}
            </ScrollArea>
          )
        ) : isMobile ? (
          <div
            ref={scrollRef}
            className={cn(
              "h-auto max-h-full",
              hasOverflow ? "overflow-y-auto" : "",
            )}
          >
            {sectionsContent}
          </div>
        ) : (
          <ScrollArea className="h-full">{sectionsContent}</ScrollArea>
        )}
      </div>
    </div>
  );
}
