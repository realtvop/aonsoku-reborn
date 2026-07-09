#pragma once

#include <string>

struct SystemMediaSessionMetadata {
  std::string title;
  std::string artist;
  std::string album;
  double duration = 0;
};

enum class SystemMediaSessionPlaybackState {
  kPlaying,
  kPaused,
  kStopped,
};

void UpdateSystemMediaSession(const SystemMediaSessionMetadata& metadata,
                              SystemMediaSessionPlaybackState state,
                              double position);
void ClearSystemMediaSession();
