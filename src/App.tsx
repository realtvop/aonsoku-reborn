import { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { RouterProvider } from "react-router-dom";
import { toast } from "react-toastify";
import { Linux } from "@/app/components/controls/linux";
import { SettingsDialog } from "@/app/components/settings/dialog";
import { LanControlObserver } from "@/app/observers/lan-control-observer";
import { LangObserver } from "@/app/observers/lang-observer";
import { MediaSessionObserver } from "@/app/observers/media-session-observer";
import { ThemeObserver } from "@/app/observers/theme-observer";
import { ToastContainer } from "@/app/observers/toast-container";
import { router } from "@/routes/router";
import {
  tryAutoConnect,
  useLanControlClientStore,
} from "@/store/lanControlClient.store";
import { isLinux } from "@/utils/desktop";

function App() {
  const { t } = useTranslation();
  const status = useLanControlClientStore((state) => state.status);

  // Try to auto-connect on mount
  useEffect(() => {
    tryAutoConnect();
  }, []);

  // Show toast when auto-connect fails
  useEffect(() => {
    const checkAutoConnectFailed = setTimeout(() => {
      if (status === "error") {
        toast.info(t("lanControl.remote.autoConnectFailed"), {
          autoClose: 5000,
        });
      }
    }, 2000);

    return () => clearTimeout(checkAutoConnectFailed);
  }, [status, t]);

  // if (!isDesktop && window.innerHeight > window.innerWidth) return <Mobile />; // Support tablets but not phones

  return (
    <>
      <MediaSessionObserver />
      <LangObserver />
      <ThemeObserver />
      <LanControlObserver />
      <SettingsDialog />
      <RouterProvider router={router} />
      <ToastContainer />
      {isLinux && <Linux />}
    </>
  );
}

export default App;
