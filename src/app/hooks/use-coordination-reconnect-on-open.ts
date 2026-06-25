import { useCallback } from "react";
import { useCoordinationStore } from "@/coordination/store";

const CONNECTING_STATES = new Set(["connecting", "reconnecting"]);

export function useCoordinationReconnectOnOpen() {
  const isConnected = useCoordinationStore((state) => state.isConnected);
  const connectionState = useCoordinationStore(
    (state) => state.connectionState,
  );
  const loadState = useCoordinationStore((state) => state.loadState);

  return useCallback(
    (open: boolean) => {
      if (
        !open ||
        isConnected ||
        CONNECTING_STATES.has(connectionState)
      ) {
        return;
      }

      loadState().catch(() => {});
    },
    [connectionState, isConnected, loadState],
  );
}
