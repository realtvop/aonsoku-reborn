#pragma once

#include <string>

struct SystemMediaSessionMetadata {
  std::string title;
  std::string artist;
  std::string album;
  std::string artwork_url;
  double duration = 0;
};

enum class SystemMediaSessionPlaybackState {
  kPlaying,
  kPaused,
  kStopped,
};

enum class SystemMediaCommand {
  kPlay,
  kPause,
  kTogglePlayPause,
  kNext,
  kPrevious,
  kSeek,
};

// Handler invoked by the platform when the system issues a media command
// (media keys, Control Center / Now Playing controls, lock screen, etc.).
// `context` is the opaque pointer registered with SetSystemMediaCommandHandler.
// `position` is only meaningful for kSeek and is expressed in seconds.
using SystemMediaCommandHandler = void (*)(void* context,
                                           SystemMediaCommand command,
                                           double position);

// Registers the active command handler. The platform implementation routes
// system media controls to this handler. Pass nullptr to detach.
void SetSystemMediaCommandHandler(SystemMediaCommandHandler handler,
                                  void* context);

// Detaches the handler only if its registered context matches `context`.
// Used during player teardown to avoid clearing a handler that a newer player
// instance has already claimed.
void ClearSystemMediaCommandHandler(void* context);

void UpdateSystemMediaSession(const SystemMediaSessionMetadata& metadata,
                              SystemMediaSessionPlaybackState state,
                              double position);
void ClearSystemMediaSession();