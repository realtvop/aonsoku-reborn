import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { toast } from "react-toastify";
import {
  mapLanControlToRemoteCommand,
  repeatModeToLoopState,
} from "@/coordination/remote-command-mapping";
import { useCoordinationStore } from "@/coordination/store";
import type {
  CoordinationErrorCode,
  DeviceId,
  HandoffPhase,
} from "@/coordination/types";
import { isNativeCoordinationAvailable } from "@/native/coordination";
import { usePlayerActions, usePlayerStore } from "@/store/player.store";
import { getHandoffErrorMessage } from "./handoff-error-message";
import type { DevicePlaybackModel } from "./types";

const SOURCE_CHANGED_MAX_RETRIES = 2;
const SOURCE_CHANGED_SNAPSHOT_WAIT_MS = 2500;
const HANDOFF_CLEAR_DELAY_MS = 1000;
const HANDOFF_SAFETY_TIMEOUT_MS = 15000;

interface HandoffRequestState {
  deviceId: DeviceId;
  isOnline: boolean;
}

export interface DevicePlaybackActions {
  enterRemoteControl: (model: DevicePlaybackModel) => void;
  exitRemoteControl: () => void;
  requestHandoff: (model: DevicePlaybackModel) => void;
  confirmLocalReplacement: () => void;
  cancelPendingHandoff: () => void;
  isConfirmationOpen: boolean;
  setIsConfirmationOpen: (open: boolean) => void;
  pendingDevice: DevicePlaybackModel | null;
  handoffPhase: HandoffPhase | null;
  handoffError: string | null;
  isControlling: boolean;
  controlledDeviceName: string | null;
}

export function useDevicePlaybackActions(): DevicePlaybackActions {
  const { t } = useTranslation();
  const manager = useCoordinationStore((state) => state.manager);
  const devices = useCoordinationStore((state) => state.devices);
  const controlledDeviceId = useCoordinationStore(
    (state) => state.controlledDeviceId,
  );
  const setControlledDevice = useCoordinationStore(
    (state) => state.setControlledDevice,
  );
  const playerActions = usePlayerActions();
  const [isConfirmationOpen, setIsConfirmationOpen] = useState(false);
  const [pendingDevice, setPendingDevice] =
    useState<DevicePlaybackModel | null>(null);
  const [handoffPhase, setHandoffPhase] = useState<HandoffPhase | null>(null);
  const [handoffError, setHandoffError] = useState<string | null>(null);
  const activeHandoffRef = useRef<HandoffRequestState | null>(null);
  const sourceChangedRetriesRef = useRef(0);
  const lastSentGenerationRef = useRef<number | null>(null);
  const lastSentRevisionRef = useRef<number | null>(null);
  const safetyTimeoutRef = useRef<number | null>(null);
  const clearPhaseTimeoutRef = useRef<number | null>(null);

  const controlledDeviceName = useMemo(
    () =>
      controlledDeviceId
        ? (devices.find((device) => device.id === controlledDeviceId)?.name ??
          null)
        : null,
    [controlledDeviceId, devices],
  );

  const clearHandoffTimers = useCallback(() => {
    if (safetyTimeoutRef.current !== null) {
      window.clearTimeout(safetyTimeoutRef.current);
      safetyTimeoutRef.current = null;
    }
    if (clearPhaseTimeoutRef.current !== null) {
      window.clearTimeout(clearPhaseTimeoutRef.current);
      clearPhaseTimeoutRef.current = null;
    }
  }, []);

  const finishHandoff = useCallback(
    (phase: HandoffPhase | null, error: string | null) => {
      clearHandoffTimers();
      activeHandoffRef.current = null;
      setHandoffPhase(phase);
      setHandoffError(error);

      if (phase === "committed") {
        clearPhaseTimeoutRef.current = window.setTimeout(() => {
          setHandoffPhase(null);
          setPendingDevice(null);
        }, HANDOFF_CLEAR_DELAY_MS);
      }
    },
    [clearHandoffTimers],
  );

  const startHandoff = useCallback(
    (model: DevicePlaybackModel) => {
      const snapshotData =
        useCoordinationStore.getState().deviceSnapshots[model.device.id];

      if (!snapshotData) {
        const message = getHandoffErrorMessage(t, "snapshot_expired");
        setHandoffError(message);
        toast.error(message);
        return;
      }

      const remoteControl = usePlayerStore.getState().remoteControl;
      if (remoteControl.active) {
        usePlayerStore.setState({
          remoteControl: {
            active: false,
            device: null,
            sendCommand: null,
          },
        });
        playerActions.setPlayingState(false);
        setControlledDevice(null);
        manager.sendControlSessionEnd();
      }

      clearHandoffTimers();
      activeHandoffRef.current = {
        deviceId: model.device.id,
        isOnline: snapshotData.isOnline,
      };
      sourceChangedRetriesRef.current = 0;
      lastSentGenerationRef.current = snapshotData.generation;
      lastSentRevisionRef.current = snapshotData.snapshotRevision;
      setPendingDevice(null);
      setHandoffError(null);
      setHandoffPhase("prepare");

      if (isNativeCoordinationAvailable()) {
        manager.requestHandoffCandidateFromCache(model.device.id);
      } else {
        manager.requestHandoffCandidate(
          model.device.id,
          snapshotData.generation,
          snapshotData.snapshotRevision,
        );
      }
      toast.info(
        t("settings.crossDevice.toast.preparingRelay", {
          defaultValue: "Preparing handoff...",
        }),
      );

      safetyTimeoutRef.current = window.setTimeout(() => {
        if (!activeHandoffRef.current) return;
        const message = getHandoffErrorMessage(t, "source_pause_timeout");
        finishHandoff(null, message);
        toast.error(message);
      }, HANDOFF_SAFETY_TIMEOUT_MS);
    },
    [
      clearHandoffTimers,
      finishHandoff,
      manager,
      playerActions,
      setControlledDevice,
      t,
    ],
  );

  const exitRemoteControl = useCallback(() => {
    const state = usePlayerStore.getState();
    if (!state.remoteControl.active && !controlledDeviceId) return;

    usePlayerStore.setState({
      remoteControl: {
        active: false,
        device: null,
        sendCommand: null,
      },
    });
    state.actions.setPlayingState(false);
    setControlledDevice(null);
    manager.sendControlSessionEnd();
    toast.info(
      t("settings.crossDevice.toast.exitRemoteControl", {
        defaultValue: "Exited remote control",
      }),
    );
  }, [controlledDeviceId, manager, setControlledDevice, t]);

  const enterRemoteControl = useCallback(
    (model: DevicePlaybackModel) => {
      if (!model.canBeControlled) return;
      if (controlledDeviceId === model.device.id) return;

      const currentRemoteControl = usePlayerStore.getState().remoteControl;
      if (currentRemoteControl.active || controlledDeviceId) {
        usePlayerStore.setState({
          remoteControl: {
            active: false,
            device: null,
            sendCommand: null,
          },
        });
        setControlledDevice(null);
        manager.sendControlSessionEnd();
      }

      playerActions.setPlayingState(false);
      usePlayerStore.setState({
        remoteControl: {
          active: true,
          device: {
            name: model.device.name,
            version: model.device.clientVersion ?? "",
          },
          sendCommand: (type, data) => {
            const coordinationState = useCoordinationStore.getState();
            const snapshotData =
              coordinationState.deviceSnapshots[model.device.id];
            const command = mapLanControlToRemoteCommand(type, data, () => {
              const snapshot = snapshotData?.snapshot;
              if (snapshot) {
                return {
                  isShuffleActive: snapshot.shuffle,
                  loopState: repeatModeToLoopState(snapshot.repeat),
                };
              }
              const playerState = usePlayerStore.getState();
              return {
                isShuffleActive: playerState.songlist.isShuffleActive,
                loopState: playerState.playerState.loopState,
              };
            });
            if (!command) return;

            if (isNativeCoordinationAvailable()) {
              coordinationState.manager.sendActiveControlCommand(command);
              return;
            }

            if (!snapshotData) return;
            coordinationState.manager.sendCommand(
              model.device.id,
              snapshotData.generation,
              command,
            );
          },
        },
      });
      setControlledDevice(model.device.id);
      manager.sendControlSessionBegin(model.device.id);
      toast.success(
        t("settings.crossDevice.toast.remoteControlSuccess", {
          defaultValue: "Remote controlling: {{name}}",
          name: model.device.name,
        }),
      );
    },
    [controlledDeviceId, manager, playerActions, setControlledDevice, t],
  );

  const requestHandoff = useCallback(
    (model: DevicePlaybackModel) => {
      if (!model.canBeContinuedLocally) return;

      const playerState = usePlayerStore.getState();
      const isLocalPlaybackActive =
        playerState.playerState.isPlaying && !playerState.remoteControl.active;

      if (isLocalPlaybackActive) {
        setPendingDevice(model);
        setIsConfirmationOpen(true);
        return;
      }

      startHandoff(model);
    },
    [startHandoff],
  );

  const confirmLocalReplacement = useCallback(() => {
    if (!pendingDevice) return;
    setIsConfirmationOpen(false);
    startHandoff(pendingDevice);
  }, [pendingDevice, startHandoff]);

  const cancelPendingHandoff = useCallback(() => {
    setIsConfirmationOpen(false);
    setPendingDevice(null);
  }, []);

  useEffect(() => {
    const originalCommitted = manager.callbacks.onHandoffCommitted;
    const originalFailed = manager.callbacks.onHandoffFailed;
    const originalError = manager.callbacks.onError;

    manager.callbacks.onHandoffCommitted = (snapshot, newGeneration) => {
      originalCommitted(snapshot, newGeneration);
      if (!activeHandoffRef.current) return;
      finishHandoff("committed", null);
      toast.success(
        t("settings.crossDevice.toast.relaySuccess", {
          defaultValue: "Handoff successful!",
        }),
      );
    };

    manager.callbacks.onHandoffFailed = (transactionId, code) => {
      originalFailed(transactionId, code);
      if (!activeHandoffRef.current) return;
      const message = getHandoffErrorMessage(t, code);
      finishHandoff(null, message);
      toast.error(message);
    };

    manager.callbacks.onError = (code, reason) => {
      const activeHandoff = activeHandoffRef.current;
      if (!activeHandoff) {
        originalError(code, reason);
        return;
      }

      if (
        code === "source_changed" &&
        sourceChangedRetriesRef.current < SOURCE_CHANGED_MAX_RETRIES
      ) {
        sourceChangedRetriesRef.current += 1;
        setHandoffPhase("prepare");
        if (!activeHandoff.isOnline) {
          originalError(code, reason);
          const message = getHandoffErrorMessage(t, code, reason);
          finishHandoff(null, message);
          toast.error(message);
          return;
        }

        manager.requestSnapshots();
        const cached = manager.getLatestDeviceSnapshot(activeHandoff.deviceId);

        if (
          cached &&
          (cached.generation !== lastSentGenerationRef.current ||
            cached.snapshotRevision !== lastSentRevisionRef.current)
        ) {
          lastSentGenerationRef.current = cached.generation;
          lastSentRevisionRef.current = cached.snapshotRevision;
          manager.requestHandoffCandidate(
            activeHandoff.deviceId,
            cached.generation,
            cached.snapshotRevision,
          );
          return;
        }

        manager
          .waitForDeviceSnapshotUpdate(
            activeHandoff.deviceId,
            SOURCE_CHANGED_SNAPSHOT_WAIT_MS,
          )
          .then(({ generation, snapshotRevision }) => {
            if (!activeHandoffRef.current) return;
            lastSentGenerationRef.current = generation;
            lastSentRevisionRef.current = snapshotRevision;
            manager.requestHandoffCandidate(
              activeHandoff.deviceId,
              generation,
              snapshotRevision,
            );
          })
          .catch(() => {
            originalError(code, reason);
            const message = getHandoffErrorMessage(t, code, reason);
            finishHandoff(null, message);
            toast.error(message);
          });
        return;
      }

      originalError(code as CoordinationErrorCode, reason);
      const message = getHandoffErrorMessage(t, code, reason);
      finishHandoff(null, message);
      toast.error(message);
    };

    return () => {
      manager.callbacks.onHandoffCommitted = originalCommitted;
      manager.callbacks.onHandoffFailed = originalFailed;
      manager.callbacks.onError = originalError;
    };
  }, [finishHandoff, manager, t]);

  useEffect(() => clearHandoffTimers, [clearHandoffTimers]);

  return {
    enterRemoteControl,
    exitRemoteControl,
    requestHandoff,
    confirmLocalReplacement,
    cancelPendingHandoff,
    isConfirmationOpen,
    setIsConfirmationOpen,
    pendingDevice,
    handoffPhase,
    handoffError,
    isControlling: !!controlledDeviceId,
    controlledDeviceName,
  };
}
