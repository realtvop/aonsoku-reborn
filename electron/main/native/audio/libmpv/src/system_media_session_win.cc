#include "system_media_session.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <mutex>
#include <string_view>

#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

namespace {

using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Media;

std::mutex g_mutex;
SystemMediaTransportControls g_controls{nullptr};
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

SystemMediaCommand ButtonToCommand(SystemMediaTransportControlsButton button) {
  switch (button) {
    case SystemMediaTransportControlsButton::Play:
      return SystemMediaCommand::kPlay;
    case SystemMediaTransportControlsButton::Pause:
      return SystemMediaCommand::kPause;
    case SystemMediaTransportControlsButton::Next:
      return SystemMediaCommand::kNext;
    case SystemMediaTransportControlsButton::Previous:
      return SystemMediaCommand::kPrevious;
    default:
      return SystemMediaCommand::kTogglePlayPause;
  }
}

bool IsHandledButton(SystemMediaTransportControlsButton button) {
  switch (button) {
    case SystemMediaTransportControlsButton::Play:
    case SystemMediaTransportControlsButton::Pause:
    case SystemMediaTransportControlsButton::Next:
    case SystemMediaTransportControlsButton::Previous:
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

struct WindowSearchContext {
  DWORD process_id;
  HWND best_window = nullptr;
  int best_score = -1;
};

BOOL CALLBACK FindProcessWindow(HWND window, LPARAM parameter) {
  auto* context = reinterpret_cast<WindowSearchContext*>(parameter);
  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id != context->process_id ||
      GetAncestor(window, GA_ROOT) != window) {
    return TRUE;
  }

  // Prefer Electron's real BrowserWindow over Chromium helper, console, and
  // tool windows, while retaining a hidden top-level window as a startup
  // fallback. GetForWindow validates that the selected HWND belongs to this
  // process.
  int score = 0;
  if (IsWindowVisible(window)) score += 100;
  if (GetWindow(window, GW_OWNER) == nullptr) score += 40;

  const auto extended_style =
      static_cast<DWORD>(GetWindowLongPtrW(window, GWL_EXSTYLE));
  if ((extended_style & WS_EX_TOOLWINDOW) == 0) score += 20;
  if ((extended_style & WS_EX_APPWINDOW) != 0) score += 10;

  wchar_t class_name[256]{};
  if (GetClassNameW(window, class_name,
                    static_cast<int>(sizeof(class_name) /
                                     sizeof(class_name[0]))) > 0) {
    constexpr std::wstring_view kElectronWindowPrefix = L"Chrome_WidgetWin_";
    const std::wstring_view window_class(class_name);
    if (window_class.compare(0, kElectronWindowPrefix.size(),
                             kElectronWindowPrefix) == 0) {
      score += 200;
    }
  }

  if (score > context->best_score) {
    context->best_score = score;
    context->best_window = window;
  }
  return TRUE;
}

HWND FindTopLevelProcessWindow() {
  WindowSearchContext context{GetCurrentProcessId()};
  if (!EnumWindows(FindProcessWindow,
                   reinterpret_cast<LPARAM>(&context))) {
    return nullptr;
  }
  return context.best_window;
}

bool EnsureApartment() {
  thread_local bool apartment_ready = false;
  if (apartment_ready) return true;

  try {
    init_apartment(apartment_type::multi_threaded);
    apartment_ready = true;
  } catch (const hresult_error& error) {
    // Electron may already have initialized this thread as an STA. WinRT is
    // still usable in that case; other COM failures should be retried later.
    if (error.code() != RPC_E_CHANGED_MODE) return false;
    apartment_ready = true;
  } catch (...) {
    return false;
  }
  return true;
}

void ResetControls() noexcept {
  if (g_controls != nullptr && g_button_registered) {
    try {
      g_controls.ButtonPressed(g_button_token);
    } catch (...) {
      // The window or controls may already be detached.
    }
  }
  g_button_registered = false;
  g_button_token = {};
  g_controls = nullptr;
}

bool EnsureControls() {
  if (g_controls != nullptr) return true;
  if (!EnsureApartment()) return false;

  HWND window = FindTopLevelProcessWindow();
  if (window == nullptr) return false;

  try {
    auto interop =
        get_activation_factory<SystemMediaTransportControls,
                               ISystemMediaTransportControlsInterop>();
    SystemMediaTransportControls controls{nullptr};
    check_hresult(interop->GetForWindow(
        window, guid_of<SystemMediaTransportControls>(), put_abi(controls)));

    controls.IsEnabled(true);
    controls.IsPlayEnabled(false);
    controls.IsPauseEnabled(false);
    controls.IsStopEnabled(false);
    controls.IsNextEnabled(false);
    controls.IsPreviousEnabled(false);

    auto button_token = controls.ButtonPressed(
        [](SystemMediaTransportControls /*sender*/,
           SystemMediaTransportControlsButtonPressedEventArgs args) {
          try {
            SystemMediaTransportControlsButton button = args.Button();
            if (!IsHandledButton(button)) return;
            DispatchCommand(ButtonToCommand(button), 0);
          } catch (...) {
            // Never let a WinRT or handler exception cross the OS callback.
          }
        });
    g_controls = controls;
    g_button_token = button_token;
    g_button_registered = true;
  } catch (...) {
    ResetControls();
    return false;
  }

  return true;
}

int64_t SecondsToTicks(double seconds) {
  constexpr double kTicksPerSecond = 10'000'000.0;
  constexpr double kMaxSeconds =
      static_cast<double>(std::numeric_limits<int64_t>::max()) /
      kTicksPerSecond;
  if (!std::isfinite(seconds) || seconds <= 0) return 0;
  return static_cast<int64_t>(std::min(seconds, kMaxSeconds) *
                              kTicksPerSecond);
}

}  // namespace

// Declared in system_media_session.h and called from aonsoku_libmpv.cc (a
// separate translation unit), so these must have external linkage. They are
// intentionally defined OUTSIDE the anonymous namespace above; defining them
// inside it (internal linkage) would leave them undefined to the addon linker.
// They reference the anonymous-namespace atomics, which are visible here via
// the anonymous namespace's implicit using-directive.
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

void UpdateSystemMediaSession(const SystemMediaSessionMetadata& metadata,
                              SystemMediaSessionPlaybackState state,
                              double position) try {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!EnsureControls()) return;

  try {
    auto updater = g_controls.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);
    auto music = updater.MusicProperties();
    music.Title(to_hstring(metadata.title));
    music.Artist(to_hstring(metadata.artist));
    music.AlbumTitle(to_hstring(metadata.album));
    if (!metadata.artwork_url.empty()) {
      try {
        auto uri = Uri(to_hstring(metadata.artwork_url));
        updater.Thumbnail(
            Windows::Storage::Streams::RandomAccessStreamReference::CreateFromUri(
                uri));
      } catch (...) {
        // Malformed or unavailable artwork must not prevent transport updates.
        updater.Thumbnail(nullptr);
      }
    } else {
      updater.Thumbnail(nullptr);
    }
    updater.Update();

    const double duration =
        std::isfinite(metadata.duration) && metadata.duration > 0
            ? metadata.duration
            : 0;
    double bounded_position =
        std::max(std::isfinite(position) ? position : 0.0, 0.0);
    if (duration > 0) bounded_position = std::min(bounded_position, duration);
    SystemMediaTransportControlsTimelineProperties timeline;
    timeline.Position(
        Windows::Foundation::TimeSpan{SecondsToTicks(bounded_position)});
    timeline.StartTime(Windows::Foundation::TimeSpan{0});
    timeline.EndTime(
        Windows::Foundation::TimeSpan{SecondsToTicks(duration)});
    g_controls.UpdateTimelineProperties(timeline);

    const bool has_track = !metadata.title.empty() ||
                           !metadata.artist.empty() || duration > 0;
    g_controls.IsPlayEnabled(
        has_track && state != SystemMediaSessionPlaybackState::kPlaying);
    g_controls.IsPauseEnabled(
        has_track && state == SystemMediaSessionPlaybackState::kPlaying);
    // The native metadata contract does not expose queue boundaries. Keep
    // next/previous enabled while a track exists because both commands are
    // handled by the desktop queue service; play/pause can be exact here.
    g_controls.IsNextEnabled(has_track);
    g_controls.IsPreviousEnabled(has_track);
    g_controls.PlaybackStatus(ToPlaybackStatus(state));
  } catch (...) {
    // A destroyed BrowserWindow invalidates its SMTC instance. Drop it so the
    // next update can bind to the replacement top-level Electron window.
    ResetControls();
  }
} catch (...) {
  // This native boundary is called directly by N-API. Even an unexpected
  // mutex/standard-library failure must not unwind into JavaScript.
}

void ClearSystemMediaSession() try {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_controls) return;

  try {
    g_controls.DisplayUpdater().ClearAll();
  } catch (...) {
  }
  try {
    g_controls.PlaybackStatus(MediaPlaybackStatus::Closed);
  } catch (...) {
  }
  try {
    g_controls.IsPlayEnabled(false);
    g_controls.IsPauseEnabled(false);
    g_controls.IsNextEnabled(false);
    g_controls.IsPreviousEnabled(false);
    g_controls.IsEnabled(false);
  } catch (...) {
  }
  ResetControls();
} catch (...) {
  // Never unwind a native clear failure through N-API teardown.
}
