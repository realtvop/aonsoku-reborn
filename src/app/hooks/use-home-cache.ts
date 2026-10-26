import {
  type QueryClient,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { get, set } from "idb-keyval";
import { type HomeCacheEntry, loadCachedHomeData } from "@/lib/home-cache";
import { libraryAccountKey } from "@/lib/library-owner";
import { useAppStore } from "@/store/app.store";
import { offlineLibraryStore } from "@/store/idb";

const forcedRandomQueries = new WeakSet<object>();

/** Manual refresh is the only invalidation that explicitly rerolls random lists. */
export async function refreshCachedHome(client: QueryClient) {
  const randomQueries = client.getQueryCache().findAll({
    type: "active",
    predicate: (query) => query.meta?.homeRandom === true,
  });
  await client.cancelQueries({
    predicate: (query) => randomQueries.includes(query),
  });
  for (const query of randomQueries) forcedRandomQueries.add(query);
  try {
    await Promise.all([
      client.invalidateQueries({ queryKey: ["albums"] }),
      client.invalidateQueries({ queryKey: ["home"] }),
    ]);
  } finally {
    for (const query of randomQueries) forcedRandomQueries.delete(query);
  }
}

/** Restore Home query results across reloads without mixing server/accounts. */
export function useCachedHomeQuery<T>({
  key,
  isOnline,
  local,
  fresh,
  hasContent,
  enabled = true,
  refetchInterval,
  keepRandom = false,
  localFirst = false,
}: {
  key: readonly unknown[];
  isOnline: boolean;
  local: (account: string) => Promise<T>;
  fresh: () => Promise<T>;
  hasContent: (value: T) => boolean;
  enabled?: boolean;
  refetchInterval?: number | false;
  keepRandom?: boolean;
  localFirst?: boolean;
}) {
  const account = useAppStore((state) => libraryAccountKey(state.data));
  const client = useQueryClient();
  const queryKey = [...key, account, isOnline ? "online" : "offline"];
  const storageKey = JSON.stringify(["home.snapshot.v1", account, key]);

  return useQuery<T>({
    queryKey,
    queryFn: ({ signal }) => {
      const query = client.getQueryCache().find({ queryKey, exact: true });
      const force = query !== undefined && forcedRandomQueries.has(query);
      return loadCachedHomeData<T>({
        read: () => get<HomeCacheEntry<T> | T>(storageKey, offlineLibraryStore),
        write: (entry) => set(storageKey, entry, offlineLibraryStore),
        memory: client.getQueryData<T>(queryKey),
        publish: (value) => client.setQueryData(queryKey, value),
        local: () => local(account),
        fresh,
        hasContent,
        online: isOnline,
        keepRandom,
        localFirst,
        force,
        signal,
      });
    },
    meta: { homeRandom: keepRandom },
    enabled,
    staleTime: 0,
    refetchOnMount: "always",
    networkMode: "always",
    refetchOnReconnect: true,
    refetchInterval,
  });
}
