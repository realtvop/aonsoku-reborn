import { useQuery, useQueryClient } from "@tanstack/react-query";
import { get, set } from "idb-keyval";
import { useAppStore } from "@/store/app.store";
import { offlineLibraryStore } from "@/store/idb";

/** Restore Home query results across reloads without mixing server/accounts. */
export function useCachedHomeQuery<T>({
  key,
  isOnline,
  local,
  fresh,
  hasContent,
  enabled = true,
  refetchInterval,
}: {
  key: readonly unknown[];
  isOnline: boolean;
  local: () => Promise<T>;
  fresh: () => Promise<T>;
  hasContent: (value: T) => boolean;
  enabled?: boolean;
  refetchInterval?: number | false;
}) {
  const account = useAppStore((state) =>
    JSON.stringify([
      (state.data.primaryUrl || state.data.url).replace(/\/+$/, ""),
      state.data.username,
    ]),
  );
  const client = useQueryClient();
  const queryKey = [...key, account, isOnline ? "online" : "offline"];
  const storageKey = JSON.stringify(["home.snapshot.v1", account, key]);

  return useQuery<T>({
    queryKey,
    queryFn: async ({ signal }) => {
      let cached = client.getQueryData<T>(queryKey);
      if (cached === undefined) {
        cached = await get<T>(storageKey, offlineLibraryStore).catch(
          () => undefined,
        );
      }
      if (cached === undefined) {
        const seed = await local().catch(() => undefined);
        if (seed !== undefined && hasContent(seed)) cached = seed;
      }
      signal.throwIfAborted();
      if (cached !== undefined) client.setQueryData(queryKey, cached);
      if (!isOnline) return cached ?? local();
      try {
        const value = await fresh();
        signal.throwIfAborted();
        // Storage failure must not discard a successful server response.
        await set(storageKey, value, offlineLibraryStore).catch(
          () => undefined,
        );
        return value;
      } catch (error) {
        signal.throwIfAborted();
        if (cached !== undefined) return cached;
        throw error;
      }
    },
    enabled,
    staleTime: 0,
    refetchOnMount: "always",
    networkMode: "always",
    refetchOnReconnect: true,
    refetchInterval,
  });
}
