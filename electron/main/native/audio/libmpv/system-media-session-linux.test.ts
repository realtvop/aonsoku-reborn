import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync(
  new URL("./src/system_media_session_linux.cc", import.meta.url),
  "utf8",
);

describe("Linux MPRIS implementation", () => {
  it("guards artwork and uses per-track object paths", () => {
    expect(source).toContain('artwork_url.rfind("file://", 0) == 0');
    expect(source).toContain('"/org/mpris/MediaPlayer2/track/" +');
    expect(source).not.toContain('"/org/mpris/MediaPlayer2/track/active"');
  });

  it("exposes fixed-rate properties and checks bus-name ownership", () => {
    expect(source).toContain("<property name='Rate' type='d'");
    expect(source).toContain("<property name='MinimumRate' type='d'");
    expect(source).toContain("<property name='MaximumRate' type='d'");
    expect(source).toContain("DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER");
    expect(source).toContain("DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER");
  });

  it("validates SetPosition and delays Seeked until the state update", () => {
    expect(source).toContain("track_id == g_state.track_id");
    expect(source).toContain("target <= g_state.metadata.duration");
    expect(source).toContain("const double requested = CurrentPosition() +");
    expect(source).toContain(
      "static_cast<int64_t>(CurrentPosition() * 1'000'000)",
    );
    const updateStart = source.indexOf("void UpdateSystemMediaSession(");
    expect(source.slice(0, updateStart)).not.toContain(
      "EmitSeeked(connection, target)",
    );
    expect(source.slice(updateStart)).toContain(
      "EmitSeeked(g_state.connection, g_state.position)",
    );
  });

  it("dispatches MPRIS Stop through the native stop command", () => {
    expect(source).toContain("DispatchCommand(SystemMediaCommand::kStop, 0)");
    expect(source).not.toContain(
      "DispatchCommand(SystemMediaCommand::kPause, 0);\n    DispatchCommand(SystemMediaCommand::kSeek, 0)",
    );
  });
});
