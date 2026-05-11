export interface SubsonicInfo {
  url: string;
  reverseProxyEnabled: boolean;
}

export async function fetchSubsonicInfo(
  coordinationUrl: string,
): Promise<SubsonicInfo> {
  const baseUrl = coordinationUrl.replace(/\/+$/, "");
  const response = await fetch(`${baseUrl}/subsonic`);

  if (!response.ok) {
    throw new Error(
      `Failed to fetch coordination server info: HTTP ${response.status}`,
    );
  }

  const data = await response.json();

  if (typeof data.url !== "string" || typeof data.reverseProxyEnabled !== "boolean") {
    throw new Error("Invalid coordination server response format");
  }

  return {
    url: data.url,
    reverseProxyEnabled: data.reverseProxyEnabled,
  };
}