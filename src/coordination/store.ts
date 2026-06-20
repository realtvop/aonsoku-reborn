// Zustand store for coordination state (design §5.2, §12.1).
// Bridges the CoordinationManager with React components.

import { create } from "zustand";
import { immer } from "zustand/middleware/immer";
import { CoordinationManager } from "./manager";
import type { CoordinationCredentials } from "./httpClient";
import type { ConnectionState } from "./wsClient";
import type { DeviceDto, DeviceId } from "./types";

interface CoordinationState {
	manager: CoordinationManager;
	isConnected: boolean;
	connectionState: ConnectionState;
	devices: DeviceDto[];
	deviceId: DeviceId | null;
	lastSyncAt: number | null;
	error: string | null;

	loadState: () => Promise<void>;
	saveConfig: (config: { serverUrl: string; identityUrl: string }) => Promise<void>;
	connect: (creds: CoordinationCredentials, deviceName: string, platform: string, clientVersion: string) => Promise<void>;
	disconnectCurrentDevice: () => Promise<void>;
	deleteAccount: () => Promise<void>;
	renameDevice: (id: DeviceId, name: string) => Promise<void>;
	revokeDevice: (id: DeviceId) => Promise<void>;
	refreshDevices: () => Promise<void>;
	setError: (error: string | null) => void;
}

const callbacks = {
	onConnectionStateChange: () => {},
	onDeviceSnapshot: () => {},
	onRemoteCommand: () => {},
	onHandoffCandidate: () => {},
	onPrepareRelinquish: () => {},
	onHandoffCommitted: () => {},
	onHandoffFailed: () => {},
	onError: () => {},
};

export const useCoordinationStore = create<CoordinationState>()(
	immer((set, get) => {
		const manager = new CoordinationManager({
			...callbacks,
			onConnectionStateChange: (state) => {
				set((s) => {
					s.connectionState = state;
					s.isConnected = state === "connected";
				});
			},
			onError: (code, reason) => {
				set((s) => {
					s.error = `${code}: ${reason}`;
				});
			},
		});

		return {
			manager,
			isConnected: false,
			connectionState: "disconnected",
			devices: [],
			deviceId: null,
			lastSyncAt: null,
			error: null,

			loadState: async () => {
				await manager.loadState();
				set((s) => {
					s.deviceId = manager.getDeviceId();
				});
			},

			saveConfig: async (config) => {
				await manager.saveConfig(config);
			},

			connect: async (creds, deviceName, platform, clientVersion) => {
				set((s) => {
					s.error = null;
				});
				await manager.connect(creds, deviceName, platform, clientVersion);
				set((s) => {
					s.deviceId = manager.getDeviceId();
					s.isConnected = true;
				});
				await get().refreshDevices();
			},

			disconnectCurrentDevice: async () => {
				if (manager.getDeviceId()) {
					await manager.revokeDevice(manager.getDeviceId()!);
				}
				await manager.disconnect();
				set((s) => {
					s.isConnected = false;
					s.deviceId = null;
					s.devices = [];
				});
			},

			deleteAccount: async () => {
				await manager.deleteAccount();
				set((s) => {
					s.isConnected = false;
					s.deviceId = null;
					s.devices = [];
				});
			},

			renameDevice: async (id, name) => {
				await manager.renameDevice(id, name);
				await get().refreshDevices();
			},

			revokeDevice: async (id) => {
				await manager.revokeDevice(id);
				await get().refreshDevices();
			},

			refreshDevices: async () => {
				try {
					const devices = await manager.listDevices();
					set((s) => {
						s.devices = devices;
						s.lastSyncAt = Date.now();
					});
				} catch (err) {
					set((s) => {
						s.error = String(err);
					});
				}
			},

			setError: (error) => {
				set((s) => {
					s.error = error;
				});
			},
		};
	}),
);