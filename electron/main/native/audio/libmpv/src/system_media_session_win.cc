#include "system_media_session.h"

#include <atomic>
#include <mutex>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>

namespace {

using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Media;

std::mutex g_mutex;
SystemMediaTransportControls g_controls{nullptr};
bool g_initialized = false;
winrt::event_token g_button_token{};
bool g_button_registered = false;

// The command handler/context are read from the SMTC ButtonPressed callback,
// which can fire on the system UI thread. Keeping them lock-free (atomics)
// avoids a deadlock when ClearSystemMediaSession revokes the ButtonPressed
// handler while holding g_mutex: the in-flight callback never contends on
// g_mutex, so revocation cannot block on a callback that needs the lock.
std::atomic<SystemMediaCommandHandler> g_command_handler{nullptr};
std::atomic<void*> g_command_context{nullptr};

void DispatchCommand(SystemMediaCommand command, double position) {
  auto handler = g_command_handler.load(std::memory_order_acquire);
  auto context = g_command_context.load(std::memory_order_acquire);
  if (handler != nullptr) handler(context, command, position);
}

SystemMediaCommand ButtonToCommand(MediaTransportControlsButton button) {
  switch (button) {
    case MediaTransportControlsButton::Play:
      return SystemMediaCommand::kPlay;
    case MediaTransportControlsButton::Pause:
      return SystemMediaCommand::kPause;
    case MediaTransportControlsButton::Next:
      return SystemMediaCommand::kNext;
    case MediaTransportControlsButton::Previous:
      return SystemMediaCommand::kPrevious;
    default:
      return SystemMediaCommand::kTogglePlayPause;
  }
}

bool IsHandledButton(MediaTransportControlsButton button) {
  switch (button) {
    case MediaTransportControlsButton::Play:
    case MediaTransportControlsButton::Pause:
    case MediaTransportControlsButton::Next:
    case MediaTransportControlsButton::Previous:
      return true;
    default:
      return false;
  }
}

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

void SetSystemMediaCommandHandler(SystemMediaCommandHandler handler,
                                  void* context) {
  g_command_context.store(context, std::memory_order_release);
  g_command_handler.store(handler, std::memory_order_release);
}

void ClearSystemMediaCommandHandler(void* context) {
  void* current = g_command_context.load(std::memory_order_acquire);
  if (current != context) return;
  g_command_handler.store(nullptr, std::memory_order_release);
  g_command_context.store(nullptr, std::memory_order_release);
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
    g_controls.IsStopEnabled(false);
    g_controls.IsNextEnabled(true);
    g_controls.IsPreviousEnabled(true);
  } catch (const hresult_error&) {
    g_controls = nullptr;
  }

  if (g_controls != nullptr && !g_button_registered) {
    g_button_token = g_controls.ButtonPressed(
        [](SystemMediaTransportControls /*sender*/,
           MediaTransportControlsButtonPressedEventArgs args) {
          MediaTransportControlsButton button = args.Button();
          if (!IsHandledButton(button)) return;
          DispatchCommand(ButtonToCommand(button), 0);
        });
    g_button_registered = true;
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

  if (g_button_registered) {
    try {
      g_controls.ButtonPressed(g_button_token);
    } catch (const hresult_error&) {
      // The controls may already be detached; ignore revoke failures.
    }
    g_button_registered = false;
  }

  g_controls.DisplayUpdater().ClearAll();
  g_controls.PlaybackStatus(MediaPlaybackStatus::Closed);
  g_controls.IsEnabled(false);
  g_controls = nullptr;
  g_initialized = false;
}
