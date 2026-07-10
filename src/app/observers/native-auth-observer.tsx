import { useEffect } from "react";
import {
  getNativeBridge,
  isNativeBridgeAvailable,
} from "@/native/bridge/facade";
import { useAppStore } from "@/store/app.store";
import { AuthType } from "@/types/serverConfig";
import { logger } from "@/utils/logger";

function nativeAuthType(authType: AuthType | null): "token" | "password" {
  return authType === AuthType.TOKEN ? "token" : "password";
}

export function NativeAuthObserver() {
  useEffect(() => {
    if (!isNativeBridgeAvailable()) return;

    const nativeBridge = getNativeBridge();
    nativeBridge
      .getCredentials()
      .then(async (credentials) => {
        if (!credentials || !credentials.serverUrl) {
          const data = useAppStore.getState().data;
          if (
            !data.isServerConfigured ||
            !data.url ||
            !data.username ||
            !data.password ||
            data.authType === null
          ) {
            return;
          }

          await nativeBridge.storeCredentials({
            serverUrl: data.url,
            username: data.username,
            password: data.password,
            authType: nativeAuthType(data.authType),
            protocolVersion: data.protocolVersion || "1.16.0",
            serverType: data.serverType || "subsonic",
            fallbackUrl: data.fallbackUrl || undefined,
          });
          return;
        }

        useAppStore.setState((state) => {
          state.data.url = credentials.serverUrl;
          state.data.primaryUrl = credentials.serverUrl;
          state.data.fallbackUrl = credentials.fallbackUrl ?? "";
          state.data.activeServerType = "primary";
          state.data.username = credentials.username;
          state.data.password = credentials.password ?? "";
          state.data.authType =
            credentials.authType === "token"
              ? AuthType.TOKEN
              : AuthType.PASSWORD;
          state.data.protocolVersion = credentials.protocolVersion;
          state.data.serverType = credentials.serverType;
          state.data.isServerConfigured = true;
        });
      })
      .catch((error) => {
        logger.error("[NativeAuthObserver] credential sync failed", error);
      });
  }, []);

  return null;
}
