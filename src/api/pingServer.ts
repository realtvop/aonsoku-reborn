import { getNativeBridgeAvailability } from "@/native/bridge/facade";
import { AuthType } from "@/types/serverConfig";
import { appName } from "@/utils/appName";
import { authQueryParams } from "./auth";

export type PingServerStatus =
  | "ok"
  | "auth_failed"
  | "network_unreachable"
  | "server_error";

export interface PingServerResult {
  status: PingServerStatus;
  protocolVersion?: string;
}

async function pingServerDetailed(
  url: string,
  user: string,
  password: string,
  authType: AuthType,
  protocolVersion?: string,
): Promise<PingServerResult> {
  const nativeBridge = getNativeBridgeAvailability();
  if (nativeBridge.available) {
    const result = await nativeBridge.plugin.ping({
      url,
      username: user,
      password,
      authType: authType === AuthType.TOKEN ? "token" : "password",
    });
    return result.reachable
      ? { status: "ok", protocolVersion }
      : { status: result.error ?? "server_error" };
  }

  const query = {
    ...authQueryParams(user, password, authType),
    v: protocolVersion || "1.16.0",
    c: appName,
    f: "json",
  };

  const queries = new URLSearchParams(query).toString();

  try {
    const response = await fetch(`${url}/rest/ping.view?${queries}`, {
      method: "GET",
    });

    if (!response.ok) {
      if (response.status === 401 || response.status === 403) {
        return { status: "auth_failed" };
      }

      return { status: "server_error" };
    }

    const data = await response.json();
    const subsonicResponse = data["subsonic-response"] as
      | {
          status?: string;
          version?: string;
          error?: {
            code?: number;
          };
        }
      | undefined;

    if (!subsonicResponse) {
      return { status: "server_error" };
    }

    const errorCode = subsonicResponse.error?.code;

    if (
      subsonicResponse.status === "failed" &&
      errorCode === 30 &&
      !protocolVersion
    ) {
      return pingServerDetailed(
        url,
        user,
        password,
        authType,
        subsonicResponse.version,
      );
    }

    if (subsonicResponse.status === "ok") {
      return {
        status: "ok",
        protocolVersion: protocolVersion || subsonicResponse.version,
      };
    }

    if (errorCode === 40 || errorCode === 41) {
      return { status: "auth_failed" };
    }

    return { status: "server_error" };
  } catch (_) {
    return { status: "network_unreachable" };
  }
}

export async function pingServer(
  url: string,
  user: string,
  password: string,
  authType: AuthType,
  protocolVersion?: string,
): Promise<boolean> {
  const result = await pingServerDetailed(
    url,
    user,
    password,
    authType,
    protocolVersion,
  );

  return result.status === "ok";
}

export async function probeServerConnection(
  url: string,
  user: string,
  password: string,
  authType: AuthType,
): Promise<PingServerResult> {
  return pingServerDetailed(url, user, password, authType);
}
