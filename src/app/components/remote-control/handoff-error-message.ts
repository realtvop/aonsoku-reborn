import type { TFunction } from "i18next";

export function getHandoffErrorMessage(
  t: TFunction,
  code: string,
  reason?: string,
): string {
  switch (code) {
    case "target_offline":
      return t("settings.crossDevice.handoffError.targetOffline", {
        defaultValue: "The device went offline.",
      });
    case "snapshot_expired":
      return t("settings.crossDevice.handoffError.snapshotExpired", {
        defaultValue: "That playback snapshot is too old to continue.",
      });
    case "handoff_conflict":
      return t("settings.crossDevice.handoffError.handoffConflict", {
        defaultValue: "Another handoff already took this session.",
      });
    case "source_changed":
      return t("settings.crossDevice.handoffError.sourceChanged", {
        defaultValue: "The source changed before it could be transferred.",
      });
    case "source_pause_timeout":
      return t("settings.crossDevice.handoffError.sourcePauseTimeout", {
        defaultValue: "The source device did not confirm pause in time.",
      });
    case "unsupported_media":
      return t("settings.crossDevice.handoffError.unsupportedMedia", {
        defaultValue: "This media type cannot be continued on another device.",
      });
    case "device_revoked":
      return t("settings.crossDevice.handoffError.deviceRevoked", {
        defaultValue:
          "This device is no longer allowed to use cross-device sync.",
      });
    case "protocol_incompatible":
    case "capability_disabled":
      return t("settings.crossDevice.handoffError.protocolIncompatible", {
        defaultValue: "Update Aonsoku on one or more devices.",
      });
    case "forbidden":
      return t("settings.crossDevice.handoffError.forbidden", {
        defaultValue:
          "This device cannot be controlled or transferred right now.",
      });
    default:
      return t("settings.crossDevice.handoffError.fallback", {
        defaultValue: "Handoff failed: {{reason}}",
        reason: reason || code,
      });
  }
}
