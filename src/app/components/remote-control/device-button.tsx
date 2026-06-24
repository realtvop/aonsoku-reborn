import { MonitorSpeaker } from "lucide-react";
import { useTranslation } from "react-i18next";
import clsx from "clsx";
import { Button } from "@/app/components/ui/button";
import { SimpleTooltip } from "@/app/components/ui/simple-tooltip";

interface PlayerDeviceButtonProps {
  onClick: () => void;
  isActive?: boolean;
}

export function PlayerDeviceButton({ onClick, isActive = false }: PlayerDeviceButtonProps) {
  const { t } = useTranslation();

  return (
    <SimpleTooltip
      text={t("settings.crossDevice.title", {
        defaultValue: "Devices",
      })}
    >
      <Button
        variant="ghost"
        size="icon"
        onClick={onClick}
        className={clsx(
          "rounded-full w-10 h-10 p-2 text-secondary-foreground relative",
          isActive && "player-button-active"
        )}
        aria-label={t("settings.crossDevice.title", {
          defaultValue: "Devices",
        })}
        unfocusable
      >
        <MonitorSpeaker className={clsx("w-4 h-4", isActive && "text-primary")} />
      </Button>
    </SimpleTooltip>
  );
}
