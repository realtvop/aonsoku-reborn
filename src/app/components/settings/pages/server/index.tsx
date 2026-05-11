import { Loader2 } from "lucide-react";
import { FormEvent, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import { Badge } from "@/app/components/ui/badge";
import { Button } from "@/app/components/ui/button";
import { Input } from "@/app/components/ui/input";
import { queryClient } from "@/lib/queryClient";
import { useAppActions, useAppData, useAppStore } from "@/store/app.store";
import { isValidServerUrl, normalizeServerUrl } from "@/utils/serverUrl";
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
} from "../../section";

export function ServerSettings() {
  const { t } = useTranslation();
  const {
    url,
    primaryUrl,
    fallbackUrl,
    activeServerType,
    lockUser,
    connectionMode,
    coordinationUrl,
  } = useAppData();
  const { saveServerUrls } = useAppActions();
  const [primaryValue, setPrimaryValue] = useState(primaryUrl || url);
  const [fallbackValue, setFallbackValue] = useState(fallbackUrl);
  const [isSaving, setIsSaving] = useState(false);

  const inputsDisabled = lockUser || isSaving;

  const isCoordination = connectionMode === "coordination";

  useEffect(() => {
    setPrimaryValue(primaryUrl || url);
    setFallbackValue(fallbackUrl);
  }, [fallbackUrl, primaryUrl, url]);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const normalizedPrimaryUrl = normalizeServerUrl(primaryValue);
    const normalizedFallbackUrl = normalizeServerUrl(fallbackValue);

    if (!isValidServerUrl(normalizedPrimaryUrl)) {
      toast.error(t("settings.server.validation.primaryUrl"));
      return;
    }

    if (normalizedFallbackUrl && !isValidServerUrl(normalizedFallbackUrl)) {
      toast.error(t("settings.server.validation.fallbackUrl"));
      return;
    }

    setIsSaving(true);

    try {
      const saved = await saveServerUrls({
        primaryUrl: normalizedPrimaryUrl,
        fallbackUrl: normalizedFallbackUrl,
      });

      if (!saved) {
        toast.error(t("settings.server.toast.error"));
        return;
      }

      if (useAppStore.getState().data.url !== url) {
        await queryClient.resetQueries();
      }

      toast.success(t("settings.server.toast.success"));
    } finally {
      setIsSaving(false);
    }
  }

  return (
    <Root>
      <Header>
        <HeaderTitle>{t("settings.server.group")}</HeaderTitle>
        <HeaderDescription>
          {t("settings.server.description")}
        </HeaderDescription>
      </Header>

      <form onSubmit={handleSubmit}>
        <Content>
          {isCoordination && coordinationUrl && (
            <ContentItem className="items-start gap-4">
              <ContentItemTitle info={t("settings.server.coordinationUrl.info")}>
                {t("settings.server.coordinationUrl.label")}
              </ContentItemTitle>
              <ContentItemForm className="max-w-none w-3/5">
                <div className="w-full rounded-md border border-input bg-muted/40 px-3 py-2 text-sm text-muted-foreground break-all">
                  {coordinationUrl}
                </div>
                <Badge variant="default" className="mt-1">
                  {t("settings.server.connectionMode.coordination")}
                </Badge>
              </ContentItemForm>
            </ContentItem>
          )}

          {!isCoordination && (
            <ContentItem className="items-start gap-4">
              <ContentItemTitle info={t("settings.server.primaryUrl.info")}>
                {t("settings.server.primaryUrl.label")}
              </ContentItemTitle>
              <ContentItemForm className="max-w-none w-3/5">
                <Input
                  value={primaryValue}
                  onChange={(event) => setPrimaryValue(event.target.value)}
                  disabled={inputsDisabled}
                  placeholder={t("settings.server.primaryUrl.placeholder")}
                  autoCorrect="false"
                  autoCapitalize="false"
                  spellCheck="false"
                />
              </ContentItemForm>
            </ContentItem>
          )}

          <ContentItem className="items-start gap-4">
            <ContentItemTitle info={t("settings.server.fallbackUrl.info")}>
              {t("settings.server.fallbackUrl.label")}
            </ContentItemTitle>
            <ContentItemForm className="max-w-none w-3/5">
              <Input
                value={fallbackValue}
                onChange={(event) => setFallbackValue(event.target.value)}
                disabled={inputsDisabled}
                placeholder={t("settings.server.fallbackUrl.placeholder")}
                autoCorrect="false"
                autoCapitalize="false"
                spellCheck="false"
              />
            </ContentItemForm>
          </ContentItem>

          <ContentItem>
            <ContentItemTitle info={t("settings.server.activeUrl.info")}>
              {t("settings.server.activeUrl.label")}
            </ContentItemTitle>
            <ContentItemForm className="max-w-none w-3/5">
              <div className="w-full rounded-md border border-input bg-muted/40 px-3 py-2 text-sm text-muted-foreground break-all">
                {url || t("settings.server.activeUrl.empty")}
              </div>
            </ContentItemForm>
          </ContentItem>

          <ContentItem>
            <ContentItemTitle info={t("settings.server.activeType.info")}>
              {t("settings.server.activeType.label")}
            </ContentItemTitle>
            <ContentItemForm className="max-w-none w-3/5">
              <div className="w-full rounded-md border border-input bg-muted/40 px-3 py-2 text-sm text-muted-foreground">
                {activeServerType
                  ? t(`settings.server.activeType.${activeServerType}`)
                  : t("settings.server.activeType.none")}
              </div>
            </ContentItemForm>
          </ContentItem>

          {lockUser && (
            <p className="text-xs text-muted-foreground">
              {t("settings.server.locked")}
            </p>
          )}

          {!isCoordination && (
            <div className="flex justify-end pt-2">
              <Button type="submit" disabled={inputsDisabled}>
                {isSaving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                {isSaving
                  ? t("settings.server.saving")
                  : t("settings.server.save")}
              </Button>
            </div>
          )}
        </Content>
      </form>

      <ContentSeparator />
    </Root>
  );
}
