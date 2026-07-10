#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

#include "system_media_session.h"

namespace {

NSString* ToNSString(const std::string& value) {
  return [NSString stringWithUTF8String:value.c_str()];
}

SystemMediaCommandHandler g_command_handler = nullptr;
void* g_command_context = nullptr;
bool g_remote_commands_registered = false;

void DispatchCommand(SystemMediaCommand command, double position = 0) {
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

    NSMutableDictionary<NSString*, id>* now_playing = [NSMutableDictionary dictionary];
    now_playing[MPMediaItemPropertyTitle] = ToNSString(metadata.title);

    if (!metadata.artist.empty()) {
      now_playing[MPMediaItemPropertyArtist] = ToNSString(metadata.artist);
    }
    if (!metadata.album.empty()) {
      now_playing[MPMediaItemPropertyAlbumTitle] = ToNSString(metadata.album);
    }
    if (metadata.duration > 0) {
      now_playing[MPMediaItemPropertyPlaybackDuration] = @(metadata.duration);
    }
    now_playing[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(position);
    now_playing[MPNowPlayingInfoPropertyPlaybackRate] =
        @(state == SystemMediaSessionPlaybackState::kPlaying ? 1.0 : 0.0);

    MPNowPlayingInfoCenter* center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = now_playing;
    center.playbackState =
        state == SystemMediaSessionPlaybackState::kPlaying
            ? MPNowPlayingPlaybackStatePlaying
            : (state == SystemMediaSessionPlaybackState::kPaused
                   ? MPNowPlayingPlaybackStatePaused
                   : MPNowPlayingPlaybackStateStopped);
  }
}

void ClearSystemMediaSession() {
  @autoreleasepool {
    MPNowPlayingInfoCenter* center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = nil;
    center.playbackState = MPNowPlayingPlaybackStateStopped;
  }
}