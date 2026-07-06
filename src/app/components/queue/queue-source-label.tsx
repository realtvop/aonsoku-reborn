import { useTranslation } from "react-i18next";
import { cn } from "@/lib/utils";
import { useQueueSource } from "@/store/player.store";

interface QueueSourceLabelProps {
  className?: string;
  sourceName?: string | null;
}

export function QueueSourceLabel({
  className,
  sourceName,
}: QueueSourceLabelProps) {
  const { t } = useTranslation();
  const localQueueSource = useQueueSource();
  const queueSource = sourceName ?? localQueueSource;

  if (!queueSource) return null;

  return (
    <p
      className={cn("text-xs text-foreground/50 px-2 pb-1 truncate", className)}
    >
      {t("fullscreen.queueFromSource", { source: queueSource })}
    </p>
  );
}
