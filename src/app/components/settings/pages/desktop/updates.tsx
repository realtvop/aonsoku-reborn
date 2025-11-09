import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  Content,
  ContentItem,
  ContentItemForm,
  ContentItemTitle,
  ContentSeparator,
  Header,
  HeaderDescription,
  HeaderTitle,
  Root,
} from "@/app/components/settings/section";
import { Button } from "@/app/components/ui/button";
import { toast } from "react-toastify";
import { isDesktop } from "@/utils/desktop";

type UpdateStatus =
  | "checking-for-update"
  | "update-available"
  | "update-not-available"
  | "error"
  | "update-download-progress"
  | "update-downloaded";

type UpdatePayload = {
  status: UpdateStatus;
  version?: string;
  releaseDate?: string;
  percent?: number;
  transferred?: number;
  total?: number;
  message?: string;
};

function UpdateSettingsContent() {
  const { t } = useTranslation();
  const [currentVersion, setCurrentVersion] = useState<string>("");
  const [isChecking, setIsChecking] = useState(false);
  const [updateStatus, setUpdateStatus] = useState<string>("");
  const [updateInfo, setUpdateInfo] = useState<{
    version?: string;
    percent?: number;
  }>({});

  useEffect(() => {
    // Get current version
    if (!window.api?.update) {
      return;
    }

    window.api.update.getVersion().then((version) => {
      setCurrentVersion(version);
    });

    // Listen for update status
    const handleUpdateStatus = (payload: UpdatePayload) => {
      setUpdateStatus(payload.status);

      switch (payload.status) {
        case "checking-for-update":
          setIsChecking(true);
          break;
        case "update-available":
          setIsChecking(false);
          setUpdateInfo({
            version: payload.version,
          });
          toast.info(
            `${t("settings.desktop.updates.updateAvailable")} - ${t(
              "settings.desktop.updates.updateAvailableDesc",
              {
                version: payload.version,
              },
            )}`,
          );
          break;
        case "update-not-available":
          setIsChecking(false);
          break;
        case "update-download-progress":
          setUpdateInfo({
            version: updateInfo.version,
            percent: payload.percent,
          });
          break;
        case "update-downloaded":
          setIsChecking(false);
          toast.success(
            `${t("settings.desktop.updates.updateReady")} - ${t("settings.desktop.updates.updateReadyDesc")}`,
          );
          break;
        case "error":
          setIsChecking(false);
          toast.error(
            `${t("settings.desktop.updates.updateError")}${payload.message ? `: ${payload.message}` : ""}`,
          );
          break;
      }
    };

    window.api.update.onUpdateStatus(handleUpdateStatus);

    return () => {
      window.api.update.removeUpdateStatusListener();
    };
  }, [t, updateInfo.version]);

  const handleCheckForUpdates = async () => {
    if (window.api?.update) {
      setIsChecking(true);
      try {
        await window.api.update.checkForUpdates();
      } catch (error) {
        console.error("Error checking for updates:", error);
        setIsChecking(false);
      }
    }
  };

  const handleDownloadUpdate = async () => {
    if (window.api?.update) {
      try {
        await window.api.update.downloadUpdate();
        toast.info(
          `${t("settings.desktop.updates.downloadStarted")} - ${t("settings.desktop.updates.downloadStartedDesc")}`,
        );
      } catch (error) {
        console.error("Error downloading update:", error);
        toast.error(
          `${t("settings.desktop.updates.downloadError")}: ${String(error)}`,
        );
      }
    }
  };

  const handleInstallUpdate = () => {
    if (window.api?.update) {
      window.api.update.installUpdate();
    }
  };

  const getStatusText = () => {
    switch (updateStatus) {
      case "checking-for-update":
        return t("settings.desktop.updates.checking");
      case "update-available":
        return t("settings.desktop.updates.availableVersion", {
          version: updateInfo.version,
        });
      case "update-download-progress":
        return t("settings.desktop.updates.downloading", {
          percent: updateInfo.percent?.toFixed(0) || 0,
        });
      case "update-downloaded":
        return t("settings.desktop.updates.readyToInstall");
      default:
        return t("settings.desktop.updates.upToDate");
    }
  };

  const getActionButton = () => {
    if (updateStatus === "update-available") {
      return (
        <Button onClick={handleDownloadUpdate} size="sm">
          {t("settings.desktop.updates.download")}
        </Button>
      );
    }
    if (updateStatus === "update-downloaded") {
      return (
        <Button onClick={handleInstallUpdate} size="sm">
          {t("settings.desktop.updates.installNow")}
        </Button>
      );
    }
    if (updateStatus === "update-download-progress") {
      return (
        <Button disabled size="sm">
          {t("settings.desktop.updates.downloading", {
            percent: updateInfo.percent?.toFixed(0) || 0,
          })}
        </Button>
      );
    }
    return (
      <Button onClick={handleCheckForUpdates} disabled={isChecking} size="sm">
        {isChecking
          ? t("settings.desktop.updates.checking")
          : t("settings.desktop.updates.checkNow.label")}
      </Button>
    );
  };

  return (
    <Root>
      <Header>
        <HeaderTitle>{t("settings.desktop.updates.group")}</HeaderTitle>
        <HeaderDescription>
          {t("settings.desktop.updates.description")}
        </HeaderDescription>
      </Header>
      <Content>
        <ContentItem>
          <ContentItemTitle
            info={t("settings.desktop.updates.currentVersion.info")}
          >
            {t("settings.desktop.updates.currentVersion.label")}
          </ContentItemTitle>
          <ContentItemForm>
            <span className="text-sm text-muted-foreground">
              v{currentVersion}
            </span>
          </ContentItemForm>
        </ContentItem>
        <ContentItem>
          <ContentItemTitle info={t("settings.desktop.updates.status.info")}>
            {t("settings.desktop.updates.status.label")}
          </ContentItemTitle>
          <ContentItemForm>
            <div className="flex items-center gap-2">
              <span className="text-sm text-muted-foreground">
                {getStatusText()}
              </span>
            </div>
          </ContentItemForm>
        </ContentItem>
        <ContentItem>
          <ContentItemTitle info={t("settings.desktop.updates.checkNow.info")}>
            {t("settings.desktop.updates.checkNow.label")}
          </ContentItemTitle>
          <ContentItemForm>{getActionButton()}</ContentItemForm>
        </ContentItem>
      </Content>
      <ContentSeparator />
    </Root>
  );
}

export function UpdateSettings() {
  if (!isDesktop()) {
    return null;
  }

  return <UpdateSettingsContent />;
}
