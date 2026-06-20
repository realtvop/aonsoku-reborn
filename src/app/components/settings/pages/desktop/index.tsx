import { DesktopSettings } from "./desktop";

import { UpdateSettings } from "./updates";

export function Desktop() {
  return (
    <div className="space-y-4">
      <DesktopSettings />
      <UpdateSettings />
    </div>
  );
}
