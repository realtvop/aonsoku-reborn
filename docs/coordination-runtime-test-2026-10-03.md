# Coordination device verification — 2026-10-03

## Environment

- macOS Electron development app with the native libmpv playback backend.
- Pixel 5 running the locally built Android debug APK, installed over the
  existing app with account data retained.
- Coordination endpoint: `https://aonsoku-coordination.realtvop.top`.
- Cloudflare active version `16fd8ee0` includes the stale fencing cleanup from
  `befea1a0`, applied through the dashboard editor. The local commits below have
  not been pushed; this was not a deployment of the complete local checkout.
- Offline tests disabled only the phone's Wi-Fi and mobile data. The computer
  stayed online. Phone networking and the temporary charging stay-awake setting
  were restored afterward. Both players were left paused.

## Confirmed on devices

| Scenario | Evidence and result |
| --- | --- |
| Online handoff in both directions | Native playback resumed at the transferred position; the source automatically paused. The renderer updated its song and queue. |
| Repeated return to the same device/session | After the Workers fencing fix, subsequent snapshots from the returning owner were accepted without pausing that owner again. |
| Completion while player and fullscreen surfaces coexist | After the subscription fix, a successful handoff no longer produced the previous false 15-second timeout. |
| Offline handoff | Desktop displayed **Continue from offline playback** and accepted the phone's retained snapshot. On the final run it resumed **海辺の電話ボックス**, context index 1, with all 39 songs and nonzero progress; a native read showed 163.46 seconds. No rapid replacement-driven skipping recurred. The following track advanced normally later. |
| Background reconnection and fencing | Phone log recorded reconnect at 14:18:58 and `session_superseded` at 14:19:13. Android MediaSession then reported **PAUSED**, position 93.075 seconds on **NONSENSE**. No manual pause was issued during this check. The phone had naturally advanced while offline. |
| Fullscreen remote controls | Phone fullscreen displayed the desktop's title/progress; pause and resume affected desktop playback. Next changed the desktop to **SPEED OF SPICE**, and the phone projection followed. A later native desktop read confirmed paused playback at 43.32 seconds. |
| Current manual queue item handed off and returned | Desktop had `isInUserQueue=true`, one manual item, context index 3 and 39 context songs. After transfer, Android persistence retained those fields and nonzero progress. Returning to desktop retained the manual item and index; the phone automatically paused. After progression, desktop had an empty manual queue, one played manual-history item, and resumed the context queue. |

## Fix commits

| Commit | Change |
| --- | --- |
| `936fa9fd` | Restore native handoff queues and reconnect clients; repair Android projection without a local source. |
| `f8869e9f` | Refresh renderer queues after native handoff. |
| `ac71aa6e` | Keep prepared candidate playback paused. |
| `f896af3d` | Pass restored progress in the libmpv source-load command. |
| `375f863b` | Hydrate handoff state from the actual native audio contract. |
| `befea1a0` | Clear obsolete fencing when an owner returns. |
| `c20ecc70` | Release closed Android sockets before reconnecting. |
| `df62239d` | Subscribe UI surfaces to handoff events independently of observer callbacks. |
| `84e1f561` | Ignore libmpv replacement stop events instead of advancing the queue. |

## Automated validation and boundaries

- Workers: 11 integration tests, type check and deployment dry-run passed for
  the fencing fix.
- Manager/native coordination/native queue controller: 48 focused tests passed
  for the UI subscription change.
- libmpv engine and desktop audio service: 78 tests passed for the final stop
  event fix, including rapid prepare/commit replacement and unchanged queue/sleep
  state after stop events.
- Android native unit tests, mobile bundle, Capacitor sync and debug APK build
  passed. The rebuilt APK is installed on Pixel 5.
- Electron production build passed after `84e1f561`; the final Electron-only
  change was also unit-tested and exercised through the running development app.
- Repository lint passed for the fix commits. Standalone web type checking is
  still blocked by baseline TS6305 missing Electron declaration outputs.
- Pixel 9 was not connected for this final retest. No iOS runtime test or iOS
  build was performed; the iOS prepare-paused change only had source/syntax
  validation.
- Reconnection uses retry backoff and is not immediate on restored networking.
  These checks do not prove indefinite background operation, process-killed
  recovery, shuffled/repeated queue parity, or every remote command.
- Further work was stopped at the user's request after committing this record.
