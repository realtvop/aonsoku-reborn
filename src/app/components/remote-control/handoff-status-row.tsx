import { useTranslation } from "react-i18next";
import { Loader2, CheckCircle2, AlertCircle } from "lucide-react";
import type { HandoffPhase } from "@/coordination/types";
import { cn } from "@/lib/utils";

interface HandoffStatusRowProps {
  phase: HandoffPhase | null;
  error: string | null;
}

export function HandoffStatusRow({ phase, error }: HandoffStatusRowProps) {
  const { t } = useTranslation();

  if (!phase && !error) return null;

  // Resolve phase text
  const getPhaseText = (p: HandoffPhase) => {
    switch (p) {
      case "prepare":
        return t("settings.crossDevice.handoff.prepare", {
          defaultValue: "Preparing track...",
        });
      case "prepare_relinquish":
        return t("settings.crossDevice.handoff.relinquish", {
          defaultValue: "Pausing source device...",
        });
      case "commit":
        return t("settings.crossDevice.handoff.commit", {
          defaultValue: "Continuing playback here...",
        });
      case "committed":
        return t("settings.crossDevice.handoff.committed", {
          defaultValue: "Handoff successful!",
        });
      default:
        return t("settings.crossDevice.handoff.processing", {
          defaultValue: "Syncing playback...",
        });
    }
  };

  const isSuccess = phase === "committed";

  return (
    <div
      className={cn(
        "flex items-center gap-2.5 p-3.5 rounded-xl border text-xs font-medium transition-all duration-300 animate-in fade-in slide-in-from-top-2",
        error
          ? "border-destructive/30 bg-destructive/5 text-destructive"
          : isSuccess
          ? "border-primary/30 bg-primary/5 text-foreground"
          : "border-border/40 bg-muted/40 text-muted-foreground"
      )}
    >
      {error ? (
        <>
          <AlertCircle className="w-4 h-4 text-destructive flex-shrink-0" />
          <span className="leading-snug text-left flex-1">{error}</span>
        </>
      ) : (
        <>
          {isSuccess ? (
            <CheckCircle2 className="w-4 h-4 text-primary animate-in zoom-in-50 duration-300 flex-shrink-0" />
          ) : (
            <Loader2 className="w-4 h-4 text-primary animate-spin flex-shrink-0" />
          )}
          <span className={cn("leading-snug text-left flex-1", isSuccess && "text-primary font-semibold")}>
            {phase && getPhaseText(phase)}
          </span>
        </>
      )}
    </div>
  );
}
