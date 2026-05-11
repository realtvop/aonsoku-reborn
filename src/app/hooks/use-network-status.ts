import { useEffect, useRef } from "react";
import { probeServerConnection } from "@/api/pingServer";
import { useAppStore } from "@/store/app.store";
import { useCacheActions, useCacheStore } from "@/store/cache.store";

let reachabilityCheckTimeout: ReturnType<typeof setTimeout> | null = null;
let inFlightProbe: Promise<boolean> | null = null;

export function getConfiguredUrls(): string[] {
  const { primaryUrl, fallbackUrl, url, coordinationUrl } =
    useAppStore.getState().data;
  return Array.from(
    new Set(
      [primaryUrl, fallbackUrl, url, coordinationUrl].filter(Boolean),
    ),
  ) as string[];
}

export function checkServerReachability(): Promise<boolean> {
  if (inFlightProbe) return inFlightProbe;

  const { username, password, authType } = useAppStore.getState().data;
  const urls = getConfiguredUrls();

  if (urls.length === 0 || !username || !password || authType === null) {
    return Promise.resolve(true);
  }

  inFlightProbe = Promise.all(
    urls.map((serverUrl) =>
      probeServerConnection(serverUrl, username, password, authType),
    ),
  )
    .then((probes) => {
      const reachable = probes.some((probe) => probe.status === "ok");
      useCacheStore.getState().actions.setIsOnline(reachable);
      return reachable;
    })
    .catch(() => {
      useCacheStore.getState().actions.setIsOnline(false);
      return false;
    })
    .finally(() => {
      inFlightProbe = null;
    });

  return inFlightProbe;
}

export function markServerUnreachable() {
  const store = useCacheStore.getState();
  if (!store.status.isOnline) return;

  store.actions.setIsOnline(false);

  if (reachabilityCheckTimeout !== null) {
    clearTimeout(reachabilityCheckTimeout);
  }
  reachabilityCheckTimeout = setTimeout(() => {
    reachabilityCheckTimeout = null;
    checkServerReachability();
  }, 5000);
}

function scheduleReachabilityCheck(delay: number) {
  if (reachabilityCheckTimeout !== null) {
    clearTimeout(reachabilityCheckTimeout);
  }
  reachabilityCheckTimeout = setTimeout(() => {
    reachabilityCheckTimeout = null;
    checkServerReachability();
  }, delay);
}

export function useNetworkStatusObserver() {
  const { setIsOnline } = useCacheActions();
  const mountedRef = useRef(false);

  useEffect(() => {
    if (mountedRef.current) return;
    mountedRef.current = true;

    checkServerReachability();
  }, []);

  useEffect(() => {
    const handleOnline = () => {
      scheduleReachabilityCheck(200);
    };

    const handleOffline = () => {
      setIsOnline(false);
    };

    const handleFocus = () => {
      if (!useCacheStore.getState().status.isOnline) {
        scheduleReachabilityCheck(0);
      }
    };

    window.addEventListener("online", handleOnline);
    window.addEventListener("offline", handleOffline);
    window.addEventListener("focus", handleFocus);

    return () => {
      window.removeEventListener("online", handleOnline);
      window.removeEventListener("offline", handleOffline);
      window.removeEventListener("focus", handleFocus);
      if (reachabilityCheckTimeout !== null) {
        clearTimeout(reachabilityCheckTimeout);
        reachabilityCheckTimeout = null;
      }
    };
  }, [setIsOnline]);
}

export function useNetworkStatus() {
  const isOnline = useCacheStore((state) => state.status.isOnline);

  return {
    isOnline,
    isOfflineMode: !isOnline,
  };
}

export function getNetworkStatus() {
  const state = useCacheStore.getState();
  return {
    isOnline: state.status.isOnline,
    isOfflineMode: !state.status.isOnline,
  };
}
