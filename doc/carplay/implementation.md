# Native CarPlay ownership

CarPlay extends the native SwiftUI app through AonsokuKit. Playback remains
owned by the existing `AudioService`.

- `CarPlaySceneDelegate` owns each display's template controller.
- `CarPlayTemplateController` uses typed audio events and the same audio service
  as the phone. It preserves row identity and system list-capacity pagination.
- `CarPlayLibraryProvider` uses GRDB repositories, native HTTP and the existing
  fenced image cache. It checks account identity after asynchronous reads.
- `AudioService` serializes CarPlay queue mutations with phone and coordination
  commands. Generation checks precede application; queue entries carry revisions
  and occurrence indices. The shared service records recent plays and completed
  download metadata for immediate native library reads.
- Credential/library notifications refresh CarPlay content. Credential changes
  cancel pending selections and invalidate visible rows. Main's account/session
  cleanup continues to own playback and library reset.

`CarPlayLibraryTests` covers collection paging, full album/playlist context,
duplicates, favorites/history, cancellation, account changes, network failures,
and downloaded-file integrity. `CarPlayPlaybackTests` covers native template
construction, queue occurrences/revisions, pagination and exactly-once cancelled
selection completion. Fixtures use temporary databases and local audio without
real server/device or Keychain credentials.
