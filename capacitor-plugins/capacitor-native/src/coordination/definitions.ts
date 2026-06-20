import type { Plugin } from "@capacitor/core";

export const COORDINATION_PLUGIN_NAME = "AonsokuNativeCoordination";

// MARK: Coordination Connection

export interface CoordinationConnectOptions {
	/** WebSocket URL of the coordination server, e.g. wss://coord.example/v1/realtime */
	wsUrl: string;
	/** One-time WebSocket ticket from the HTTP API. */
	ticket: string;
	/** Device ID assigned by the coordination server. */
	deviceId: string;
	/** Capability bitmask (HISTORY=1, OBSERVE=2, CONTROL=4, HANDOFF=8). */
	capabilities: number;
	/** Protocol version (currently 1). */
	protocolVersion: number;
}

export interface CoordinationStateResult {
	state: "disconnected" | "connecting" | "connected" | "reconnecting" | "error";
	deviceId: string | null;
}

export interface CoordinationSnapshotOptions {
	sessionId: string;
	generation: number;
	snapshotRevision: number;
	/** JSON-serialized PlaybackSnapshot. */
	snapshotJson: string;
}

export interface CoordinationCommandOptions {
	targetDeviceId: string;
	expectedGeneration: number;
	/** JSON-serialized RemoteCommand. */
	commandJson: string;
}

export interface CoordinationHandoffOptions {
	transactionId: string;
	/** JSON-serialized PlaybackSnapshot for relinquish_ack. */
	snapshotJson: string;
}

export interface CoordinationTokenOptions {
	accessToken: string;
	refreshToken: string;
	deviceId: string;
	accountId: string;
	historyLimit: number;
}

export interface CoordinationConfigOptions {
	serverUrl: string;
	identityUrl: string;
}

/// Native coordination plugin — maintains a WebSocket connection in the
/// background on iOS/Android, bridging remote commands and handoff events to
/// the native queue controller and playback backend (design §8, §9, §10, §11).
///
/// Multi-stack consistency: the native plugin receives the same RemoteCommand
/// types as the Web/Electron observer and dispatches them to the native
/// queue controller (NativeQueueController) via the same playback-actions
/// branch. The WebView-side CoordinationManager delegates to this plugin when
/// `isNativeBridgeAvailable()` returns true.
export interface AonsokuNativeCoordinationPlugin extends Plugin {
	/// Store coordination tokens in Keychain/Keystore (design §6.3).
	storeTokens(options: CoordinationTokenOptions): Promise<void>;

	/// Load coordination tokens from Keychain/Keystore.
	loadTokens(): Promise<CoordinationTokenOptions | null>;

	/// Clear stored coordination tokens.
	clearTokens(): Promise<void>;

	/// Store coordination server/identity config.
	storeConfig(options: CoordinationConfigOptions): Promise<void>;

	/// Load coordination config.
	loadConfig(): Promise<CoordinationConfigOptions | null>;

	/// Open a background WebSocket connection to the coordination server.
	connect(options: CoordinationConnectOptions): Promise<void>;

	/// Disconnect and stop background reconnection.
	disconnect(): Promise<void>;

	/// Get the current connection state.
	getState(): Promise<CoordinationStateResult>;

	/// Publish a playback snapshot to the server (design §9.2).
	publishSnapshot(options: CoordinationSnapshotOptions): Promise<void>;

	/// Send a remote control command to a target device (design §10).
	sendCommand(options: CoordinationCommandOptions): Promise<void>;

	/// Request a handoff candidate from a source device (design §11.1 step 1).
	requestHandoffCandidate(
		sourceDeviceId: string,
		expectedGeneration: number,
		expectedSnapshotRevision: number,
	): Promise<void>;

	/// Signal target_ready (design §11.1 step 3).
	sendTargetReady(
		transactionId: string,
		generation: number,
		snapshotRevision: number,
	): Promise<void>;

	/// Send relinquish_ack with final snapshot (design §11.1 step 5).
	sendRelinquishAck(options: CoordinationHandoffOptions): Promise<void>;

	/// Add a listener for incoming coordination events (snapshot projections,
	/// commands, handoff events). The event payload is a JSON-serialized
	/// Envelope in the `coordinationEvent` event.
	addListener(
		eventName: "coordinationEvent",
		listenerFunc: (data: { envelopeJson: string }) => void,
	): Promise<PluginListenerHandle>;

	/// Add a listener for connection state changes.
	addListener(
		eventName: "coordinationStateChange",
		listenerFunc: (data: CoordinationStateResult) => void,
	): Promise<PluginListenerHandle>;
}

/// Re-exported from @capacitor/core for the listener handle type.
import type { PluginListenerHandle } from "@capacitor/core";