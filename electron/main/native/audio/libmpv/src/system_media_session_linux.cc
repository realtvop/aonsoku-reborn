#include "system_media_session.h"

#include <dbus/dbus.h>

#include <atomic>
#include <cmath>
#include <mutex>
#include <string>
#include <thread>

namespace {

constexpr char kBusName[] = "org.mpris.MediaPlayer2.aonsoku";
constexpr char kObjectPath[] = "/org/mpris/MediaPlayer2";
constexpr char kPropertiesInterface[] = "org.freedesktop.DBus.Properties";
constexpr char kPlayerInterface[] = "org.mpris.MediaPlayer2.Player";

struct MprisState {
  std::mutex mutex;
  DBusConnection* connection = nullptr;
  std::thread dispatch_thread;
  std::atomic_bool running{false};
  bool initialized = false;
  SystemMediaSessionMetadata metadata;
  SystemMediaSessionPlaybackState playback_state =
      SystemMediaSessionPlaybackState::kStopped;
  double position = 0;
};

MprisState g_state;

// Command reception (MPRIS method call routing) is not yet wired on Linux;
// the D-Bus registration is display-only for now. The handler is stored so the
// addon API stays uniform across platforms.
SystemMediaCommandHandler g_command_handler = nullptr;
void* g_command_context = nullptr;

void SetSystemMediaCommandHandler(SystemMediaCommandHandler handler,
                                  void* context) {
  std::lock_guard<std::mutex> lock(g_state.mutex);
  g_command_handler = handler;
  g_command_context = context;
}

void ClearSystemMediaCommandHandler(void* context) {
  std::lock_guard<std::mutex> lock(g_state.mutex);
  if (g_command_context == context) {
    g_command_handler = nullptr;
    g_command_context = nullptr;
  }
}

const char* PlaybackStatus(SystemMediaSessionPlaybackState state) {
  switch (state) {
    case SystemMediaSessionPlaybackState::kPlaying:
      return "Playing";
    case SystemMediaSessionPlaybackState::kPaused:
      return "Paused";
    case SystemMediaSessionPlaybackState::kStopped:
      return "Stopped";
  }

  return "Stopped";
}

void AppendStringVariant(DBusMessageIter* dictionary, const char* key,
                         const std::string& value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  const char* text = value.c_str();
  dbus_message_iter_open_container(dictionary, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant);
  dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &text);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dictionary, &entry);
}

void AppendBoolVariant(DBusMessageIter* dictionary, const char* key,
                       bool value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  dbus_bool_t dbus_value = value ? TRUE : FALSE;
  dbus_message_iter_open_container(dictionary, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "b", &variant);
  dbus_message_iter_append_basic(&variant, DBUS_TYPE_BOOLEAN, &dbus_value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dictionary, &entry);
}

void AppendInt64Variant(DBusMessageIter* dictionary, const char* key,
                        int64_t value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  dbus_message_iter_open_container(dictionary, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "x", &variant);
  dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT64, &value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dictionary, &entry);
}

void AppendObjectPathVariant(DBusMessageIter* dictionary, const char* key,
                             const char* value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  dbus_message_iter_open_container(dictionary, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "o", &variant);
  dbus_message_iter_append_basic(&variant, DBUS_TYPE_OBJECT_PATH, &value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dictionary, &entry);
}

void AppendStringArrayVariant(DBusMessageIter* dictionary, const char* key,
                              const std::string& value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  DBusMessageIter array;
  const char* artist = value.c_str();
  dbus_message_iter_open_container(dictionary, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "as", &variant);
  dbus_message_iter_open_container(&variant, DBUS_TYPE_ARRAY, "s", &array);
  if (!value.empty()) {
    dbus_message_iter_append_basic(&array, DBUS_TYPE_STRING, &artist);
  }
  dbus_message_iter_close_container(&variant, &array);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dictionary, &entry);
}

void AppendMetadata(DBusMessageIter* dictionary,
                    const SystemMediaSessionMetadata& metadata) {
  AppendObjectPathVariant(dictionary, "mpris:trackid", "/org/mpris/MediaPlayer2/track/active");
  AppendStringVariant(dictionary, "xesam:title", metadata.title);
  AppendStringArrayVariant(dictionary, "xesam:artist", metadata.artist);
  AppendStringVariant(dictionary, "xesam:album", metadata.album);
  if (!metadata.artwork_url.empty()) {
    AppendStringVariant(dictionary, "mpris:artUrl", metadata.artwork_url);
  }
  if (metadata.duration > 0) {
    AppendInt64Variant(dictionary, "mpris:length",
                       static_cast<int64_t>(metadata.duration * 1'000'000));
  }
}

void AppendPlayerPropertiesFromState(DBusMessageIter* dictionary) {
  AppendStringVariant(dictionary, "PlaybackStatus",
                      PlaybackStatus(g_state.playback_state));
  AppendMetadata(dictionary, g_state.metadata);
  AppendInt64Variant(dictionary, "Position",
                     static_cast<int64_t>(g_state.position * 1'000'000));
  AppendBoolVariant(dictionary, "CanControl", false);
  AppendBoolVariant(dictionary, "CanPlay", false);
  AppendBoolVariant(dictionary, "CanPause", false);
  AppendBoolVariant(dictionary, "CanGoNext", false);
  AppendBoolVariant(dictionary, "CanGoPrevious", false);
}

void AppendPlayerProperties(DBusMessageIter* dictionary) {
  std::lock_guard<std::mutex> lock(g_state.mutex);
  AppendPlayerPropertiesFromState(dictionary);
}

DBusHandlerResult HandleMessage(DBusConnection* connection, DBusMessage* message,
                                void*) {
  if (dbus_message_is_method_call(message, "org.freedesktop.DBus.Introspectable",
                                  "Introspect")) {
    static const char kIntrospection[] =
        "<node>"
        "<interface name='org.mpris.MediaPlayer2'/>"
        "<interface name='org.mpris.MediaPlayer2.Player'>"
        "<property name='PlaybackStatus' type='s' access='read'/>"
        "<property name='Metadata' type='a{sv}' access='read'/>"
        "</interface>"
        "<interface name='org.freedesktop.DBus.Properties'/>"
        "</node>";
    DBusMessage* reply = dbus_message_new_method_return(message);
    if (!reply) return DBUS_HANDLER_RESULT_NEED_MEMORY;
    const char* xml = kIntrospection;
    dbus_message_append_args(reply, DBUS_TYPE_STRING, &xml, DBUS_TYPE_INVALID);
    dbus_connection_send(connection, reply, nullptr);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (!dbus_message_is_method_call(message, kPropertiesInterface, "GetAll")) {
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }

  const char* interface_name = nullptr;
  if (!dbus_message_get_args(message, nullptr, DBUS_TYPE_STRING, &interface_name,
                             DBUS_TYPE_INVALID) ||
      std::string(interface_name) != kPlayerInterface) {
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }

  DBusMessage* reply = dbus_message_new_method_return(message);
  if (!reply) return DBUS_HANDLER_RESULT_NEED_MEMORY;
  DBusMessageIter root;
  DBusMessageIter dictionary;
  dbus_message_iter_init_append(reply, &root);
  dbus_message_iter_open_container(&root, DBUS_TYPE_ARRAY, "{sv}", &dictionary);
  AppendPlayerProperties(&dictionary);
  dbus_message_iter_close_container(&root, &dictionary);
  dbus_connection_send(connection, reply, nullptr);
  dbus_message_unref(reply);
  return DBUS_HANDLER_RESULT_HANDLED;
}

DBusObjectPathVTable kObjectVTable = {nullptr, HandleMessage, nullptr, nullptr,
                                      nullptr, nullptr};

void DispatchLoop() {
  while (g_state.running.load()) {
    DBusConnection* connection = nullptr;
    {
      std::lock_guard<std::mutex> lock(g_state.mutex);
      connection = g_state.connection;
    }
    if (!connection) return;
    dbus_connection_read_write_dispatch(connection, 100);
  }
}

bool EnsureConnection() {
  if (g_state.initialized) return g_state.connection != nullptr;

  g_state.initialized = true;
  dbus_threads_init_default();
  DBusError error;
  dbus_error_init(&error);
  g_state.connection = dbus_bus_get(DBUS_BUS_SESSION, &error);
  if (dbus_error_is_set(&error)) dbus_error_free(&error);
  if (!g_state.connection) return false;

  dbus_connection_set_exit_on_disconnect(g_state.connection, FALSE);
  dbus_bus_request_name(g_state.connection, kBusName, DBUS_NAME_FLAG_DO_NOT_QUEUE,
                        nullptr);
  if (!dbus_connection_register_object_path(g_state.connection, kObjectPath,
                                            &kObjectVTable, nullptr)) {
    dbus_connection_unref(g_state.connection);
    g_state.connection = nullptr;
    return false;
  }

  g_state.running.store(true);
  g_state.dispatch_thread = std::thread(DispatchLoop);
  return true;
}

void EmitPropertiesChanged() {
  DBusConnection* connection = g_state.connection;
  if (!connection) return;
  DBusMessage* signal = dbus_message_new_signal(
      kObjectPath, kPropertiesInterface, "PropertiesChanged");
  if (!signal) return;

  DBusMessageIter root;
  DBusMessageIter changed;
  DBusMessageIter invalidated;
  const char* interface_name = kPlayerInterface;
  dbus_message_iter_init_append(signal, &root);
  dbus_message_iter_append_basic(&root, DBUS_TYPE_STRING, &interface_name);
  dbus_message_iter_open_container(&root, DBUS_TYPE_ARRAY, "{sv}", &changed);
  AppendPlayerPropertiesFromState(&changed);
  dbus_message_iter_close_container(&root, &changed);
  dbus_message_iter_open_container(&root, DBUS_TYPE_ARRAY, "s", &invalidated);
  dbus_message_iter_close_container(&root, &invalidated);
  dbus_connection_send(connection, signal, nullptr);
  dbus_connection_flush(connection);
  dbus_message_unref(signal);
}

}  // namespace

void UpdateSystemMediaSession(const SystemMediaSessionMetadata& metadata,
                              SystemMediaSessionPlaybackState state,
                              double position) {
  std::lock_guard<std::mutex> lock(g_state.mutex);
  if (!EnsureConnection()) return;
  g_state.metadata = metadata;
  g_state.playback_state = state;
  g_state.position = std::max(0.0, position);
  EmitPropertiesChanged();
}

void ClearSystemMediaSession() {
  std::thread dispatch_thread;
  DBusConnection* connection = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    if (!g_state.connection) return;
    g_state.running.store(false);
    dispatch_thread = std::move(g_state.dispatch_thread);
    connection = g_state.connection;
    g_state.connection = nullptr;
    g_state.initialized = false;
  }

  if (dispatch_thread.joinable()) dispatch_thread.join();
  dbus_connection_unregister_object_path(connection, kObjectPath);
  dbus_bus_release_name(connection, kBusName, nullptr);
  dbus_connection_unref(connection);
}
