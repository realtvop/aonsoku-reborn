import { Monitor, Moon, Sun } from "lucide-react";

export enum ThemeMode {
  Light = "light",
  Dark = "dark",
  System = "system",
}

export enum Theme {
  Light = "light",
  Dark = "dark",
  Black = "black",
  OneDark = "one-dark",
  NightOwlLight = "night-owl-light",
  MarmaladeBeaver = "marmalade-beaver",
  NoctisLilac = "noctis-lilac",
  MaterialTheme = "material-theme",
  MonokaiPro = "monokai-pro",
  GithubDark = "github-dark",
  ShadesOfPurple = "shades-of-purple",
  BeardedSolarized = "bearded-solarized",
  CatppuccinMocha = "catppuccin-mocha",
  NuclearDark = "nuclear-dark",
  Achiever = "achiever",
  Dracula = "dracula",
  Discord = "discord",
  TinaciousDesign = "tinacious-design",
  VueDark = "vue-dark",
  VimDarkSoft = "vim-dark-soft",
}

export const lightThemes: Theme[] = [
  Theme.Light,
  Theme.NightOwlLight,
  Theme.NoctisLilac,
  Theme.Achiever,
  Theme.TinaciousDesign,
];

export const darkThemes: Theme[] = [
  Theme.Dark,
  Theme.Black,
  Theme.OneDark,
  Theme.MarmaladeBeaver,
  Theme.MaterialTheme,
  Theme.MonokaiPro,
  Theme.GithubDark,
  Theme.ShadesOfPurple,
  Theme.BeardedSolarized,
  Theme.CatppuccinMocha,
  Theme.NuclearDark,
  Theme.Dracula,
  Theme.Discord,
  Theme.VueDark,
  Theme.VimDarkSoft,
];

export const themeGroups = [
  { key: "light" as const, label: "theme.modeLight", themes: lightThemes },
  { key: "dark" as const, label: "theme.modeDark", themes: darkThemes },
];

export const themeModeItems = [
  { value: ThemeMode.Light, labelKey: "theme.modeLight", icon: Sun },
  { value: ThemeMode.Dark, labelKey: "theme.modeDark", icon: Moon },
  { value: ThemeMode.System, labelKey: "theme.modeSystem", icon: Monitor },
] as const;

export function isDarkTheme(theme: Theme) {
  return darkThemes.includes(theme);
}

export function getThemeGroupForMode(mode: ThemeMode) {
  return mode === ThemeMode.Light ? themeGroups[0] : themeGroups[1];
}

export interface IThemeContext {
  theme: Theme;
  themeMode: ThemeMode;
  lightTheme: Theme;
  darkTheme: Theme;
  materialYouEnabled: boolean;
  usePointerCursors: boolean;
  setTheme: (theme: Theme) => void;
  setThemeMode: (mode: ThemeMode) => void;
  setLightTheme: (theme: Theme) => void;
  setDarkTheme: (theme: Theme) => void;
  setMaterialYouEnabled: (enabled: boolean) => void;
  setUsePointerCursors: (enabled: boolean) => void;
}
