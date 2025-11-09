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

function UpdateSettingsContent() {
  const { t } = useTranslation();
  const [currentVersion, setCurrentVersion] = useState<string>("");
  const [isChecking, setIsChecking] = useState(false);

  useEffect(() => {
    // Get current version
    if (!window.api?.update) {
      return;
    }

    window.api.update.getVersion().then((version) => {
      setCurrentVersion(version);
    });
  }, []);

  const handleCheckForUpdates = async () => {
    if (window.api?.update) {
      setIsChecking(true);
      try {
        await window.api.update.checkForUpdates();
        toast.info(t("settings.desktop.updates.checkingManually"));
      } catch (error) {
        console.error("Error checking for updates:", error);
        toast.error(`${t("settings.desktop.updates.updateError")}`);
      } finally {
        setIsChecking(false);
      }
    }
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
          <ContentItemTitle info={t("settings.desktop.updates.checkNow.info")}>
            {t("settings.desktop.updates.checkNow.label")}
          </ContentItemTitle>
          <ContentItemForm>
            <Button
              onClick={handleCheckForUpdates}
              disabled={isChecking}
              size="sm"
            >
              {isChecking
                ? t("settings.desktop.updates.checking")
                : t("settings.desktop.updates.checkNow.label")}
            </Button>
          </ContentItemForm>
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
