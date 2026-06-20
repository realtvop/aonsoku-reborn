import { SettingsOptions } from "@/app/components/settings/options";
import { useAppSettings } from "@/store/app.store";
import { Accounts } from "./accounts";
import { Appearance } from "./appearance";
import { Audio } from "./audio";
import { Content } from "./content";
import { CrossDeviceSettings } from "./cross-device";
import { Desktop } from "./desktop";
import { Language } from "./language";
import { Privacy } from "./privacy";
import { ServerSettings } from "./server";
import { Storage } from "./storage";

const pages: Record<SettingsOptions, JSX.Element> = {
  server: <ServerSettings />,
  appearance: <Appearance />,
  audio: <Audio />,
  language: <Language />,
  content: <Content />,
  storage: <Storage />,
  accounts: <Accounts />,
  desktop: <Desktop />,
  "cross-device": <CrossDeviceSettings />,
  privacy: <Privacy />,
};

export function Pages() {
  const { currentPage } = useAppSettings();

  return pages[currentPage];
}
