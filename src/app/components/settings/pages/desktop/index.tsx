import { DesktopSettings } from "./desktop";
import { LanControlSettings } from "./lanControl";
import { UpdateSettings } from "./updates";

export function Desktop() {
  return (
    <div className="space-y-4">
      <DesktopSettings />
      <UpdateSettings />
      <LanControlSettings />
    </div>
  );
}
