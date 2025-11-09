import { Copy, RefreshCw } from "lucide-react";
import { useEffect } from "react";
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
import { Badge } from "@/app/components/ui/badge";
import { Button } from "@/app/components/ui/button";
import { Input } from "@/app/components/ui/input";
import { Switch } from "@/app/components/ui/switch";
import { toast } from "react-toastify";
import {
  useLanControlActions,
  useLanControlConfig,
  useLanControlServerInfo,
} from "@/store/lanControl.store";
import { isDesktop } from "@/utils/desktop";

export function LanControlSettings() {
  const { t } = useTranslation();
  const config = useLanControlConfig();
  const serverInfo = useLanControlServerInfo();
  const actions = useLanControlActions();

  useEffect(() => {
    if (!isDesktop()) return;

    // Get initial server info
    window.api.lanControl.getInfo().then((info) => {
      actions.setServerInfo(info);
    });
  }, [actions.setServerInfo]);

  const handleToggle = (checked: boolean) => {
    actions.setEnabled(checked);
  };

  const handlePortChange = (value: string) => {
    const port = Number.parseInt(value, 10);
    if (port && port > 0 && port <= 65535) {
      actions.setPort(port);
    }
  };

  const handlePasswordChange = (value: string) => {
    // Only allow alphanumeric characters, max 6 characters
    const cleaned = value
      .replace(/[^a-zA-Z0-9]/g, "")
      .slice(0, 6)
      .toUpperCase();
    actions.setPassword(cleaned);
  };

  const handleRegeneratePassword = () => {
    const newPassword = actions.generateRandomPassword();
    toast.success(t("settings.desktop.lanControl.passwordRegenerated"));
    return newPassword;
  };

  const handleCopyAddress = (address: string) => {
    navigator.clipboard.writeText(address);
    toast.success(t("settings.desktop.lanControl.addressCopied"));
  };

  const handleCopyPassword = () => {
    navigator.clipboard.writeText(config.password);
    toast.success(t("settings.desktop.lanControl.passwordCopied"));
  };

  if (!isDesktop()) {
    return null;
  }

  return (
    <Root>
      <Header>
        <HeaderTitle>{t("settings.desktop.lanControl.group")}</HeaderTitle>
        <HeaderDescription>
          {t("settings.desktop.lanControl.description")}
        </HeaderDescription>
      </Header>
      <Content>
        <ContentItem>
          <ContentItemTitle info={t("settings.desktop.lanControl.enable.info")}>
            {t("settings.desktop.lanControl.enable.label")}
          </ContentItemTitle>
          <ContentItemForm>
            <Switch checked={config.enabled} onCheckedChange={handleToggle} />
          </ContentItemForm>
        </ContentItem>

        {config.enabled && (
          <>
            <ContentItem>
              <ContentItemTitle
                info={t("settings.desktop.lanControl.port.info")}
              >
                {t("settings.desktop.lanControl.port.label")}
              </ContentItemTitle>
              <ContentItemForm>
                <Input
                  type="number"
                  min={1}
                  max={65535}
                  value={config.port}
                  onChange={(e) => handlePortChange(e.target.value)}
                  className="w-32"
                />
              </ContentItemForm>
            </ContentItem>

            <ContentItem>
              <ContentItemTitle
                info={t("settings.desktop.lanControl.password.info")}
              >
                {t("settings.desktop.lanControl.password.label")}
              </ContentItemTitle>
              <ContentItemForm>
                <div className="flex items-center gap-2">
                  <Input
                    type="text"
                    value={config.password}
                    onChange={(e) => handlePasswordChange(e.target.value)}
                    className="w-32 font-mono"
                    maxLength={6}
                  />
                  <Button
                    variant="outline"
                    size="icon"
                    onClick={handleCopyPassword}
                    title={t("settings.desktop.lanControl.copyPassword")}
                  >
                    <Copy className="size-4" />
                  </Button>
                  <Button
                    variant="outline"
                    size="icon"
                    onClick={handleRegeneratePassword}
                    title={t("settings.desktop.lanControl.regeneratePassword")}
                  >
                    <RefreshCw className="size-4" />
                  </Button>
                </div>
              </ContentItemForm>
            </ContentItem>

            <ContentItem>
              <ContentItemTitle
                info={t("settings.desktop.lanControl.allowNavidromeAuth.info")}
              >
                {t("settings.desktop.lanControl.allowNavidromeAuth.label")}
              </ContentItemTitle>
              <ContentItemForm>
                <Switch
                  checked={config.allowNavidromeAuth}
                  onCheckedChange={actions.setAllowNavidromeAuth}
                />
              </ContentItemForm>
            </ContentItem>

            {serverInfo.running &&
              serverInfo.addresses &&
              serverInfo.addresses.length > 0 && (
                <ContentItem>
                  <ContentItemTitle
                    info={t("settings.desktop.lanControl.address.info")}
                  >
                    {t("settings.desktop.lanControl.address.label")}
                  </ContentItemTitle>
                  <ContentItemForm>
                    <div className="flex flex-wrap gap-2">
                      {serverInfo.addresses.map((address, index) => (
                        <div key={index} className="flex items-center gap-1">
                          <Badge
                            variant="secondary"
                            className="font-mono text-sm"
                          >
                            {address}
                          </Badge>
                          <Button
                            variant="outline"
                            size="icon"
                            onClick={() => handleCopyAddress(address)}
                            title={t("settings.desktop.lanControl.copyAddress")}
                          >
                            <Copy className="size-4" />
                          </Button>
                        </div>
                      ))}
                    </div>
                  </ContentItemForm>
                </ContentItem>
              )}
          </>
        )}
      </Content>
      <ContentSeparator />
    </Root>
  );
}
