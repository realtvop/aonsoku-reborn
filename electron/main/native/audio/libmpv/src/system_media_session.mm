#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

#include "system_media_session.h"

namespace {

NSString* ToNSString(const std::string& value) {
  return [NSString stringWithUTF8String:value.c_str()];
}

}  // namespace

void UpdateSystemMediaSession(const SystemMediaSessionMetadata& metadata,
                              SystemMediaSessionPlaybackState state,
                              double position) {
  @autoreleasepool {
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
            : MPNowPlayingPlaybackStatePaused;
  }
}

void ClearSystemMediaSession() {
  @autoreleasepool {
    MPNowPlayingInfoCenter* center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = nil;
    center.playbackState = MPNowPlayingPlaybackStateStopped;
  }
}
