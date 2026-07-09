#include "system_media_session.h"

#include <mutex>

#include <winrt/Windows.Media.h>

namespace {

using namespace winrt;
using namespace Windows::Media;

std::mutex g_mutex;
SystemMediaTransportControls g_controls{nullptr};
bool g_initialized = false;

MediaPlaybackStatus ToPlaybackStatus(SystemMediaSessionPlaybackState state) {
  switch (state) {
    case SystemMediaSessionPlaybackState::kPlaying:
      return MediaPlaybackStatus::Playing;
    case SystemMediaSessionPlaybackState::kPaused:
      return MediaPlaybackStatus::Paused;
    case SystemMediaSessionPlaybackState::kStopped:
      return MediaPlaybackStatus::Stopped;
  }

  return MediaPlaybackStatus::Closed;
}

bool EnsureControls() {
  if (g_initialized) return g_controls != nullptr;

  g_initialized = true;
  try {
    init_apartment(apartment_type::multi_threaded);
  } catch (const hresult_error&) {
    // The Electron main process can already be initialized for COM.
  }

  try {
    g_controls = SystemMediaTransportControls::GetForCurrentView();
    g_controls.IsEnabled(true);
    g_controls.IsPlayEnabled(true);
    g_controls.IsPauseEnabled(true);
    g_controls.IsStopEnabled(true);
  } catch (const hresult_error&) {
    g_controls = nullptr;
  }

  return g_controls != nullptr;
}

}  // namespace

void UpdateSystemMediaSession(const SystemMediaSessionMetadata& metadata,
                              SystemMediaSessionPlaybackState state,
                              double position) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!EnsureControls()) return;

  auto updater = g_controls.DisplayUpdater();
  updater.Type(MediaPlaybackType::Music);
  auto music = updater.MusicProperties();
  music.Title(to_hstring(metadata.title));
  music.Artist(to_hstring(metadata.artist));
  music.AlbumTitle(to_hstring(metadata.album));
  updater.Update();

  SystemMediaTransportControlsTimelineProperties timeline;
  timeline.Position(Windows::Foundation::TimeSpan{
      static_cast<int64_t>(position * 10'000'000)});
  timeline.StartTime(Windows::Foundation::TimeSpan{0});
  timeline.EndTime(Windows::Foundation::TimeSpan{
      static_cast<int64_t>(metadata.duration * 10'000'000)});
  g_controls.UpdateTimelineProperties(timeline);
  g_controls.PlaybackStatus(ToPlaybackStatus(state));
}

void ClearSystemMediaSession() {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_controls) return;

  g_controls.DisplayUpdater().ClearAll();
  g_controls.PlaybackStatus(MediaPlaybackStatus::Closed);
  g_controls.IsEnabled(false);
  g_controls = nullptr;
  g_initialized = false;
}
