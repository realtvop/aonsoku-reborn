#include "system_media_session.h"

#include <dbus/dbus.h>

#include <chrono>
#include <cstdio>

// Exercise the actual MPRIS implementation without libmpv or a desktop.
// A separate connection verifies that the dispatch thread sends queued signals.
int main() {
  dbus_threads_init_default();
  DBusError error;
  dbus_error_init(&error);
  DBusConnection* observer = dbus_bus_get_private(DBUS_BUS_SESSION, &error);
  if (observer == nullptr) {
    std::fprintf(stderr, "Cannot connect MPRIS observer: %s\n", error.message);
    dbus_error_free(&error);
    return 1;
  }
  dbus_connection_set_exit_on_disconnect(observer, FALSE);
  dbus_bus_add_match(observer,
      "type='signal',interface='org.freedesktop.DBus.Properties',"
      "member='PropertiesChanged',path='/org/mpris/MediaPlayer2'", &error);
  if (dbus_error_is_set(&error)) {
    std::fprintf(stderr, "Cannot observe MPRIS signals: %s\n", error.message);
    dbus_error_free(&error);
    dbus_connection_close(observer);
    dbus_connection_unref(observer);
    return 1;
  }
  dbus_connection_flush(observer);

  SystemMediaSessionMetadata metadata;
  metadata.title = "Aonsoku MPRIS smoke test";
  metadata.duration = 2;
  for (int index = 0; index < 100; ++index) {
    UpdateSystemMediaSession(metadata, SystemMediaSessionPlaybackState::kPaused,
                             index / 100.0);
  }

  bool received = false;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (!received && std::chrono::steady_clock::now() < deadline) {
    dbus_connection_read_write(observer, 100);
    while (DBusMessage* message = dbus_connection_pop_message(observer)) {
      received |= dbus_message_is_signal(message,
          "org.freedesktop.DBus.Properties", "PropertiesChanged");
      dbus_message_unref(message);
    }
  }

  ClearSystemMediaSession();
  dbus_connection_close(observer);
  dbus_connection_unref(observer);
  if (!received) {
    std::fprintf(stderr, "MPRIS dispatch did not deliver queued state changes.\n");
    return 1;
  }
  std::puts("MPRIS: 100 updates, signal delivery and shutdown passed.");
  return 0;
}
