# CarPlay

Aonsoku's native iOS app exposes Home, Library and Downloaded through Apple's
CarPlay list templates. Now Playing uses the system template, media information
and remote commands. CarPlay and SwiftUI share `AppServices.shared.audio`;
connecting a display never creates a second player or coordination device.

`ios/Aonsoku/Resources/CarPlaySceneDelegate.swift` connects the scene to
`ios/AonsokuKit/Sources/AonsokuKit/CarPlay/CarPlayTemplateController.swift`.
The provider reads the existing GRDB library, native networking and cover cache.
The main SwiftUI app owns phone navigation; there is no WKWebView dependency.

Library and queue pages fill `CPListTemplate.maximumItemCount`, including their
navigation rows. Page history stores actual offsets. Recent, favorites and
downloaded playback uses the displayed page; albums and playlists retain their
full context and duplicate occurrences. Downloads must have matching completion
metadata, an existing file and the indexed byte size.

Unchanged logical rows reuse `CPListItem` identities across refreshes, including
occurrence indices for duplicate songs. Queue commands carry the occurrence and
queue revision; stale rows fail without selecting a different song. A library
selection has a 15-second preparation deadline. Cancellation completes the row
immediately, and generation checks reject late work before queue application.
Remote-control projection disables CarPlay playback actions.

The scene manifest includes the CarPlay role alongside SwiftUI's phone scene.
`Aonsoku/Resources/CarPlay.entitlements` is the default signing entitlement.
Device builds need the CarPlay audio capability and a matching provisioning
profile. To build without that device capability, set
`AONSOKU_ENTITLEMENTS=Aonsoku/Resources/App.entitlements`.

Run `bash scripts/test-ios-native.sh` on macOS with Xcode and an available iPhone
Simulator. CarPlay library, Apple template, duplicate/stale queue, pagination and
cancellation tests execute against the actual AonsokuKit target with temporary
fixtures. The compatibility commands `node scripts/ios/test-carplay-library.mjs`
and `node scripts/ios/test-carplay-simulator.mjs` run that same native suite.
No physical device or real server is required. A vehicle connection and its
audio-route behavior still require manual validation.
