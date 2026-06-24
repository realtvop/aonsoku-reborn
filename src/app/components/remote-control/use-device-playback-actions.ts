import { useState } from "react";
import type { DevicePlaybackModel } from "./types";
import type { HandoffPhase } from "@/coordination/types";
import { toast } from "react-toastify";

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
  const [isConfirmationOpen, setIsConfirmationOpen] = useState(false);
  const [pendingDevice, setPendingDevice] = useState<DevicePlaybackModel | null>(null);
  const [handoffPhase, setHandoffPhase] = useState<HandoffPhase | null>(null);
  const [handoffError, setHandoffError] = useState<string | null>(null);
  const [isControlling, setIsControlling] = useState(false);
  const [controlledDeviceName, setControlledDeviceName] = useState<string | null>(null);

  const enterRemoteControl = (model: DevicePlaybackModel) => {
    setIsControlling(true);
    setControlledDeviceName(model.device.name);
    toast.success(`[UI Mock] Remote controlling: ${model.device.name}`);
  };

  const exitRemoteControl = () => {
    setIsControlling(false);
    setControlledDeviceName(null);
    toast.info("[UI Mock] Exited remote control");
  };

  const requestHandoff = (model: DevicePlaybackModel) => {
    // For UI session: if local playing state is active, or if we want to show the dialog:
    // We can simulate checking if local device is playing. For now, let's open the confirmation dialog.
    setPendingDevice(model);
    setIsConfirmationOpen(true);
  };

  const confirmLocalReplacement = () => {
    setIsConfirmationOpen(false);
    if (!pendingDevice) return;

    // Simulate handoff phases sequentially for visual verification
    setHandoffPhase("prepare");
    setHandoffError(null);

    setTimeout(() => {
      setHandoffPhase("prepare_relinquish");
    }, 1500);

    setTimeout(() => {
      setHandoffPhase("commit");
    }, 3000);

    setTimeout(() => {
      setHandoffPhase("committed");
      toast.success(`[UI Mock] Handoff from ${pendingDevice.device.name} successful!`);
      setTimeout(() => {
        setHandoffPhase(null);
        setPendingDevice(null);
      }, 1000);
    }, 4500);
  };

  const cancelPendingHandoff = () => {
    setIsConfirmationOpen(false);
    setPendingDevice(null);
    setHandoffPhase(null);
    toast.info("[UI Mock] Handoff cancelled");
  };

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
    isControlling,
    controlledDeviceName,
  };
}
