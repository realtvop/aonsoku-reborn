import {
  ChevronRight,
  EarthLock,
  FileText,
  Globe,
  HardDrive,
  Headphones,
  LaptopIcon,
  Paintbrush,
  Server,
  Share2,
} from "lucide-react";
import { ComponentType } from "react";
import { useTranslation } from "react-i18next";
import { useSearchParams } from "react-router-dom";
import { MobilePageHeader } from "@/app/components/header/mobile-page-header";
import { SettingsOptions } from "@/app/components/settings/options";
import { Appearance } from "@/app/components/settings/pages/appearance";
import { Audio } from "@/app/components/settings/pages/audio";
import { Content } from "@/app/components/settings/pages/content";
import { CrossDeviceSettings } from "@/app/components/settings/pages/cross-device";
import { Desktop } from "@/app/components/settings/pages/desktop";
import { Language } from "@/app/components/settings/pages/language";
import { Privacy } from "@/app/components/settings/pages/privacy";
import { ServerSettings } from "@/app/components/settings/pages/server";
import { Storage } from "@/app/components/settings/pages/storage";
import { isDesktop } from "@/utils/desktop";

interface CategoryItem {
  id: SettingsOptions;
  icon: ComponentType<{ className?: string }>;
}

const desktopOption: CategoryItem = { id: "desktop", icon: LaptopIcon };

const categories: CategoryItem[] = [
  { id: "server", icon: Server },
  { id: "appearance", icon: Paintbrush },
  { id: "language", icon: Globe },
  { id: "audio", icon: Headphones },
  { id: "content", icon: FileText },
  { id: "storage", icon: HardDrive },
  ...(isDesktop() ? [desktopOption] : []),
  { id: "cross-device", icon: Share2 },
  { id: "privacy", icon: EarthLock },
];

const pages: Record<SettingsOptions, () => JSX.Element> = {
  server: () => <ServerSettings />,
  appearance: () => <Appearance />,
  audio: () => <Audio />,
  language: () => <Language />,
  content: () => <Content />,
  storage: () => <Storage />,
  desktop: () => <Desktop />,
  "cross-device": () => <CrossDeviceSettings />,
  privacy: () => <Privacy />,
};

export default function MobileSettings() {
  const { t } = useTranslation();
  const [searchParams, setSearchParams] = useSearchParams();
  const currentPage = searchParams.get("page") as SettingsOptions | null;

  function openPage(id: SettingsOptions) {
    setSearchParams({ page: id }, { replace: true });
  }

  function goBack() {
    setSearchParams({}, { replace: true });
  }

  if (currentPage && pages[currentPage]) {
    const title = t(`settings.options.${currentPage}`);
    return (
      <div className="flex flex-col w-full">
        <MobilePageHeader
          variant="sub"
          title={title}
          onBack={goBack}
          transparentTheme="default"
        />
        <div className="flex flex-col pb-8">
          <div className="px-4 py-4 flex flex-col">
            <h1
              id="detail-page-title"
              className="text-2xl font-bold tracking-tight"
            >
              {title}
            </h1>
          </div>
          <div className="px-4">{pages[currentPage]()}</div>
        </div>
      </div>
    );
  }

  const title = t("settings.label");
  return (
    <div className="flex flex-col w-full">
      <MobilePageHeader
        variant="sub"
        title={title}
        transparentTheme="default"
      />
      <div className="flex flex-col pb-8">
        <div className="px-4 py-4 flex flex-col">
          <h1
            id="detail-page-title"
            className="text-2xl font-bold tracking-tight"
          >
            {title}
          </h1>
        </div>
        <div className="flex flex-col">
          {categories.map((item) => (
            <button
              key={item.id}
              type="button"
              onClick={() => openPage(item.id)}
              className="flex items-center gap-3 px-4 py-3.5 active:bg-accent/50 border-b last:border-b-0"
            >
              <item.icon className="w-5 h-5 text-muted-foreground flex-shrink-0" />
              <span className="flex-1 text-sm text-left">
                {t(`settings.options.${item.id}`)}
              </span>
              <ChevronRight className="w-4 h-4 text-muted-foreground" />
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
