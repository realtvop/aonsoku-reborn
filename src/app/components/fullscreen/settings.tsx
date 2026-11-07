import { SlidersHorizontal } from "lucide-react";
import { ComponentPropsWithoutRef, ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { Button } from "@/app/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/app/components/ui/popover";
import { Separator } from "@/app/components/ui/separator";
import { Slider } from "@/app/components/ui/slider";
import { Switch } from "@/app/components/ui/switch";
import { useFullscreenContrast } from "@/app/hooks/use-fullscreen-contrast";
import { cn } from "@/lib/utils";
import { isDynamicCoverAvailable } from "@/native/artwork";
import {
  useFullscreenPlayerSettings,
  useSongColor,
} from "@/store/player.store";

export function FullscreenSettings() {
  return (
    <DynamicSettingsPopover>
      <ColorIntensityOption showSeparator={false} />
      <DynamicArtworkOption />
    </DynamicSettingsPopover>
  );
}

function DynamicArtworkOption() {
  const { t } = useTranslation();
  const { dynamicArtworkEnabled, setDynamicArtworkEnabled } =
    useFullscreenPlayerSettings();
  if (!isDynamicCoverAvailable()) return null;
  return (
    <SettingWrapper text={t("fullscreen.dynamicArtwork")}>
      <Switch
        aria-label={t("fullscreen.dynamicArtwork")}
        checked={dynamicArtworkEnabled ?? false}
        onCheckedChange={setDynamicArtworkEnabled}
      />
    </SettingWrapper>
  );
}

interface PopoverProps {
  children: ReactNode;
}

function DynamicSettingsPopover({ children }: PopoverProps) {
  const { t } = useTranslation();
  const { hoverBg } = useFullscreenContrast();

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className={`size-10 rounded-full ${hoverBg}`}
          aria-label={t("settings.label")}
        >
          <SlidersHorizontal className="size-4" strokeWidth={2.5} />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-80 p-0" align="end">
        <div className="flex flex-col">{children}</div>
      </PopoverContent>
    </Popover>
  );
}

type OptionProps = Omit<
  ComponentPropsWithoutRef<typeof SettingWrapper>,
  "text"
>;

function ColorIntensityOption(props: OptionProps) {
  const { t } = useTranslation();
  const { currentSongColorIntensity, setCurrentSongIntensity } = useSongColor();

  return (
    <SettingWrapper
      text={t("settings.appearance.queue.colors.intensity")}
      {...props}
    >
      <Slider
        defaultValue={[currentSongColorIntensity]}
        min={0.3}
        max={1.0}
        step={0.05}
        onValueChange={([value]) => setCurrentSongIntensity(value)}
      />
    </SettingWrapper>
  );
}

type SettingWrapperProps = ComponentPropsWithoutRef<"div"> & {
  text: string;
  showSeparator?: boolean;
};

function SettingWrapper({
  text,
  className,
  children,
  showSeparator = true,
  ...props
}: SettingWrapperProps) {
  return (
    <>
      {showSeparator && <Separator />}
      <div
        className={cn("flex items-center justify-between p-3", className)}
        {...props}
      >
        <span className="text-sm flex-1 text-balance">{text}</span>
        <div className="w-2/5 flex items-center justify-end">{children}</div>
      </div>
    </>
  );
}
