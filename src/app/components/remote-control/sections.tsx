import { useState } from "react";
import { ChevronDown, ChevronRight, Laptop, Smartphone, Tv, Cast, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/app/components/ui/button";
import { DevicePlaybackCard } from "./device-playback-card";
import type { DevicePlaybackModel } from "./types";

function getDeviceIcon(platform: string) {
  const p = platform.toLowerCase();
  if (
    p.includes("ios") ||
    p.includes("android") ||
    p.includes("phone") ||
    p.includes("mobile")
  ) {
    return <Smartphone className="w-4 h-4 text-muted-foreground" />;
  }
  if (
    p.includes("electron") ||
    p.includes("desktop") ||
    p.includes("mac") ||
    p.includes("windows") ||
    p.includes("linux")
  ) {
    return <Laptop className="w-4 h-4 text-muted-foreground" />;
  }
  if (p.includes("tv")) {
    return <Tv className="w-4 h-4 text-muted-foreground" />;
  }
  return <Cast className="w-4 h-4 text-muted-foreground" />;
}

// 1. ThisDeviceSection
interface ThisDeviceSectionProps {
  model: DevicePlaybackModel | null;
  isControlling: boolean;
  controlledDeviceName: string | null;
  onExitControl: () => void;
}

export function ThisDeviceSection({
  model,
  isControlling,
  controlledDeviceName,
  onExitControl,
}: ThisDeviceSectionProps) {
  const { t } = useTranslation();

  if (isControlling && controlledDeviceName) {
    return (
      <div className="flex flex-col gap-2 p-4 rounded-xl border border-primary/30 bg-primary/5 backdrop-blur-md">
        <div className="flex items-center justify-between">
          <div className="flex flex-col min-w-0">
            <span className="text-xs font-semibold text-primary uppercase tracking-wider">
              {t("settings.crossDevice.playback.remoteControl", { defaultValue: "Remote Mode" })}
            </span>
            <span className="text-sm font-medium text-foreground truncate mt-0.5">
              {t("settings.crossDevice.playback.controlling", {
                defaultValue: "Controlling {{name}}",
                name: controlledDeviceName,
              })}
            </span>
          </div>
          <Button
            variant="destructive"
            size="sm"
            onClick={onExitControl}
            className="h-8 px-3 text-xs gap-1.5 font-semibold transition-all shadow-sm"
          >
            <X className="w-3.5 h-3.5" />
            {t("settings.crossDevice.playback.exitControl", { defaultValue: "Exit" })}
          </Button>
        </div>
      </div>
    );
  }

  if (!model) return null;

  return (
    <div className="flex flex-col gap-2 p-3.5 rounded-xl border border-border/40 bg-card/25 backdrop-blur-md">
      <span className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
        {t("settings.crossDevice.playback.thisDevice", { defaultValue: "This Device" })}
      </span>
      <div className="flex items-center gap-2 mt-1">
        {getDeviceIcon(model.device.platform)}
        <span className="text-sm font-semibold text-foreground truncate">{model.device.name}</span>
        <span className="text-xs text-muted-foreground/80">({t("settings.crossDevice.device.current", { defaultValue: "Local Target" })})</span>
      </div>
    </div>
  );
}

// 2. LiveDevicesSection
interface LiveDevicesSectionProps {
  models: DevicePlaybackModel[];
  onControl: (model: DevicePlaybackModel) => void;
  onContinue: (model: DevicePlaybackModel) => void;
}

export function LiveDevicesSection({
  models,
  onControl,
  onContinue,
}: LiveDevicesSectionProps) {
  const { t } = useTranslation();

  if (models.length === 0) return null;

  return (
    <div className="flex flex-col gap-3">
      <span className="text-xs font-bold text-muted-foreground uppercase tracking-wider px-1">
        {t("settings.crossDevice.playback.liveDevices", { defaultValue: "Live peer devices" })}
      </span>
      <div className="flex flex-col gap-3">
        {models.map((model) => (
          <DevicePlaybackCard
            key={model.device.id}
            model={model}
            onControl={() => onControl(model)}
            onContinue={() => onContinue(model)}
          />
        ))}
      </div>
    </div>
  );
}

// 3. OfflineSnapshotsSection
interface OfflineSnapshotsSectionProps {
  models: DevicePlaybackModel[];
  onContinue: (model: DevicePlaybackModel) => void;
}

export function OfflineSnapshotsSection({
  models,
  onContinue,
}: OfflineSnapshotsSectionProps) {
  const { t } = useTranslation();
  const [isExpanded, setIsExpanded] = useState(true);

  if (models.length === 0) return null;

  return (
    <div className="flex flex-col gap-2">
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
        className="flex items-center justify-between w-full py-1 px-1 hover:text-foreground text-muted-foreground transition-colors"
      >
        <span className="text-xs font-bold uppercase tracking-wider text-left">
          {t("settings.crossDevice.playback.offlineSnapshots", { defaultValue: "Continue from offline playback" })}
        </span>
        {isExpanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
      </button>

      {isExpanded && (
        <div className="flex flex-col gap-3 mt-1">
          {models.map((model) => (
            <DevicePlaybackCard
              key={model.device.id}
              model={model}
              isOffline={true}
              onContinue={() => onContinue(model)}
            />
          ))}
        </div>
      )}
    </div>
  );
}
