# Native Android app parity

The native app in `android/` replaces the Capacitor Android host. It was built
to the behavior of the web app as it ran inside that host, page by page and
setting by setting. This note records where the native app deliberately
differs, what it adds, and what can only be checked on a device. The JVM smoke
journeys in `android/app/src/test/.../smoke/AppSmokeTest.kt` exercise every
screen listed below against fake servers.

## Covered

- **Sign-in**: primary and fallback server URLs, protocol check, sign-out, and
  the server settings page.
- **Home**: carousel, pinned items, album sections, and the devices playing
  elsewhere.
- **Library**: playlists, albums with every filter of the web app (by name,
  artist, genre, or year; starred, most played, recently added, recently
  played, random; an artist's discography; search), artists, songs (an
  artist's tracks, search), favorites, and radios.
- **Search** and the **detail pages** for albums, artists, and playlists.
- **Menus**: play, play next, add last, pin, like, download and remove
  download, add to playlist, playlist and radio forms, delete confirmations,
  go to artist or album, and song info.
- **Player**: mini player; full player with the playing view, lyrics, the
  per-song lyrics page, and the queue; sleep timer, color intensity, like,
  shuffle, repeat, volume, and ReplayGain.
- **Lyrics**: source priority, LRCLIB, a custom lyrics server, per-song
  choices and offsets, translations and romanization, and dots during long
  pauses.
- **Queue**: history, manually queued songs, the context queue, reordering,
  removal, and confirmation before queued songs are replaced.
- **Offline**: downloads of songs, albums, playlists, and artists; smart
  downloads; quotas; the cache manager; sync status.
- **Settings**: server, appearance, language, player and audio, content,
  offline experience, cross-device, privacy and security.
- **Cross-device**: registration, the device list, remote control, and
  handoff in both directions.

## Deliberate differences

- **Signing out** also clears the library, the downloads, and the images. The
  web app keeps them, and a different server could then show the previous
  library.
- **Clearing a cache** asks first.
- **Downloads** run in the app process without a foreground service. They stop
  with the process, and the user's own downloads resume at the next start.
- **Library caching** cannot be switched off: every list reads the Room
  library.
- **Audio files the Capacitor app left without an index row** are adopted as
  explicit downloads, the one kind that is never removed automatically.
- **Settings without meaning on a phone** are left out: automatic fullscreen,
  pointer cursors, and browser picture-in-picture.
- **History sync** over the coordination server is not implemented. The web
  app never calls it either.
- **The smart-download rule for favorite playlists** depends on the server
  reporting starred playlists.
- **Language** follows the app's own setting. Android's per-app language
  picker is not connected to it.
- **Release builds** are shrunk with R8, so a release build can behave
  differently from a debug build where reflection is involved.

These match the web app on purpose, although they may look like gaps: while
another device is controlled, queue rows cannot be reordered or removed and
radios do not start; signing out keeps the device registered for
cross-device use.

## Native additions

- Tapping the playback notification or the system's media controls opens the
  full player.
- The full player follows the predictive back gesture.
- While a volume bar of this device's playback is on screen, the volume keys
  change the volume without the system's volume panel. The web app asks its
  native host for the same while its full player is open.
- The mini player and the full player say which device is being controlled.
- Screen readers move rows of the queue and of the lyric source list with
  "Move up" and "Move down" actions.

## To check on a device

- Installing over the Capacitor build keeps the sign-in, imports the
  settings, and keeps the library and the downloads.
- Background playback, the notification and lock screen controls, Bluetooth
  and headset buttons, audio focus, and the sleep timer.
- The notification tap, the volume keys in the player, and predictive back
  (Android 14 and later).
- Scrolling and lyric blur performance (blur needs Android 12 or later).
- Downloads and smart downloads against a real server, on Wi-Fi and on a
  metered connection.
- Cross-device playback with a coordination server and a second client.
- A release build, which is shrunk with R8.
