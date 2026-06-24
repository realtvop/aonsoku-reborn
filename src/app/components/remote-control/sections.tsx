import { useState } from "react";
import { ChevronDown, ChevronRight } from "lucide-react";
import { useTranslation } from "react-i18next";
import { DevicePlaybackCard } from "./device-playback-card";
import type { DevicePlaybackModel } from "./types";

// 1. ThisDeviceSection
interface ThisDeviceSectionProps {
  model: DevicePlaybackModel | null;
  isControlling: boolean;
  onExitControl: () => void;
}

export function ThisDeviceSection({
  model,
  isControlling,
  onExitControl,
}: ThisDeviceSectionProps) {
  const { t } = useTranslation();

  if (!model) return null;

  const isActive = !isControlling;

  return (
    <div className="flex flex-col gap-2.5">
      <span className="text-xs font-bold text-muted-foreground uppercase tracking-wider px-1">
        {t("settings.crossDevice.playback.thisDevice", { defaultValue: "This Device" })}
      </span>
      <DevicePlaybackCard
        model={model}
        isActive={isActive}
        onControl={isControlling ? onExitControl : undefined}
      />
    </div>
  );
}

// 2. LiveDevicesSection
interface LiveDevicesSectionProps {
  models: DevicePlaybackModel[];
  controlledDeviceName: string | null;
  onControl: (model: DevicePlaybackModel) => void;
  onExitControl: () => void;
  onContinue: (model: DevicePlaybackModel) => void;
}

export function LiveDevicesSection({
  models,
  controlledDeviceName,
  onControl,
  onExitControl,
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
        {models.map((model) => {
          const isActive = controlledDeviceName === model.device.name;
          return (
            <DevicePlaybackCard
              key={model.device.id}
              model={model}
              isActive={isActive}
              onControl={
                isActive
                  ? onExitControl
                  : model.canBeControlled
                    ? () => onControl(model)
                    : undefined
              }
              onContinue={
                model.canBeContinuedLocally ? () => onContinue(model) : undefined
              }
            />
          );
        })}
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
              onContinue={
                model.canBeContinuedLocally ? () => onContinue(model) : undefined
              }
            />
          ))}
        </div>
      )}
    </div>
  );
}
