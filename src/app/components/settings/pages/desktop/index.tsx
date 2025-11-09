import { DesktopSettings } from "./desktop";
import { LanControlSettings } from "./lanControl";

export function Desktop() {
  return (
    <div className="space-y-4">
      <DesktopSettings />
      <LanControlSettings />
    </div>
  );
}
