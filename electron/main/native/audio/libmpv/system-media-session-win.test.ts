import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const source = readFileSync(
  fileURLToPath(new URL("./src/system_media_session_win.cc", import.meta.url)),
  "utf8",
);

describe("Windows native system media session", () => {
  it("binds desktop SMTC to a top-level window through Win32 interop", () => {
    expect(source).toContain("<systemmediatransportcontrolsinterop.h>");
    expect(source).toContain("ISystemMediaTransportControlsInterop");
    expect(source).toContain("GetForWindow(");
    expect(source).toContain("guid_of<SystemMediaTransportControls>()");
    expect(source).toContain("EnumWindows(");
    expect(source).toContain("GetCurrentProcessId()");
    expect(source).not.toContain("GetForCurrentView");
  });

  it("keeps initialization retryable after a missing window or SMTC failure", () => {
    expect(source).toContain("if (window == nullptr) return false;");
    expect(source).toContain("ResetControls();\n    return false;");
    expect(source).not.toContain("g_initialized");
  });

  it("contains native exceptions and updates play/pause capabilities", () => {
    expect(source).toContain("double position) try {");
    expect(source).toContain("void ClearSystemMediaSession() try {");
    expect(source).toContain("g_controls.IsPlayEnabled(");
    expect(source).toContain("g_controls.IsPauseEnabled(");
  });
});
