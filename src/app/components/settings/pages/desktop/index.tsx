import { DesktopSettings } from "./desktop";
import { DiscordRpc } from "./discord-rpc";
import { UpdateSettings } from "./updates";

export function Desktop() {
  return (
    <div className="space-y-4">
      <DesktopSettings />
      <DiscordRpc />
      <UpdateSettings />
    </div>
  );
}
