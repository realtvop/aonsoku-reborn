import {
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
import {
  SidebarGroup,
  SidebarGroupContent,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/app/components/ui/sidebar";
import { useAppSettings } from "@/store/app.store";
import { isDesktop } from "@/utils/desktop";

export type SettingsOptions =
  | "server"
  | "appearance"
  | "language"
  | "audio"
  | "content"
  | "storage"
  | "desktop"
  | "cross-device"
  | "privacy";

interface OptionsData {
  id: SettingsOptions;
  icon: ComponentType;
}

const desktopOption: OptionsData = { id: "desktop", icon: LaptopIcon };

const options: OptionsData[] = [
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

export function SettingsOptions() {
  const { t } = useTranslation();
  const { currentPage, setCurrentPage } = useAppSettings();

  return (
    <SidebarGroup>
      <SidebarGroupContent>
        <SidebarMenu>
          {options.map((item) => (
            <SidebarMenuItem key={item.id}>
              <SidebarMenuButton
                isActive={item.id === currentPage}
                onClick={() => setCurrentPage(item.id)}
              >
                <item.icon />
                <span>{t(`settings.options.${item.id}`)}</span>
              </SidebarMenuButton>
            </SidebarMenuItem>
          ))}
        </SidebarMenu>
      </SidebarGroupContent>
    </SidebarGroup>
  );
}
