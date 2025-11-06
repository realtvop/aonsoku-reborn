import { NavigationButtons } from "@/app/components/header/navigation-buttons";
import { UserDropdown } from "@/app/components/header/user-dropdown";
import { SettingsButton } from "@/app/components/settings/header-button";
import { useAppWindow } from "@/app/hooks/use-app-window";
import { isLinux, isWindows } from "@/utils/desktop";
import CommandMenu from "../components/command/command-menu";
import { memo } from "react";
import { Link } from "react-router-dom";
import { Button } from "../components/ui/button";
import { HomeIcon } from "lucide-react";

export function Header() {
  const { isFullscreen } = useAppWindow();
  const MemoCommandMenu = memo(CommandMenu);

  return (
    <header className="w-full grid grid-cols-header h-header px-4 fixed top-0 right-0 left-0 z-20 bg-background border-b electron-drag">
      <div className="flex items-center">
        <div className="w-8 h-8">
          <Link to="/">
            <Button
              variant="ghost"
              size="sm"
              className="h-8 w-8 p-0 rounded-md"
            >
              <HomeIcon className="w-4 h-4" strokeWidth={1.5} />
            </Button>
          </Link>
        </div>
        <div className="md:hidden flex justify-center items-center px-4 gap-2 w-full">
          <NavigationButtons />
          <MemoCommandMenu />
        </div>
      </div>
      <div className="col-span-2 flex items-center justify-center">
        <div className="hidden md:flex justify-center items-center px-4 gap-2 w-full">
          <NavigationButtons />
          <MemoCommandMenu />
        </div>
      </div>
      <div className="flex justify-end items-center gap-2">
        <SettingsButton />
        <UserDropdown />
        {isWindows && !isFullscreen && <div className="w-[122px]" />}
        {isLinux && !isFullscreen && <div className="w-[94px]" />}
      </div>
    </header>
  );
}
