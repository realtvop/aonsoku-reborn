#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

#include <cstdarg>
#include <cstdio>

#include "system_media_session.h"

namespace {

NSString* ToNSString(const std::string& value) {
  return [NSString stringWithUTF8String:value.c_str()];
}

SystemMediaCommandHandler g_command_handler = nullptr;
void* g_command_context = nullptr;
bool g_remote_commands_registered = false;

// Artwork is fetched asynchronously from artwork_url. The downloaded image is
// cached per-URL so repeated nowPlayingInfo updates (play/pause/seek) do not
// re-download, and stale in-flight downloads are ignored when the URL changes.
NSImage* g_artwork_image = nil;
NSString* g_artwork_url = nil;

// Last published state, kept so an async artwork download completion can
// re-apply nowPlayingInfo with the artwork attached without needing the JS
// caller to re-issue an update.
SystemMediaSessionMetadata g_last_metadata;
SystemMediaSessionPlaybackState g_last_state = SystemMediaSessionPlaybackState::kStopped;
double g_last_position = 0;

void ApplyNowPlayingInfo();
void DownloadArtwork(NSString* url_string);

// Diagnostics for system media session command delivery. Written to stderr so
// they show up in `pnpm electron:dev` / the packaged app terminal and make it
// possible to see where the macOS -> JS command chain breaks.
void LogMediaSession(const char* format, ...) {
  va_list args;
  va_start(args, format);
  fprintf(stderr, "[aonsoku-media] ");
  vfprintf(stderr, format, args);
  fprintf(stderr, "\n");
  fflush(stderr);
  va_end(args);
}

const char* StateName(SystemMediaSessionPlaybackState state) {
  switch (state) {
    case SystemMediaSessionPlaybackState::kPlaying:
      return "playing";
    case SystemMediaSessionPlaybackState::kPaused:
      return "paused";
    case SystemMediaSessionPlaybackState::kStopped:
      return "stopped";
  }
  return "unknown";
}

void DispatchCommand(SystemMediaCommand command, double position = 0) {
  const char* name = "unknown";
  switch (command) {
    case SystemMediaCommand::kPlay: name = "play"; break;
    case SystemMediaCommand::kPause: name = "pause"; break;
    case SystemMediaCommand::kTogglePlayPause: name = "togglePlayPause"; break;
    case SystemMediaCommand::kNext: name = "next"; break;
    case SystemMediaCommand::kPrevious: name = "previous"; break;
    case SystemMediaCommand::kSeek: name = "seek"; break;
  }
  LogMediaSession("command fired: %s position=%.3f handler=%p", name, position,
                   (void*)g_command_handler);
  if (g_command_handler != nullptr) {
    g_command_handler(g_command_context, command, position);
  }
}

// Registers MPRemoteCommandCenter handlers so macOS treats this process as a
// "Now Playing" app. Without at least one registered remote command handler,
// MPNowPlayingInfoCenter updates are ignored by Control Center / Now Playing
// and media keys are not routed. This is the difference between the system
// media session "working" and being silently invisible on macOS.
void EnsureRemoteCommandCenter() {
  if (g_remote_commands_registered) return;
  g_remote_commands_registered = true;

  LogMediaSession("registering MPRemoteCommandCenter handlers");

  MPRemoteCommandCenter* center = [MPRemoteCommandCenter sharedCommandCenter];

  center.playCommand.enabled = YES;
  [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
      MPRemoteCommandEvent* _Nonnull) {
    DispatchCommand(SystemMediaCommand::kPlay);
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  center.pauseCommand.enabled = YES;
  [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
      MPRemoteCommandEvent* _Nonnull) {
    DispatchCommand(SystemMediaCommand::kPause);
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  center.togglePlayPauseCommand.enabled = YES;
  [center.togglePlayPauseCommand
      addTargetWithHandler:^MPRemoteCommandHandlerStatus(
          MPRemoteCommandEvent* _Nonnull) {
        DispatchCommand(SystemMediaCommand::kTogglePlayPause);
        return MPRemoteCommandHandlerStatusSuccess;
      }];

  center.nextTrackCommand.enabled = YES;
  [center.nextTrackCommand
      addTargetWithHandler:^MPRemoteCommandHandlerStatus(
          MPRemoteCommandEvent* _Nonnull) {
        DispatchCommand(SystemMediaCommand::kNext);
        return MPRemoteCommandHandlerStatusSuccess;
      }];

  center.previousTrackCommand.enabled = YES;
  [center.previousTrackCommand
      addTargetWithHandler:^MPRemoteCommandHandlerStatus(
          MPRemoteCommandEvent* _Nonnull) {
        DispatchCommand(SystemMediaCommand::kPrevious);
        return MPRemoteCommandHandlerStatusSuccess;
      }];

  center.changePlaybackPositionCommand.enabled = YES;
  [center.changePlaybackPositionCommand
      addTargetWithHandler:^MPRemoteCommandHandlerStatus(
          MPRemoteCommandEvent* _Nonnull event) {
        MPChangePlaybackPositionCommandEvent* position_event =
            (MPChangePlaybackPositionCommandEvent*)event;
        DispatchCommand(SystemMediaCommand::kSeek, position_event.positionTime);
        return MPRemoteCommandHandlerStatusSuccess;
      }];
}

void ApplyNowPlayingInfo() {
  @autoreleasepool {
    NSMutableDictionary<NSString*, id>* now_playing = [NSMutableDictionary dictionary];
    if (!g_last_metadata.title.empty()) {
      now_playing[MPMediaItemPropertyTitle] = ToNSString(g_last_metadata.title);
    }
    if (!g_last_metadata.artist.empty()) {
      now_playing[MPMediaItemPropertyArtist] = ToNSString(g_last_metadata.artist);
    }
    if (!g_last_metadata.album.empty()) {
      now_playing[MPMediaItemPropertyAlbumTitle] = ToNSString(g_last_metadata.album);
    }
    if (g_last_metadata.duration > 0) {
      now_playing[MPMediaItemPropertyPlaybackDuration] = @(g_last_metadata.duration);
    }
    now_playing[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(g_last_position);
    now_playing[MPNowPlayingInfoPropertyPlaybackRate] =
        @(g_last_state == SystemMediaSessionPlaybackState::kPlaying ? 1.0 : 0.0);

    if (g_artwork_image != nil) {
      NSImage* image = g_artwork_image;
      MPMediaItemArtwork* artwork =
          [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
                                           requestHandler:^NSImage* (CGSize size) {
                                             (void)size;
                                             return image;
                                           }];
      now_playing[MPMediaItemPropertyArtwork] = artwork;
    }

    MPNowPlayingInfoCenter* center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = now_playing;
    center.playbackState =
        g_last_state == SystemMediaSessionPlaybackState::kPlaying
            ? MPNowPlayingPlaybackStatePlaying
            : (g_last_state == SystemMediaSessionPlaybackState::kPaused
                   ? MPNowPlayingPlaybackStatePaused
                   : MPNowPlayingPlaybackStateStopped);
  }
}

void DownloadArtwork(NSString* url_string) {
  NSURL* url = [NSURL URLWithString:url_string];
  if (url == nil) return;

  NSURLSessionTask* task = [[NSURLSession sharedSession]
      dataTaskWithURL:url
    completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        (void)response;
        if (error != nil || data == nil) return;

        NSImage* image = [[NSImage alloc] initWithData:data];
        if (image == nil) return;

        // Re-apply on the main thread, but only if this download is still the
        // current artwork (the song may have changed while we were fetching).
        dispatch_async(dispatch_get_main_queue(), ^{
          if (![url_string isEqualToString:g_artwork_url]) return;
          g_artwork_image = image;
          ApplyNowPlayingInfo();
        });
    }];
  [task resume];
}

}  // namespace

void SetSystemMediaCommandHandler(SystemMediaCommandHandler handler,
                                  void* context) {
  g_command_handler = handler;
  g_command_context = context;
}

void ClearSystemMediaCommandHandler(void* context) {
  if (g_command_context == context) {
    g_command_handler = nullptr;
    g_command_context = nullptr;
  }
}

void UpdateSystemMediaSession(const SystemMediaSessionMetadata& metadata,
                              SystemMediaSessionPlaybackState state,
                              double position) {
  @autoreleasepool {
    EnsureRemoteCommandCenter();

    LogMediaSession(
        "update: state=%s position=%.3f duration=%.3f title=\"%s\" artwork=\"%s\"",
        StateName(state), position, metadata.duration,
        metadata.title.c_str(),
        metadata.artwork_url.empty() ? "" : metadata.artwork_url.c_str());

    g_last_metadata = metadata;
    g_last_state = state;
    g_last_position = position;

    NSString* new_url = nil;
    if (!metadata.artwork_url.empty()) {
      new_url = ToNSString(metadata.artwork_url);
    }

    if (new_url == nil) {
      g_artwork_url = nil;
      g_artwork_image = nil;
    } else if (![new_url isEqualToString:g_artwork_url]) {
      // URL changed: drop the stale image and fetch the new one. The nowPlayingInfo
      // applied below will omit artwork until the download completes, then
      // ApplyNowPlayingInfo() re-runs with the image attached.
      g_artwork_url = new_url;
      g_artwork_image = nil;
      DownloadArtwork(new_url);
    }

    ApplyNowPlayingInfo();
  }
}

void ClearSystemMediaSession() {
  @autoreleasepool {
    g_artwork_url = nil;
    g_artwork_image = nil;
    g_last_metadata = SystemMediaSessionMetadata{};
    g_last_state = SystemMediaSessionPlaybackState::kStopped;
    g_last_position = 0;

    MPNowPlayingInfoCenter* center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = nil;
    center.playbackState = MPNowPlayingPlaybackStateStopped;
  }
}