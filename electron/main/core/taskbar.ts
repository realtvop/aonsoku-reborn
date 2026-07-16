import { is } from "@electron-toolkit/utils";
import { app, nativeImage, nativeTheme } from "electron";
import { join } from "path";
import { mainWindow } from "../window";
import {
  dispatchDesktopPlaybackAction,
  getDesktopPlaybackControlState,
} from "./playerControls";

export const resourcesPath = join(
  is.dev ? app.getAppPath() : process.resourcesPath,
  "resources",
);
const taskbarIconsPath = join(resourcesPath, "taskbar");

const buttons = {
  previous: "skip_previous.png",
  pause: "pause.png",
  play: "play.png",
  next: "skip_next.png",
};

export function getTaskbarIcon(icon: keyof typeof buttons) {
  const themeFolder = nativeTheme.shouldUseDarkColors ? "dark" : "light";

  const iconName = buttons[icon];
  const iconPath = join(taskbarIconsPath, themeFolder, iconName);

  return nativeImage.createFromPath(iconPath);
}

export function setTaskbarButtons() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (!mainWindow.isVisible()) return;

  const { isPlaying, hasPrevious, hasNext, hasSonglist } =
    getDesktopPlaybackControlState();

  mainWindow.setThumbarButtons([
    {
      icon: getTaskbarIcon("previous"),
      flags: hasPrevious ? undefined : ["disabled"],
      click() {
        dispatchDesktopPlaybackAction("skipBackwards").catch(() => {});
      },
    },
    {
      icon: getTaskbarIcon(isPlaying ? "pause" : "play"),
      flags: hasSonglist ? undefined : ["disabled"],
      click() {
        dispatchDesktopPlaybackAction("togglePlayPause").catch(() => {});
      },
    },
    {
      icon: getTaskbarIcon("next"),
      flags: hasNext ? undefined : ["disabled"],
      click() {
        dispatchDesktopPlaybackAction("skipForward").catch(() => {});
      },
    },
  ]);
}
