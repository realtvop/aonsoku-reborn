import { Loader2, Pencil, Trash2, X } from "lucide-react";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
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
import { Badge } from "@/app/components/ui/badge";
import { Button } from "@/app/components/ui/button";
import { ConfirmationDialog } from "@/app/components/ui/confirmation-dialog";
import { Input } from "@/app/components/ui/input";
import { useCoordinationStore } from "@/coordination/store";
import type { ConnectionState } from "@/coordination/wsClient";
import type { DeviceDto, DeviceId } from "@/coordination/types";
import { useAppData } from "@/store/app.store";
import { usePlayerStore } from "@/store/player.store";
import { detectRuntime } from "@/utils/capabilities";
import dateTime from "@/utils/dateTime";

const DEFAULT_CLIENT_VERSION = "0.30.0";

type Runtime = ReturnType<typeof detectRuntime>;

function getPlatformLabel(runtime: Runtime) {
  switch (runtime) {
    case "electron":
      return "Desktop";
    case "capacitor-ios":
      return "iOS";
    case "capacitor-android":
      return "Android";
    default:
      return "Web";
  }
}

function getPlatformId(runtime: Runtime) {
  switch (runtime) {
    case "electron":
      return "electron";
    case "capacitor-ios":
      return "capacitor-ios";
    case "capacitor-android":
      return "capacitor-android";
    default:
      return "web";
  }
}

function getConnectionStateVariant(state: ConnectionState) {
  switch (state) {
    case "connected":
      return "default";
    case "connecting":
    case "authenticating":
      return "secondary";
    case "error":
      return "destructive";
    default:
      return "outline";
  }
}

export function CrossDeviceSettings() {
  const { t } = useTranslation();
  const { url, username, password, authType } = useAppData();
  const coordStore = useCoordinationStore();
  const [serverUrl, setServerUrl] = useState("");
  const [identityUrl, setIdentityUrl] = useState("");
  const [deviceName, setDeviceName] = useState("");
  const [isConnecting, setIsConnecting] = useState(false);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);

  useEffect(() => {
    const config = coordStore.manager.getConfig();
    if (config) {
      if (!serverUrl) setServerUrl(config.serverUrl);
      if (!identityUrl) setIdentityUrl(config.identityUrl);
    } else if (!identityUrl && url) {
      setIdentityUrl(url);
    }
  }, [coordStore.manager, url, serverUrl, identityUrl]);

  useEffect(() => {
    if (!deviceName) {
      const runtime = detectRuntime();
      const platformLabel = getPlatformLabel(runtime);
      setDeviceName(`${platformLabel} — ${new Date().toLocaleDateString()}`);
    }
  }, [deviceName]);

  const handleConnect = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!serverUrl || !identityUrl || !username || !password) {
      toast.error(
        t("settings.crossDevice.error.missingFields", {
          defaultValue: "Fill in all fields",
        }),
      );
      return;
    }
    setIsConnecting(true);
    try {
      await coordStore.saveConfig({ serverUrl, identityUrl });
      const runtime = detectRuntime();
      const platform = getPlatformId(runtime);
      await coordStore.connect(
        { identityUrl, username, password, authType },
        deviceName || platform,
        platform,
        DEFAULT_CLIENT_VERSION,
      );
      toast.success(
        t("settings.crossDevice.connected", { defaultValue: "Connected" }),
      );
    } catch (err) {
      toast.error(
        t("settings.crossDevice.error.connectFailed", {
          defaultValue: "Connection failed",
        }) +
          ": " +
          (err instanceof Error ? err.message : String(err)),
      );
    } finally {
      setIsConnecting(false);
    }
  };

  const handleDisconnect = async () => {
    try {
      await coordStore.disconnectCurrentDevice();
      usePlayerStore.setState({
        remoteControl: {
          active: false,
          device: null,
          sendCommand: null,
        },
      });
      usePlayerStore.getState().actions.setPlayingState(false);
      toast.success(
        t("settings.crossDevice.disconnected", {
          defaultValue: "Disconnected",
        }),
      );
    } catch (err) {
      toast.error(String(err));
    }
  };

  const handleDeleteAccount = async () => {
    try {
      await coordStore.deleteAccount();
      setDeleteDialogOpen(false);
      toast.success(
        t("settings.crossDevice.deleted", {
          defaultValue: "Coordination data deleted",
        }),
      );
    } catch (err) {
      toast.error(String(err));
    }
  };

  const handleRenameDevice = async (id: DeviceId, name: string) => {
    try {
      await coordStore.renameDevice(id, name);
      toast.success(t("settings.crossDevice.device.renamed"));
    } catch (err) {
      toast.error(String(err));
    }
  };

  const handleRevokeDevice = async (id: DeviceId) => {
    try {
      await coordStore.revokeDevice(id);
      toast.success(t("settings.crossDevice.device.revoked"));
    } catch (err) {
      toast.error(String(err));
    }
  };

  const connectDisabled =
    !serverUrl || !identityUrl || !username || !password || isConnecting;

  return (
    <Root>
      <Header>
        <HeaderTitle>
          {t("settings.crossDevice.title", { defaultValue: "Cross-Device" })}
        </HeaderTitle>
        <HeaderDescription>
          {t("settings.crossDevice.description", {
            defaultValue:
              "Sync history and continue playback across your devices.",
          })}
        </HeaderDescription>
      </Header>

      {!coordStore.deviceId && (
        <form onSubmit={handleConnect}>
          <Content>
            <ContentItem className="items-start gap-4">
              <ContentItemTitle
                info={t("settings.crossDevice.serverUrl.info", {
                  defaultValue: "URL of your coordination server.",
                })}
              >
                {t("settings.crossDevice.serverUrl.label", {
                  defaultValue: "Coordination server URL",
                })}
              </ContentItemTitle>
              <ContentItemForm className="max-w-none w-3/5">
                <Input
                  value={serverUrl}
                  onChange={(event) => setServerUrl(event.target.value)}
                  placeholder="https://coord.example.com"
                  autoCorrect="false"
                  autoCapitalize="false"
                  spellCheck="false"
                />
              </ContentItemForm>
            </ContentItem>

            <ContentItem className="items-start gap-4">
              <ContentItemTitle
                info={t("settings.crossDevice.identityUrl.info", {
                  defaultValue: "Your Navidrome/Subsonic server URL.",
                })}
              >
                {t("settings.crossDevice.identityUrl.label", {
                  defaultValue: "Identity URL",
                })}
              </ContentItemTitle>
              <ContentItemForm className="max-w-none w-3/5">
                <Input
                  value={identityUrl}
                  onChange={(event) => setIdentityUrl(event.target.value)}
                  placeholder={url || "https://navidrome.example"}
                  autoCorrect="false"
                  autoCapitalize="false"
                  spellCheck="false"
                />
              </ContentItemForm>
            </ContentItem>

            <ContentItem className="items-start gap-4">
              <ContentItemTitle
                info={t("settings.crossDevice.deviceName.info", {
                  defaultValue: "A friendly name for this device.",
                })}
              >
                {t("settings.crossDevice.deviceName.label", {
                  defaultValue: "Device name",
                })}
              </ContentItemTitle>
              <ContentItemForm className="max-w-none w-3/5">
                <Input
                  value={deviceName}
                  onChange={(event) => setDeviceName(event.target.value)}
                  placeholder={t("settings.crossDevice.deviceName.placeholder", {
                    defaultValue: "My device",
                  })}
                />
              </ContentItemForm>
            </ContentItem>

            <div className="flex justify-end pt-2">
              <Button type="submit" disabled={connectDisabled}>
                {isConnecting && (
                  <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                )}
                {t("settings.crossDevice.connect", {
                  defaultValue: "Connect",
                })}
              </Button>
            </div>
          </Content>
        </form>
      )}

      {coordStore.deviceId && (
        <>
          <ContentSeparator />
          <Header>
            <HeaderTitle>
              {t("settings.crossDevice.status", {
                defaultValue: "Connection status",
              })}
            </HeaderTitle>
          </Header>
          <Content>
            <ContentItem>
              <ContentItemTitle>
                {t("settings.crossDevice.connectionState.label", {
                  defaultValue: "State",
                })}
              </ContentItemTitle>
              <Badge
                variant={getConnectionStateVariant(coordStore.connectionState)}
              >
                {t(
                  `settings.crossDevice.connectionState.${coordStore.connectionState}`,
                  { defaultValue: coordStore.connectionState },
                )}
              </Badge>
            </ContentItem>
            <ContentItem>
              <ContentItemTitle>
                {t("settings.crossDevice.lastSync.label", {
                  defaultValue: "Last sync",
                })}
              </ContentItemTitle>
              <span className="text-sm text-muted-foreground">
                {coordStore.lastSyncAt
                  ? dateTime(coordStore.lastSyncAt).fromNow()
                  : t("settings.crossDevice.never", { defaultValue: "Never" })}
              </span>
            </ContentItem>
            {coordStore.error && (
              <ContentItem>
                <ContentItemTitle>
                  {t("settings.crossDevice.error.label", {
                    defaultValue: "Error",
                  })}
                </ContentItemTitle>
                <span className="text-sm text-destructive">
                  {coordStore.error}
                </span>
              </ContentItem>
            )}
            <ContentItem>
              <ContentItemForm>
                <Button variant="outline" onClick={handleDisconnect}>
                  {t("settings.crossDevice.disconnect", {
                    defaultValue: "Disconnect this device",
                  })}
                </Button>
              </ContentItemForm>
            </ContentItem>
          </Content>
        </>
      )}

      {coordStore.devices.length > 0 && (
        <>
          <ContentSeparator />
          <Header>
            <HeaderTitle>
              {t("settings.crossDevice.devices", {
                defaultValue: "Bound devices",
              })}
            </HeaderTitle>
          </Header>
          <Content>
            {coordStore.devices.map((device) => (
              <DeviceRow
                key={device.id}
                device={device}
                isCurrent={device.id === coordStore.deviceId}
                onRename={handleRenameDevice}
                onRevoke={handleRevokeDevice}
              />
            ))}
          </Content>
        </>
      )}

      {coordStore.deviceId && (
        <>
          <ContentSeparator />
          <Content>
            <ContentItem>
              <ContentItemTitle
                info={t("settings.crossDevice.deleteData.info", {
                  defaultValue:
                    "Remove your account and all synced data from the coordination server.",
                })}
              >
                {t("settings.crossDevice.deleteData.label", {
                  defaultValue: "Delete all coordination data",
                })}
              </ContentItemTitle>
              <ContentItemForm>
                <Button
                  variant="destructive"
                  onClick={() => setDeleteDialogOpen(true)}
                >
                  <Trash2 className="mr-2 h-4 w-4" />
                  {t("settings.crossDevice.delete", {
                    defaultValue: "Delete",
                  })}
                </Button>
              </ContentItemForm>
            </ContentItem>
          </Content>
        </>
      )}

      <ConfirmationDialog
        open={deleteDialogOpen}
        onOpenChange={setDeleteDialogOpen}
        title={t("settings.crossDevice.deleteConfirm.title", {
          defaultValue: "Delete all coordination data?",
        })}
        description={t("settings.crossDevice.deleteConfirm.description", {
          defaultValue: "This action cannot be undone.",
        })}
        onConfirm={handleDeleteAccount}
        cancelLabel={t("generic.cancel", { defaultValue: "Cancel" })}
        confirmLabel={t("settings.crossDevice.delete", {
          defaultValue: "Delete",
        })}
      />
    </Root>
  );
}

function DeviceRow({
  device,
  isCurrent,
  onRename,
  onRevoke,
}: {
  device: DeviceDto;
  isCurrent: boolean;
  onRename: (id: DeviceId, name: string) => void;
  onRevoke: (id: DeviceId) => void;
}) {
  const { t } = useTranslation();
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(device.name);
  const lastOnlineText = useMemo(() => {
    if (!device.lastOnlineAt) return null;
    return dateTime(device.lastOnlineAt).fromNow();
  }, [device.lastOnlineAt]);

  const handleSave = () => {
    if (name.trim()) {
      onRename(device.id, name.trim());
    }
    setEditing(false);
  };

  const handleCancel = () => {
    setName(device.name);
    setEditing(false);
  };

  return (
    <ContentItem className="flex-col items-start gap-2 sm:flex-row sm:items-center">
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-sm leading-5 text-foreground">
            {device.name}
          </span>
          {isCurrent && (
            <Badge variant="secondary">
              {t("settings.crossDevice.device.current", {
                defaultValue: "Current",
              })}
            </Badge>
          )}
        </div>
        <div className="flex items-center gap-2 text-xs text-muted-foreground">
          <span>{device.platform}</span>
          {lastOnlineText && (
            <>
              <span>·</span>
              <span>
                {t("settings.crossDevice.device.lastOnline", {
                  defaultValue: "Last online {{time}}",
                  time: lastOnlineText,
                })}
              </span>
            </>
          )}
        </div>
      </div>

      <ContentItemForm>
        {editing ? (
          <>
            <Input
              value={name}
              onChange={(event) => setName(event.target.value)}
              className="w-40"
              autoFocus
            />
            <Button
              variant="outline"
              size="icon"
              onClick={handleSave}
              title={t("settings.crossDevice.device.save", {
                defaultValue: "Save",
              })}
            >
              <Pencil className="h-4 w-4" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              onClick={handleCancel}
              title={t("settings.crossDevice.device.cancel", {
                defaultValue: "Cancel",
              })}
            >
              <X className="h-4 w-4" />
            </Button>
          </>
        ) : (
          <>
            <Button variant="ghost" size="sm" onClick={() => setEditing(true)}>
              {t("settings.crossDevice.device.rename", {
                defaultValue: "Rename",
              })}
            </Button>
            {!isCurrent && (
              <Button
                variant="ghost"
                size="sm"
                onClick={() => onRevoke(device.id)}
              >
                {t("settings.crossDevice.device.revoke", {
                  defaultValue: "Revoke",
                })}
              </Button>
            )}
          </>
        )}
      </ContentItemForm>
    </ContentItem>
  );
}
