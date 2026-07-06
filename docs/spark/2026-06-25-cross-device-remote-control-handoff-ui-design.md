# Cross-Device Remote Control and Handoff UI/UX Design

Date: 2026-06-25
Status: Approved for spec review

## Context

Aonsoku already has the coordination backend, realtime protocol, playback
snapshot projection, remote commands, online handoff, offline handoff, and
multi-stack playback integration. The current frontend exposes these abilities
mainly through `src/app/components/home/cross-device-playbacks.tsx` and
connection/device management through
`src/app/components/settings/pages/cross-device/index.tsx`.

The existing UI works functionally, but it mixes discovery, action handling,
handoff state, remote-control setup, song metadata loading, and card rendering
inside one Home component. It also places the primary cross-device experience
away from the persistent player, even though the user's mental model is "where
am I listening and what device am I controlling?"

This design refactors the frontend UI/UX only. Backend protocol, server logic,
handoff state machine, snapshot publishing, command routing, player-store
remote-control plumbing, and playback backend behavior remain in place unless a
small adapter is needed to present existing state cleanly.

## Goals

- Make cross-device playback feel as immediate as Spotify Connect while
  preserving Aonsoku's ability to play on multiple devices at the same time.
- Put device selection, remote control, and handoff in the persistent player
  experience instead of burying them in Home or Settings.
- Make remote control visually obvious so users do not confuse controlling a
  remote device with playing locally.
- Separate online devices from offline handoff snapshots so the UI does not
  imply that an offline source can be stopped remotely.
- Keep Settings focused on connection, device management, and diagnostics.
- Improve code boundaries so device grouping, action orchestration, and UI
  rendering can be tested independently.

## Non-Goals

- No backend, database, protocol, native plugin, or coordination-server changes.
- No changes to the meaning of remote commands, snapshots, generation checks,
  source-changed retries, or handoff commit semantics.
- No podcast, radio, or non-song handoff support beyond existing behavior.
- No global "single active output" model. Multiple devices may keep playing
  independently unless the user explicitly controls or hands off a selected
  device.
- No playback controls in Settings.

## Chosen Approach

Use a player-first device panel.

The persistent player becomes the main cross-device operation surface. A device
button opens a dedicated device panel where the user can inspect this device,
live peer devices, and valid offline playback snapshots. Home keeps a lightweight
overview so users can notice other active devices, but all meaningful actions
open or route through the device panel. Settings becomes a management and
diagnostic page.

This approach was chosen over a standalone device center or a Home-first
redesign because device switching and remote control are playback actions. They
should be reachable from anywhere the persistent player is visible.

## Information Architecture

```text
Persistent Player = operation center
Home              = discovery and reminder
Settings          = connection, management, diagnostics
```

### Persistent Player

The player gets a device button near the existing right-side controls on desktop
and in the reachable mini-player control area on mobile. The button opens the
device panel. If cross-device coordination is not configured or not connected,
the panel shows a compact empty or disconnected state with a route to
Cross-Device Settings.

When remote control is active, the player enters a dedicated Remote Mode instead
of presenting itself as normal local playback.

### Home

Home keeps a lightweight "Other devices playing" overview. It shows peer device
name, platform, online/offline indicator, current or last-known track, and an
action to open the device panel. It does not expose full remote-control or
handoff controls directly.

### Settings

Cross-Device Settings manages:

- Coordination server URL and identity URL.
- Current connection state and diagnostic errors.
- Current device name.
- Bound devices, rename, revoke, and last-online metadata.
- Disconnect current device.
- Delete coordination data.

It does not show remote-control, handoff, or offline-continue playback actions.

## Device Panel

The panel is divided by user intent and protocol semantics:

```text
Device Panel
├─ This device
├─ Live devices
└─ Continue from offline playback
```

### This Device

This section identifies the current device and local playback state. It helps the
user understand the target of "Continue here" actions. When remote control is
active, this section changes to a Remote Mode summary with the controlled device
name and an Exit action.

### Live Devices

Live devices include online peer devices with a valid song snapshot. Each card
shows:

- Platform icon and device name.
- Online status.
- Track title, artist, cover art, and playback state.
- Projected progress and duration.
- Last confirmed/synced freshness when useful.
- Explicit `Control` action.
- Explicit `Continue here` action.

The full card has no default click action. This avoids accidental handoff or
remote-control entry.

`Control` enters remote-control mode. The local player becomes a command surface
for the target device, and local audio output is not mounted.

`Continue here` starts handoff from the selected device to the current device.
If the current device is actively playing local audio, the user must confirm the
replacement first.

Devices that are currently acting as controllers remain hidden or disabled for
remote control and handoff, matching the existing control-session exclusivity
rules.

### Offline Playback Snapshots

Offline snapshots appear in a separate collapsible section named "Continue from
offline playback". They are shown only when the snapshot is valid under the
existing expiry rules and has a supported song snapshot.

Offline cards show:

- Device name and platform.
- "Last seen" or "Last synced" freshness.
- Last-known track, artist, cover art, and progress.
- A single `Continue` action.

They do not show `Control`, and the copy must not imply that Aonsoku can pause or
stop the offline source device. The semantics are: continue locally from the last
known snapshot.

## Handoff Confirmation and Feedback

If the current device is actively playing and the user chooses `Continue here`
from another device, show a confirmation dialog before requesting handoff:

```text
Continue playback here?

Current on this device
Song X - Artist X

Will continue from iPhone
Song B - Artist B, 1:24

[Cancel] [Continue here]
```

If the current device is not playing, handoff may begin without the replacement
confirmation.

Handoff progress is displayed as staged feedback rather than a generic spinner:

```text
Preparing track -> Pausing source device -> Continuing here
```

The existing `source_changed` retry behavior remains. During that retry window,
the UI says that it is syncing the latest state from the source device.

On success, the player returns to normal local playback and begins playing the
committed snapshot. On failure, show a user-facing error mapped from the
coordination error code:

- `target_offline`: The device went offline.
- `snapshot_expired`: That playback snapshot is too old to continue.
- `handoff_conflict`: Another handoff already took this session.
- `source_changed`: The source changed before it could be transferred.
- `source_pause_timeout`: The source device did not confirm pause in time.
- `unsupported_media`: This media type cannot be continued on another device.
- `device_revoked`: This device is no longer allowed to use cross-device sync.
- `protocol_incompatible` or `capability_disabled`: Update Aonsoku on one or
  more devices.
- `forbidden`: This device cannot be controlled or transferred right now.
- fallback: Handoff failed with the returned reason.

## Remote Control Mode

Remote Mode is a visible player state, not just a toast. It should look like a
remote-control surface:

```text
Cover  Song B / Artist B
       Controlling iPhone                     [Exit]

       previous  play/pause  next  volume  queue
```

Behavior:

- Player controls, progress seek, volume, shuffle, repeat, queue actions, and
  supported play actions route through `remoteControl.sendCommand`.
- Remote snapshots continue to update the projected song, queue, progress,
  play/pause state, shuffle, repeat, and volume.
- Local audio elements are not mounted for the controlled song.
- Local play history and scrobbling remain suppressed while remote control is
  active.
- `Exit` ends the control session, clears the remote-control projection, and
  returns the player to normal local state.

Remote Mode should be prominent in the player, but it should not use a global
banner. The user needs clarity without a persistent warning across the entire
application.

## Component and State Boundaries

The current Home card component should be split into model, action, and view
layers.

```text
coordination store / manager
        |
        v
useDevicePlaybackModels
        |
        v
DevicePanel and Home overview

useDevicePlaybackActions
        |
        v
remote control, confirmation, handoff request, exit control
```

### `useDevicePlaybackModels`

Responsible for deriving render-ready device models from existing coordination
state:

- Merge `devices`, `deviceSnapshots`, current `deviceId`, and
  `controlledDeviceId`.
- Group devices into `thisDevice`, `liveDevices`, `offlineSnapshots`, and
  `hiddenDevices`.
- Compute whether each device can be controlled.
- Compute whether each device can be continued locally.
- Project progress using the existing projection helper.
- Preserve the existing eight-hour offline snapshot eligibility rule.
- Attach enough song metadata state for cards to render loading, known track,
  and unknown-track states.

This hook does not send commands or mutate player state.

### `useDevicePlaybackActions`

Responsible for user actions:

- `enterRemoteControl(deviceId)`.
- `exitRemoteControl()`.
- `requestHandoff(deviceId)`.
- `confirmLocalReplacement()`.
- `cancelPendingHandoff()`.

It coordinates existing `CoordinationManager` methods, player-store
`remoteControl`, `controlledDeviceId`, control-session begin/end, and the
handoff candidate request. It owns local UI state for confirmation dialogs and
handoff phases.

### Views

Suggested view components:

- `PlayerDeviceButton`.
- `DevicePanel`.
- `ThisDeviceSection`.
- `LiveDevicesSection`.
- `OfflineSnapshotsSection`.
- `DevicePlaybackCard`.
- `RemoteModePlayerStatus`.
- `HandoffConfirmationDialog`.
- `HandoffStatusRow`.
- `HomeDevicePlaybackOverview`.

The player uses only the device button and remote-mode presentation. It should
not know protocol details such as generation, snapshot revision, or transaction
id.

Home uses the same model hook but renders the lightweight overview only.

Settings uses connection and device-management state only. It should not import
device playback actions.

## Responsive Behavior

Desktop:

- Device panel opens from the player device button as a right-side sheet or
  popover-like panel.
- Target width is roughly 380 to 440 px.
- Long device names, song titles, and artists truncate cleanly.
- The current remote-control status or active handoff phase remains visible near
  the top of the panel when the list scrolls.

Mobile:

- Device panel opens as a bottom sheet.
- It respects safe-area insets and does not conflict with system gestures.
- The sheet can scroll independently from the app content.
- Primary actions remain large enough for touch and use text plus icons.

Both:

- No nested card containers for whole page sections.
- Device cards use compact, scan-friendly styling.
- Online and offline sections must be visually distinct.
- Progress display must not imply local buffering for remote playback. Remote
  buffered progress is hidden or visually de-emphasized.

## Accessibility and Copy

- Every icon-only control has an accessible label and tooltip.
- `Control`, `Continue here`, `Continue`, and `Exit` use clear text labels.
- Handoff confirmation focuses the cancel/confirm flow correctly and can be
  dismissed with Escape.
- Remote Mode exposes "Controlling <device>" in visible text and accessible
  labels.
- Offline copy uses "last synced" or "last seen" language, not "playing now".
- Error messages are human-readable and do not expose raw protocol codes as the
  primary text.

## Testing

Unit tests:

- Device grouping into this device, live devices, offline snapshots, and hidden
  devices.
- Offline snapshot expiry at the existing eight-hour boundary.
- Control and handoff action availability.
- Error-code to user-message mapping.
- Handoff phase transitions in the action layer.

Component tests:

- Device panel renders live and offline sections separately.
- Offline cards show `Continue` only.
- Online cards show separate `Control` and `Continue here` actions.
- Local playback replacement confirmation appears when local playback is active.
- Remote Mode player shows the controlled device and Exit action.
- Settings does not expose playback control actions.

Light Cypress coverage:

- Open device panel from the player.
- Enter remote control and exit remote control.
- Start handoff while local playback is active and confirm replacement.
- Verify an offline snapshot appears in the offline section and does not offer
  remote control.

Visual QA:

- Desktop and mobile viewport checks.
- Long device names and long track titles truncate without overlap.
- Player device button does not crowd track info or primary playback controls.
- Bottom sheet and right sheet keep primary actions reachable.

## Implementation Notes

The implementation should keep behavior consistent across web, Electron, and
native runtimes. Because the backend and playback abstraction already support
the core behavior, this frontend refactor should avoid changing
`PlaybackBackend`, queue controllers, native coordination facade, or server
protocol types unless a small type-safe adapter is required for presentation.

The existing `CrossDevicePlaybacks` logic should be used as the behavioral
source for remote command mapping, control-session begin/end, and handoff retry
semantics, but its responsibilities should move into the model/action/view
boundaries above.

The existing server design document remains the source of truth for protocol
invariants:

- `docs/spark/2026-06-20-cross-device-coordination-server-design.md`

This UI design is complete when users can discover active peer playback from
Home, operate devices from the player panel, understand when they are controlling
a remote device, safely confirm destructive handoff replacement, and manage
device registration from Settings without playback controls leaking into that
page.
