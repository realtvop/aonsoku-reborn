import {
  Check,
  CircleAlert,
  Loader2,
  Pencil,
  Plug,
  Trash2,
  Wifi,
  WifiOff,
  X,
} from "lucide-react";
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
import { Card, CardContent } from "@/app/components/ui/card";
import { ConfirmationDialog } from "@/app/components/ui/confirmation-dialog";
import { Input } from "@/app/components/ui/input";
import { SimpleTooltip } from "@/app/components/ui/simple-tooltip";
import { useCoordinationStore } from "@/coordination/store";
import type { ConnectionState } from "@/coordination/wsClient";
import type { DeviceDto, DeviceId } from "@/coordination/types";
import { cn } from "@/lib/utils";
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

function isConnectionHealthy(state: ConnectionState) {
  return state === "connected" || state === "authenticating";
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
  const [disconnectDialogOpen, setDisconnectDialogOpen] = useState(false);
  const [revokeTarget, setRevokeTarget] = useState<DeviceDto | null>(null);

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
      setDisconnectDialogOpen(false);
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
  const isConnected = Boolean(coordStore.deviceId);
  const lastSyncText = coordStore.lastSyncAt
    ? dateTime(coordStore.lastSyncAt).fromNow()
    : t("settings.crossDevice.never", { defaultValue: "Never" });
  const connectionLabel = t(
    `settings.crossDevice.connectionState.${coordStore.connectionState}`,
    { defaultValue: coordStore.connectionState },
  );

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

      <div className="mb-5 grid gap-3 sm:grid-cols-3">
        <StatusTile
          icon={
            isConnectionHealthy(coordStore.connectionState) ? Wifi : WifiOff
          }
          label={t("settings.crossDevice.connectionState.label", {
            defaultValue: "State",
          })}
          value={connectionLabel}
          badge={
            <Badge
              variant={getConnectionStateVariant(coordStore.connectionState)}
            >
              {connectionLabel}
            </Badge>
          }
        />
        <StatusTile
          icon={Plug}
          label={t("settings.crossDevice.lastSync.label", {
            defaultValue: "Last sync",
          })}
          value={lastSyncText}
        />
        <StatusTile
          icon={Check}
          label={t("settings.crossDevice.devices", {
            defaultValue: "Bound devices",
          })}
          value={t("settings.crossDevice.deviceCount", {
            defaultValue: "{{count}} devices",
            count: coordStore.devices.length,
          })}
        />
      </div>

      {!isConnected && (
        <>
          <Header className="mb-3">
            <HeaderTitle>
              {t("settings.crossDevice.setup.title", {
                defaultValue: "Connect this device",
              })}
            </HeaderTitle>
            <HeaderDescription>
              {t("settings.crossDevice.setup.description", {
                defaultValue:
                  "Use the same coordination server on every device you want to keep in sync.",
              })}
            </HeaderDescription>
          </Header>
          <form onSubmit={handleConnect}>
            <Card className="rounded-md shadow-none">
              <CardContent className="space-y-4 p-4">
                <div className="grid gap-4 sm:grid-cols-2">
                  <FieldBlock
                    label={t("settings.crossDevice.serverUrl.label", {
                      defaultValue: "Coordination server URL",
                    })}
                    description={t("settings.crossDevice.serverUrl.info", {
                      defaultValue: "URL of your coordination server.",
                    })}
                  >
                    <Input
                      value={serverUrl}
                      onChange={(event) => setServerUrl(event.target.value)}
                      placeholder="https://coord.example.com"
                      autoCorrect="false"
                      autoCapitalize="false"
                      spellCheck="false"
                    />
                  </FieldBlock>

                  <FieldBlock
                    label={t("settings.crossDevice.identityUrl.label", {
                      defaultValue: "Identity URL",
                    })}
                    description={t("settings.crossDevice.identityUrl.info", {
                      defaultValue: "Your Navidrome/Subsonic server URL.",
                    })}
                  >
                    <Input
                      value={identityUrl}
                      onChange={(event) => setIdentityUrl(event.target.value)}
                      placeholder={url || "https://navidrome.example"}
                      autoCorrect="false"
                      autoCapitalize="false"
                      spellCheck="false"
                    />
                  </FieldBlock>
                </div>

                <FieldBlock
                  label={t("settings.crossDevice.deviceName.label", {
                    defaultValue: "Device name",
                  })}
                  description={t("settings.crossDevice.deviceName.info", {
                    defaultValue: "A friendly name for this device.",
                  })}
                >
                  <Input
                    value={deviceName}
                    onChange={(event) => setDeviceName(event.target.value)}
                    placeholder={t(
                      "settings.crossDevice.deviceName.placeholder",
                      {
                        defaultValue: "My device",
                      },
                    )}
                  />
                </FieldBlock>

                <div className="flex flex-col gap-2 border-t pt-4 sm:flex-row sm:items-center sm:justify-between">
                  <p className="text-xs leading-5 text-muted-foreground">
                    {t("settings.crossDevice.setup.requirement", {
                      defaultValue:
                        "Your current music server credentials are used only to authorize this device.",
                    })}
                  </p>
                  <Button
                    type="submit"
                    disabled={connectDisabled}
                    className="sm:min-w-28"
                  >
                    {isConnecting && (
                      <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                    )}
                    {t("settings.crossDevice.connect", {
                      defaultValue: "Connect",
                    })}
                  </Button>
                </div>
              </CardContent>
            </Card>
          </form>
        </>
      )}

      {isConnected && (
        <>
          <ContentSeparator />
          <Header className="mb-3">
            <HeaderTitle>
              {t("settings.crossDevice.status", {
                defaultValue: "Connection status",
              })}
            </HeaderTitle>
          </Header>
          <Content className="rounded-md border p-4">
            <ContentItem className="min-h-0 items-start">
              <ContentItemTitle
                info={t("settings.crossDevice.statusInfo", {
                  defaultValue:
                    "This device stays available for playback handoff while connected.",
                })}
              >
                {t("settings.crossDevice.currentDevice", {
                  defaultValue: "Current device",
                })}
              </ContentItemTitle>
              <ContentItemForm className="max-w-none gap-2 sm:w-auto">
                <Badge
                  variant={getConnectionStateVariant(
                    coordStore.connectionState,
                  )}
                >
                  {connectionLabel}
                </Badge>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => setDisconnectDialogOpen(true)}
                >
                  {t("settings.crossDevice.disconnectShort", {
                    defaultValue: "Disconnect",
                  })}
                </Button>
              </ContentItemForm>
            </ContentItem>
            {coordStore.error && (
              <div className="mt-3 flex items-start gap-2 rounded-md border border-destructive/30 bg-destructive/10 p-3 text-destructive">
                <CircleAlert className="mt-0.5 h-4 w-4 shrink-0" />
                <span className="text-xs leading-5">{coordStore.error}</span>
              </div>
            )}
          </Content>
        </>
      )}

      {coordStore.devices.length > 0 && (
        <>
          <ContentSeparator />
          <Header className="mb-3 mt-5">
            <HeaderTitle>
              {t("settings.crossDevice.devices", {
                defaultValue: "Bound devices",
              })}
            </HeaderTitle>
            <HeaderDescription>
              {t("settings.crossDevice.devicesDescription", {
                defaultValue:
                  "Rename devices so they are easy to recognize, or revoke old sessions.",
              })}
            </HeaderDescription>
          </Header>
          <div className="grid gap-2">
            {coordStore.devices.map((device) => (
              <DeviceRow
                key={device.id}
                device={device}
                isCurrent={device.id === coordStore.deviceId}
                onRename={handleRenameDevice}
                onRevoke={() => setRevokeTarget(device)}
              />
            ))}
          </div>
        </>
      )}

      {isConnected && (
        <>
          <ContentSeparator />
          <Content className="rounded-md border border-destructive/25 bg-destructive/5 p-4">
            <ContentItem className="items-start">
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
              <ContentItemForm className="sm:w-auto">
                <Button
                  variant="destructive"
                  size="sm"
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

      <ConfirmationDialog
        open={disconnectDialogOpen}
        onOpenChange={setDisconnectDialogOpen}
        title={t("settings.crossDevice.disconnectConfirm.title", {
          defaultValue: "Disconnect this device?",
        })}
        description={t("settings.crossDevice.disconnectConfirm.description", {
          defaultValue: "This will stop cross-device sync on this device.",
        })}
        onConfirm={handleDisconnect}
        cancelLabel={t("generic.cancel", { defaultValue: "Cancel" })}
        confirmLabel={t("settings.crossDevice.disconnect", {
          defaultValue: "Disconnect",
        })}
      />

      <ConfirmationDialog
        open={revokeTarget !== null}
        onOpenChange={(open) => !open && setRevokeTarget(null)}
        title={t("settings.crossDevice.revokeConfirm.title", {
          defaultValue: "Revoke device?",
        })}
        description={t("settings.crossDevice.revokeConfirm.description", {
          defaultValue: `Are you sure you want to revoke access for ${revokeTarget?.name}?`,
          name: revokeTarget?.name,
        })}
        onConfirm={async () => {
          if (revokeTarget) {
            await handleRevokeDevice(revokeTarget.id);
            setRevokeTarget(null);
          }
        }}
        cancelLabel={t("generic.cancel", { defaultValue: "Cancel" })}
        confirmLabel={t("settings.crossDevice.device.revoke", {
          defaultValue: "Revoke",
        })}
      />
    </Root>
  );
}

function StatusTile({
  icon: Icon,
  label,
  value,
  badge,
}: {
  icon: typeof Wifi;
  label: string;
  value: string;
  badge?: JSX.Element;
}) {
  return (
    <div className="flex min-h-20 items-center gap-3 rounded-md border bg-card p-3">
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-md bg-muted text-muted-foreground">
        <Icon className="h-4 w-4" />
      </div>
      <div className="min-w-0 flex-1">
        <p className="text-xs leading-5 text-muted-foreground">{label}</p>
        {badge || (
          <p className="truncate text-sm font-medium leading-5 text-foreground">
            {value}
          </p>
        )}
      </div>
    </div>
  );
}

function FieldBlock({
  label,
  description,
  children,
}: {
  label: string;
  description: string;
  children: JSX.Element;
}) {
  return (
    <label className="grid gap-2">
      <span className="text-sm leading-5 text-foreground">{label}</span>
      <span className="text-xs leading-4 text-muted-foreground">
        {description}
      </span>
      {children}
    </label>
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
  const canSave = name.trim() && name.trim() !== device.name;
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
    <Card
      className={cn(
        "rounded-md shadow-none",
        isCurrent && "border-primary/45 bg-primary/5",
      )}
    >
      <CardContent className="flex flex-col gap-3 p-3 sm:flex-row sm:items-center">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="truncate text-sm font-medium leading-5 text-foreground">
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
          <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground">
            <span>{device.platform}</span>
            {lastOnlineText && (
              <>
                <span aria-hidden="true">·</span>
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

        <div className="flex items-center justify-end gap-2">
          {editing ? (
            <>
              <Input
                value={name}
                onChange={(event) => setName(event.target.value)}
                className="h-9 min-w-0 sm:w-44"
                autoFocus
              />
              <SimpleTooltip
                text={t("settings.crossDevice.device.save", {
                  defaultValue: "Save",
                })}
              >
                <Button
                  variant="outline"
                  size="icon"
                  onClick={handleSave}
                  disabled={!canSave}
                  className="h-9 w-9"
                  aria-label={t("settings.crossDevice.device.save", {
                    defaultValue: "Save",
                  })}
                >
                  <Check className="h-4 w-4" />
                </Button>
              </SimpleTooltip>
              <SimpleTooltip
                text={t("settings.crossDevice.device.cancel", {
                  defaultValue: "Cancel",
                })}
              >
                <Button
                  variant="ghost"
                  size="icon"
                  onClick={handleCancel}
                  className="h-9 w-9"
                  aria-label={t("settings.crossDevice.device.cancel", {
                    defaultValue: "Cancel",
                  })}
                >
                  <X className="h-4 w-4" />
                </Button>
              </SimpleTooltip>
            </>
          ) : (
            <>
              <SimpleTooltip
                text={t("settings.crossDevice.device.rename", {
                  defaultValue: "Rename",
                })}
              >
                <Button
                  variant="ghost"
                  size="icon"
                  onClick={() => setEditing(true)}
                  className="h-9 w-9"
                  aria-label={t("settings.crossDevice.device.rename", {
                    defaultValue: "Rename",
                  })}
                >
                  <Pencil className="h-4 w-4" />
                </Button>
              </SimpleTooltip>
              {!isCurrent && (
                <SimpleTooltip
                  text={t("settings.crossDevice.device.revoke", {
                    defaultValue: "Revoke",
                  })}
                >
                  <Button
                    variant="ghost"
                    size="icon"
                    onClick={() => onRevoke(device.id)}
                    className="h-9 w-9 text-destructive hover-supported:bg-destructive/10 hover-supported:text-destructive"
                    aria-label={t("settings.crossDevice.device.revoke", {
                      defaultValue: "Revoke",
                    })}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </SimpleTooltip>
              )}
            </>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
