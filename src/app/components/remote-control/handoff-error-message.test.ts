import type { TFunction } from "i18next";
import { describe, expect, it } from "vitest";
import { getHandoffErrorMessage } from "./handoff-error-message";

function testT(key: string, options?: Record<string, unknown>): string {
  const defaults: Record<string, string> = {
    "settings.crossDevice.handoffError.targetOffline":
      "The device went offline.",
    "settings.crossDevice.handoffError.snapshotExpired":
      "That playback snapshot is too old to continue.",
    "settings.crossDevice.handoffError.handoffConflict":
      "Another handoff already took this session.",
    "settings.crossDevice.handoffError.sourceChanged":
      "The source changed before it could be transferred.",
    "settings.crossDevice.handoffError.sourcePauseTimeout":
      "The source device did not confirm pause in time.",
    "settings.crossDevice.handoffError.unsupportedMedia":
      "This media type cannot be continued on another device.",
    "settings.crossDevice.handoffError.deviceRevoked":
      "This device is no longer allowed to use cross-device sync.",
    "settings.crossDevice.handoffError.protocolIncompatible":
      "Update Aonsoku on one or more devices.",
    "settings.crossDevice.handoffError.forbidden":
      "This device cannot be controlled or transferred right now.",
    "settings.crossDevice.handoffError.fallback":
      `Handoff failed: ${String(options?.reason)}`,
  };

  return defaults[key] ?? String(options?.defaultValue ?? key);
}

describe("getHandoffErrorMessage", () => {
  const t = testT as TFunction;

  it("maps coordination handoff codes to user-facing messages", () => {
    expect(getHandoffErrorMessage(t, "target_offline")).toBe(
      "The device went offline.",
    );
    expect(getHandoffErrorMessage(t, "snapshot_expired")).toBe(
      "That playback snapshot is too old to continue.",
    );
    expect(getHandoffErrorMessage(t, "handoff_conflict")).toBe(
      "Another handoff already took this session.",
    );
    expect(getHandoffErrorMessage(t, "source_changed")).toBe(
      "The source changed before it could be transferred.",
    );
    expect(getHandoffErrorMessage(t, "source_pause_timeout")).toBe(
      "The source device did not confirm pause in time.",
    );
    expect(getHandoffErrorMessage(t, "unsupported_media")).toBe(
      "This media type cannot be continued on another device.",
    );
    expect(getHandoffErrorMessage(t, "device_revoked")).toBe(
      "This device is no longer allowed to use cross-device sync.",
    );
    expect(getHandoffErrorMessage(t, "forbidden")).toBe(
      "This device cannot be controlled or transferred right now.",
    );
  });

  it("shares update guidance for protocol and capability errors", () => {
    expect(getHandoffErrorMessage(t, "protocol_incompatible")).toBe(
      "Update Aonsoku on one or more devices.",
    );
    expect(getHandoffErrorMessage(t, "capability_disabled")).toBe(
      "Update Aonsoku on one or more devices.",
    );
  });

  it("falls back to reason or raw code for unknown failures", () => {
    expect(getHandoffErrorMessage(t, "internal", "server is tired")).toBe(
      "Handoff failed: server is tired",
    );
    expect(getHandoffErrorMessage(t, "internal")).toBe(
      "Handoff failed: internal",
    );
  });
});
