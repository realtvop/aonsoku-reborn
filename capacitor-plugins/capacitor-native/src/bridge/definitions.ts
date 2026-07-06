import type { Plugin } from "@capacitor/core";

export const NATIVE_BRIDGE_PLUGIN_NAME = "AonsokuNativeBridge";

// MARK: Credential Management

export interface StoreCredentialsOptions {
  serverUrl: string;
  username: string;
  password: string;
  authType: "token" | "password";
  protocolVersion: string;
  serverType: string;
  fallbackUrl?: string;
}

export interface StoredCredentials {
  serverUrl: string;
  username: string;
  password?: string;
  authType: "token" | "password";
  protocolVersion: string;
  serverType: string;
  fallbackUrl?: string;
}

export interface HasCredentialsResult {
  stored: boolean;
}

// MARK: Login & Server Validation

export interface LoginOptions {
  url: string;
  fallbackUrl?: string;
  username: string;
  password: string;
}

export interface LoginResult {
  success: boolean;
  authType?: "token" | "password";
  protocolVersion?: string;
  serverType?: string;
  activeUrl?: string;
  activeServerType?: "primary" | "fallback";
  password?: string;
  error?: string;
}

export interface PingOptions {
  url: string;
  username: string;
  password: string;
  authType: "token" | "password";
}

export interface PingResult {
  reachable: boolean;
  error?: "auth_failed" | "server_error" | "network_unreachable";
}

export interface ServerInfoOptions {
  url: string;
}

export interface ServerInfoResult {
  protocolVersion: string;
  protocolVersionNumber: number;
  serverType: string;
}

// MARK: API Request Proxy

export interface APIRequestOptions {
  path: string;
  method?: "GET" | "POST" | "PUT" | "DELETE";
  query?: Record<string, string | number>;
  body?: string;
}

export interface APIResponse {
  count: number;
  data: Record<string, unknown>;
}

// MARK: Material You Color Retrieval

export interface MaterialYouColors {
  colorPrimary: string;
  colorOnPrimary: string;
  colorSecondary: string;
  colorOnSecondary: string;
  colorBackground: string;
  colorOnBackground: string;
  colorSurface: string;
  colorOnSurface: string;
  colorSurfaceVariant: string;
  colorOnSurfaceVariant: string;
  colorOutline: string;
}

export interface MaterialYouColorsResult {
  supported: boolean;
  colors?: MaterialYouColors;
}

// MARK: Plugin Interface

export interface AonsokuNativeBridgePlugin extends Plugin {
  storeCredentials(options: StoreCredentialsOptions): Promise<void>;
  getCredentials(): Promise<StoredCredentials | null>;
  clearCredentials(): Promise<void>;
  hasCredentials(): Promise<HasCredentialsResult>;

  login(options: LoginOptions): Promise<LoginResult>;
  ping(options: PingOptions): Promise<PingResult>;
  queryServerInfo(options: ServerInfoOptions): Promise<ServerInfoResult>;

  request(options: APIRequestOptions): Promise<APIResponse>;
  getMaterialYouColors(options: {
    isDark: boolean;
  }): Promise<MaterialYouColorsResult>;
}
