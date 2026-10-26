/** Stable across active primary/fallback URL switches. Never includes credentials. */
export function libraryAccountKey(config: {
  url: string;
  primaryUrl?: string;
  username: string;
}): string {
  return JSON.stringify([
    (config.primaryUrl || config.url).replace(/\/+$/, ""),
    config.username,
  ]);
}
