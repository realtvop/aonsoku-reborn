import { Share2 } from "lucide-react";
import { useTranslation } from "react-i18next";
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
        onClick={onClick}
        className={`size-11 p-0 rounded-lg transition-all duration-200 ${
          isActive ? "text-primary bg-primary/10" : "text-foreground hover:bg-accent/40"
        }`}
        aria-label={t("settings.crossDevice.title", {
          defaultValue: "Devices",
        })}
      >
        <Share2 className="w-5 h-5" />
      </Button>
    </SimpleTooltip>
  );
}
