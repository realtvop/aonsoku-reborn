import { RadioTower, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/app/components/ui/button";
import { useRemoteControlState } from "@/store/player.store";

interface RemoteModePlayerStatusProps {
  onExit: () => void;
  compact?: boolean;
}

export function RemoteModePlayerStatus({
  onExit,
  compact = false,
}: RemoteModePlayerStatusProps) {
  const { t } = useTranslation();
  const remoteControl = useRemoteControlState();

  if (!remoteControl.active) return null;

  const deviceName =
    remoteControl.device?.name ||
    t("settings.crossDevice.playback.peerDevice", {
      defaultValue: "remote device",
    });

  return (
    <div className="flex min-w-0 items-center gap-2 rounded-md border border-primary/30 bg-primary/5 px-2 py-1 text-primary">
      <RadioTower className="size-3.5 shrink-0" />
      <span
        className={
          compact
            ? "max-w-32 truncate text-[10px] font-semibold"
            : "max-w-48 truncate text-xs font-semibold"
        }
      >
        {t("settings.crossDevice.playback.controllingDevice", {
          defaultValue: "Controlling {{name}}",
          name: deviceName,
        })}
      </span>
      <Button
        type="button"
        variant="ghost"
        size="icon"
        onClick={onExit}
        className="size-6 rounded-md text-primary hover:bg-primary/10 hover:text-primary"
        aria-label={t("settings.crossDevice.playback.exitControl", {
          defaultValue: "Exit control",
        })}
        title={t("settings.crossDevice.playback.exitControl", {
          defaultValue: "Exit control",
        })}
      >
        <X className="size-3.5" />
      </Button>
    </div>
  );
}
