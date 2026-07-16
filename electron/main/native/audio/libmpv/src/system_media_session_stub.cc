#include "system_media_session.h"

// Command reception is not available on unsupported platforms.
void SetSystemMediaCommandHandler(SystemMediaCommandHandler, void*) {}

void ClearSystemMediaCommandHandler(void* /*context*/) {}

void UpdateSystemMediaSession(const SystemMediaSessionMetadata&,
                              SystemMediaSessionPlaybackState, double) {}

void ClearSystemMediaSession() {}