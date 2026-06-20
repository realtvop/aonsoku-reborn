import { Loader2, Trash2 } from "lucide-react";
import { FormEvent, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import { Button } from "@/app/components/ui/button";
import { Input } from "@/app/components/ui/input";
import { useAppData } from "@/store/app.store";
import { detectRuntime } from "@/utils/capabilities";
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
import { useCoordinationStore } from "@/coordination/store";

export function CrossDeviceSettings() {
	const { t } = useTranslation();
	const { url, username, password, authType } = useAppData();
	const coordStore = useCoordinationStore();
	const [serverUrl, setServerUrl] = useState("");
	const [identityUrl, setIdentityUrl] = useState("");
	const [deviceName, setDeviceName] = useState("");
	const [isConnecting, setIsConnecting] = useState(false);

	useEffect(() => {
		coordStore.loadState();
	}, [coordStore]);

	useEffect(() => {
		if (!identityUrl && url) {
			setIdentityUrl(url);
		}
	}, [url, identityUrl]);

	useEffect(() => {
		if (!deviceName) {
			const runtime = detectRuntime();
			const platformLabel =
				runtime === "electron"
					? "Desktop"
					: runtime === "capacitor-ios"
						? "iOS"
						: runtime === "capacitor-android"
							? "Android"
							: "Web";
			setDeviceName(`${platformLabel} — ${new Date().toLocaleDateString()}`);
		}
	}, [deviceName]);

	const handleConnect = async (e: FormEvent) => {
		e.preventDefault();
		if (!serverUrl || !identityUrl || !username || !password) {
			toast.error(t("settings.crossDevice.error.missingFields", { defaultValue: "Fill in all fields" }));
			return;
		}
		setIsConnecting(true);
		try {
			await coordStore.saveConfig({ serverUrl, identityUrl });
			const runtime = detectRuntime();
			const platform =
				runtime === "electron"
					? "electron"
					: runtime === "capacitor-ios"
						? "capacitor-ios"
						: runtime === "capacitor-android"
							? "capacitor-android"
							: "web";
			await coordStore.connect(
				{ identityUrl, username, password, authType },
				deviceName || platform,
				platform,
				"0.30.0",
			);
			toast.success(t("settings.crossDevice.connected", { defaultValue: "Connected" }));
		} catch (err) {
			toast.error(
				t("settings.crossDevice.error.connectFailed", { defaultValue: "Connection failed" }) +
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
			toast.success(t("settings.crossDevice.disconnected", { defaultValue: "Disconnected" }));
		} catch (err) {
			toast.error(String(err));
		}
	};

	const handleDeleteAccount = async () => {
		if (!window.confirm(t("settings.crossDevice.deleteConfirm", { defaultValue: "Delete all coordination data? This cannot be undone." }))) {
			return;
		}
		try {
			await coordStore.deleteAccount();
			toast.success(t("settings.crossDevice.deleted", { defaultValue: "Coordination data deleted" }));
		} catch (err) {
			toast.error(String(err));
		}
	};

	const handleRenameDevice = async (id: string, name: string) => {
		try {
			await coordStore.renameDevice(id, name);
		} catch (err) {
			toast.error(String(err));
		}
	};

	const handleRevokeDevice = async (id: string) => {
		try {
			await coordStore.revokeDevice(id);
		} catch (err) {
			toast.error(String(err));
		}
	};

	return (
		<Root>
			<Header>
				<HeaderTitle>{t("settings.crossDevice.title", { defaultValue: "Cross-Device" })}</HeaderTitle>
				<HeaderDescription>
					{t("settings.crossDevice.description", {
						defaultValue: "Sync history and continue playback across your devices.",
					})}
				</HeaderDescription>
			</Header>
			<Content>
				<ContentItem>
					<ContentItemTitle>
						{t("settings.crossDevice.serverUrl", { defaultValue: "Coordination server URL" })}
					</ContentItemTitle>
					<ContentItemForm>
						<Input
							value={serverUrl}
							onChange={(e) => setServerUrl(e.target.value)}
							placeholder="https://coord.example.com"
						/>
					</ContentItemForm>
				</ContentItem>
				<ContentItem>
					<ContentItemTitle>
						{t("settings.crossDevice.identityUrl", { defaultValue: "Identity URL" })}
					</ContentItemTitle>
					<ContentItemForm>
						<Input
							value={identityUrl}
							onChange={(e) => setIdentityUrl(e.target.value)}
							placeholder={url || "https://navidrome.example"}
						/>
					</ContentItemForm>
				</ContentItem>
				<ContentItem>
					<ContentItemTitle>
						{t("settings.crossDevice.deviceName", { defaultValue: "Device name" })}
					</ContentItemTitle>
					<ContentItemForm>
						<Input value={deviceName} onChange={(e) => setDeviceName(e.target.value)} />
					</ContentItemForm>
				</ContentItem>
				<ContentItem>
					<ContentItemForm>
						<Button onClick={handleConnect} disabled={isConnecting || coordStore.isConnected}>
							{isConnecting && <Loader2 className="w-4 h-4 animate-spin" />}
							{t("settings.crossDevice.connect", { defaultValue: "Connect" })}
						</Button>
					</ContentItemForm>
				</ContentItem>
			</Content>

			{coordStore.isConnected && (
				<>
					<ContentSeparator />
					<Header>
						<HeaderTitle>
							{t("settings.crossDevice.status", { defaultValue: "Connection status" })}
						</HeaderTitle>
					</Header>
					<Content>
						<ContentItem>
							<ContentItemTitle>
								{t("settings.crossDevice.connectionState", { defaultValue: "State" })}
							</ContentItemTitle>
							<span className="text-sm text-muted-foreground">{coordStore.connectionState}</span>
						</ContentItem>
						<ContentItem>
							<ContentItemTitle>
								{t("settings.crossDevice.lastSync", { defaultValue: "Last sync" })}
							</ContentItemTitle>
							<span className="text-sm text-muted-foreground">
								{coordStore.lastSyncAt
									? new Date(coordStore.lastSyncAt).toLocaleString()
									: t("settings.crossDevice.never", { defaultValue: "Never" })}
							</span>
						</ContentItem>
						{coordStore.error && (
							<ContentItem>
								<ContentItemTitle>
									{t("settings.crossDevice.error.label", { defaultValue: "Error" })}
								</ContentItemTitle>
								<span className="text-sm text-destructive">{coordStore.error}</span>
							</ContentItem>
						)}
						<ContentItem>
							<ContentItemForm>
								<Button variant="outline" onClick={handleDisconnect}>
									{t("settings.crossDevice.disconnect", { defaultValue: "Disconnect this device" })}
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
							{t("settings.crossDevice.devices", { defaultValue: "Bound devices" })}
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

			{coordStore.isConnected && (
				<>
					<ContentSeparator />
					<Content>
						<ContentItem>
							<ContentItemTitle>
								{t("settings.crossDevice.deleteData", {
									defaultValue: "Delete all coordination data",
								})}
							</ContentItemTitle>
							<ContentItemForm>
								<Button variant="destructive" onClick={handleDeleteAccount}>
									<Trash2 className="w-4 h-4" />
									{t("settings.crossDevice.delete", { defaultValue: "Delete" })}
								</Button>
							</ContentItemForm>
						</ContentItem>
					</Content>
				</>
			)}
		</Root>
	);
}

import type { DeviceDto } from "@/coordination/types";

function DeviceRow({
	device,
	isCurrent,
	onRename,
	onRevoke,
}: {
	device: DeviceDto;
	isCurrent: boolean;
	onRename: (id: string, name: string) => void;
	onRevoke: (id: string) => void;
}) {
	const { t } = useTranslation();
	const [editing, setEditing] = useState(false);
	const [name, setName] = useState(device.name);

	return (
		<ContentItem key={device.id}>
			<ContentItemTitle>
				{device.name}
				{isCurrent && (
					<span className="text-xs text-muted-foreground">
						{t("settings.crossDevice.current", { defaultValue: " (current)" })}
					</span>
				)}
				<span className="text-xs text-muted-foreground">{device.platform}</span>
			</ContentItemTitle>
			<ContentItemForm>
				{editing ? (
					<>
						<Input
							value={name}
							onChange={(e) => setName(e.target.value)}
							className="w-32"
						/>
						<Button
							variant="outline"
							size="sm"
							onClick={() => {
								onRename(device.id, name);
								setEditing(false);
							}}
						>
							{t("common.save", { defaultValue: "Save" })}
						</Button>
					</>
				) : (
					<>
						<Button variant="ghost" size="sm" onClick={() => setEditing(true)}>
							{t("common.rename", { defaultValue: "Rename" })}
						</Button>
						{!isCurrent && (
							<Button variant="ghost" size="sm" onClick={() => onRevoke(device.id)}>
								{t("common.revoke", { defaultValue: "Revoke" })}
							</Button>
						)}
					</>
				)}
			</ContentItemForm>
		</ContentItem>
	);
}