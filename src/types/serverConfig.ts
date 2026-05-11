import { SettingsOptions } from "@/app/components/settings/options";

export enum AuthType {
  PASSWORD,
  TOKEN,
}

export interface IServerConfig {
  url: string;
  fallbackUrl?: string;
  username: string;
  password: string;
  protocolVersion?: string;
  serverType?: string;
  connectionMode?: ConnectionMode;
  coordinationUrl?: string;
}

export interface IServerUrlConfig {
  primaryUrl: string;
  fallbackUrl: string;
}

export type ActiveServerType = "primary" | "fallback" | null;

export type ConnectionMode = "coordination" | "direct";

export type PageViewType = "grid" | "table";

interface IAppPages {
  showInfoPanel: boolean;
  toggleShowInfoPanel: () => void;
  hideRadiosSection: boolean;
  setHideRadiosSection: (value: boolean) => void;
  artistsPageViewType: PageViewType;
  setArtistsPageViewType: (type: PageViewType) => void;
}

export interface IAppData extends IServerConfig {
  primaryUrl: string;
  fallbackUrl: string;
  activeServerType: ActiveServerType;
  authType: AuthType | null;
  isServerConfigured: boolean;
  osType: string;
  logoutDialogState: boolean;
  hideServer: boolean;
  lockUser: boolean;
  songCount: number | null;
  favoriteCount: number | null;
  connectionMode: ConnectionMode;
  coordinationUrl: string;
}

export interface IAppActions {
  setOsType: (value: string) => void;
  setUrl: (value: string) => void;
  setUsername: (value: string) => void;
  setPassword: (value: string) => void;
  setCoordinationUrl: (value: string) => void;
  setConnectionMode: (value: ConnectionMode) => void;
  saveConfig: (data: IServerConfig) => Promise<boolean>;
  saveServerUrls: (data: IServerUrlConfig) => Promise<boolean>;
  selectConfiguredServer: () => Promise<boolean>;
  removeConfig: () => void;
  setLogoutDialogState: (value: boolean) => void;
}

export interface IAppCommand {
  open: boolean;
  setOpen: (value: boolean) => void;
}

export interface IAppUpdate {
  openDialog: boolean;
  setOpenDialog: (value: boolean) => void;
  remindOnNextBoot: boolean;
  setRemindOnNextBoot: (value: boolean) => void;
}

interface IAppSettings {
  openDialog: boolean;
  setOpenDialog: (value: boolean) => void;
  currentPage: SettingsOptions;
  setCurrentPage: (page: SettingsOptions) => void;
}

interface IAccounts {
  discord: {
    rpcEnabled: boolean;
    setRpcEnabled: (value: boolean) => void;
  };
}

// When changing the desktop data types
// You have to update the electron one.
// Located at -> electron > main > core > settings.ts
interface IDesktop {
  data: {
    minimizeToTray: boolean;
  };
  actions: {
    setMinimizeToTray: (value: boolean) => void;
  };
}

export interface IAppContext {
  data: IAppData;
  accounts: IAccounts;
  pages: IAppPages;
  desktop: IDesktop;
  command: IAppCommand;
  actions: IAppActions;
  update: IAppUpdate;
  settings: IAppSettings;
}
