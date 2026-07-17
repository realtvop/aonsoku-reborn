#include "system_media_session.h"

#include <dbus/dbus.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

namespace {

constexpr char kBusName[] = "org.mpris.MediaPlayer2.aonsoku";
constexpr char kObjectPath[] = "/org/mpris/MediaPlayer2";
constexpr char kIntrospectableInterface[] =
    "org.freedesktop.DBus.Introspectable";
constexpr char kPropertiesInterface[] = "org.freedesktop.DBus.Properties";
constexpr char kRootInterface[] = "org.mpris.MediaPlayer2";
constexpr char kPlayerInterface[] = "org.mpris.MediaPlayer2.Player";
constexpr char kNoTrackId[] = "/org/mpris/MediaPlayer2/TrackList/NoTrack";
constexpr char kErrorNotSupported[] = "org.freedesktop.DBus.Error.NotSupported";
constexpr char kErrorUnknownProperty[] =
    "org.freedesktop.DBus.Error.UnknownProperty";
constexpr char kErrorInvalidArgs[] = "org.freedesktop.DBus.Error.InvalidArgs";

struct MprisState {
  std::mutex mutex;
  DBusConnection* connection = nullptr;
  std::thread dispatch_thread;
  std::atomic_bool running{false};
  bool initialized = false;
  SystemMediaSessionMetadata metadata;
  std::string track_id = kNoTrackId;
  uint64_t next_track_id = 1;
  SystemMediaSessionPlaybackState playback_state =
      SystemMediaSessionPlaybackState::kStopped;
  double position = 0;
  std::chrono::steady_clock::time_point position_updated_at =
      std::chrono::steady_clock::now();
  bool seek_pending = false;
  std::string pending_seek_track_id;
};

MprisState g_state;

SystemMediaCommandHandler g_command_handler = nullptr;
void* g_command_context = nullptr;

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

bool IsSameTrackMetadata(const SystemMediaSessionMetadata& left,
                         const SystemMediaSessionMetadata& right) {
  return left.title == right.title && left.artist == right.artist &&
         left.album == right.album &&
         std::abs(left.duration - right.duration) < 0.001;
}

bool IsSafeArtworkUrl(const std::string& artwork_url) {
  return artwork_url.rfind("file://", 0) == 0;
}

// Caller must hold g_state.mutex.
double CurrentPosition() {
  double position = g_state.position;
  if (g_state.playback_state == SystemMediaSessionPlaybackState::kPlaying) {
    position += std::chrono::duration<double>(
                    std::chrono::steady_clock::now() -
                    g_state.position_updated_at)
                    .count();
  }
  if (g_state.metadata.duration > 0)
    position = std::min(position, g_state.metadata.duration);
  return std::max(0.0, position);
}

// ---------------------------------------------------------------------------
// Value appenders: append a bare value into an already-open container iter.
// Used by both the dict-entry builders (GetAll) and the Get variant builder.
// ---------------------------------------------------------------------------

void AppendStringValue(DBusMessageIter* iter, const std::string& value) {
  const char* text = value.c_str();
  dbus_message_iter_append_basic(iter, DBUS_TYPE_STRING, &text);
}

void AppendObjectPathValue(DBusMessageIter* iter, const char* value) {
  dbus_message_iter_append_basic(iter, DBUS_TYPE_OBJECT_PATH, &value);
}

void AppendBoolValue(DBusMessageIter* iter, bool value) {
  dbus_bool_t dbus_value = value ? TRUE : FALSE;
  dbus_message_iter_append_basic(iter, DBUS_TYPE_BOOLEAN, &dbus_value);
}

void AppendInt64Value(DBusMessageIter* iter, int64_t value) {
  dbus_message_iter_append_basic(iter, DBUS_TYPE_INT64, &value);
}

void AppendDoubleValue(DBusMessageIter* iter, double value) {
  dbus_message_iter_append_basic(iter, DBUS_TYPE_DOUBLE, &value);
}

void AppendStringArrayValue(DBusMessageIter* iter, const std::string& value) {
  DBusMessageIter array;
  dbus_message_iter_open_container(iter, DBUS_TYPE_ARRAY, "s", &array);
  if (!value.empty()) {
    const char* text = value.c_str();
    dbus_message_iter_append_basic(&array, DBUS_TYPE_STRING, &text);
  }
  dbus_message_iter_close_container(iter, &array);
}

// ---------------------------------------------------------------------------
// Dict-entry builders: append a "{sv}" entry (key + variant) to a dict iter.
// ---------------------------------------------------------------------------

void AppendStringEntry(DBusMessageIter* dict, const char* key,
                       const std::string& value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant);
  AppendStringValue(&variant, value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}

void AppendBoolEntry(DBusMessageIter* dict, const char* key, bool value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "b", &variant);
  AppendBoolValue(&variant, value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}

void AppendInt64Entry(DBusMessageIter* dict, const char* key, int64_t value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "x", &variant);
  AppendInt64Value(&variant, value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}

void AppendDoubleEntry(DBusMessageIter* dict, const char* key, double value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "d", &variant);
  AppendDoubleValue(&variant, value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}

void AppendObjectPathEntry(DBusMessageIter* dict, const char* key,
                           const char* value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "o", &variant);
  AppendObjectPathValue(&variant, value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}

void AppendStringArrayEntry(DBusMessageIter* dict, const char* key,
                            const std::string& value) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "as", &variant);
  AppendStringArrayValue(&variant, value);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}

// Metadata is itself an a{sv} variant. AppendMetadataValue opens the array;
// AppendMetadataEntry wraps it as the "Metadata" property dict entry.
void AppendMetadataValue(DBusMessageIter* iter,
                         const SystemMediaSessionMetadata& metadata,
                         const std::string& track_id) {
  DBusMessageIter array;
  dbus_message_iter_open_container(iter, DBUS_TYPE_ARRAY, "{sv}", &array);
  const char* track_path = track_id.c_str();
  AppendObjectPathEntry(&array, "mpris:trackid", track_path);
  AppendStringEntry(&array, "xesam:title", metadata.title);
  AppendStringArrayEntry(&array, "xesam:artist", metadata.artist);
  AppendStringEntry(&array, "xesam:album", metadata.album);
  if (IsSafeArtworkUrl(metadata.artwork_url)) {
    AppendStringEntry(&array, "mpris:artUrl", metadata.artwork_url);
  }
  if (metadata.duration > 0) {
    AppendInt64Entry(&array, "mpris:length",
                     static_cast<int64_t>(metadata.duration * 1'000'000));
  }
  dbus_message_iter_close_container(iter, &array);
}

void AppendMetadataEntry(DBusMessageIter* dict,
                         const SystemMediaSessionMetadata& metadata,
                         const std::string& track_id) {
  DBusMessageIter entry;
  DBusMessageIter variant;
  static const char* key = "Metadata";
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, nullptr,
                                   &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
  dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "a{sv}",
                                    &variant);
  AppendMetadataValue(&variant, metadata, track_id);
  dbus_message_iter_close_container(&entry, &variant);
  dbus_message_iter_close_container(dict, &entry);
}

// ---------------------------------------------------------------------------
// Property registry: signatures + value appenders per interface/property.
// AppendPropertyValue appends the bare value into an already-open variant
// iter; the caller must hold g_state.mutex for Player properties (they read
// playback state). Root properties are static.
// ---------------------------------------------------------------------------

const char* PropertySignature(const std::string& iface,
                              const std::string& prop) {
  if (iface == kPlayerInterface) {
    if (prop == "PlaybackStatus" || prop == "Metadata") {
      return prop == "PlaybackStatus" ? "s" : "a{sv}";
    }
    if (prop == "Rate" || prop == "MinimumRate" || prop == "MaximumRate")
      return "d";
    if (prop == "Position") return "x";
    if (prop == "CanPlay" || prop == "CanPause" || prop == "CanSeek" ||
        prop == "CanGoNext" || prop == "CanGoPrevious" || prop == "CanControl") {
      return "b";
    }
  } else if (iface == kRootInterface) {
    if (prop == "Identity" || prop == "DesktopEntry") return "s";
    if (prop == "SupportedUriSchemes" || prop == "SupportedMimeTypes")
      return "as";
    if (prop == "CanQuit" || prop == "CanRaise" || prop == "HasTrackList")
      return "b";
  }

  return nullptr;
}

// Returns true if the property is known and its value was appended.
bool AppendPropertyValue(DBusMessageIter* variant, const std::string& iface,
                         const std::string& prop) {
  if (iface == kPlayerInterface) {
    if (prop == "PlaybackStatus") {
      AppendStringValue(variant, PlaybackStatus(g_state.playback_state));
      return true;
    }
    if (prop == "Metadata") {
      AppendMetadataValue(variant, g_state.metadata, g_state.track_id);
      return true;
    }
    if (prop == "Rate" || prop == "MinimumRate" || prop == "MaximumRate") {
      AppendDoubleValue(variant, 1.0);
      return true;
    }
    if (prop == "Position") {
      AppendInt64Value(variant,
                       static_cast<int64_t>(CurrentPosition() * 1'000'000));
      return true;
    }
    const bool has_handler = g_command_handler != nullptr;
    const bool has_track = g_state.track_id != kNoTrackId;
    if (prop == "CanControl") {
      AppendBoolValue(variant, has_handler);
      return true;
    }
    if (prop == "CanPlay") {
      AppendBoolValue(variant, has_handler && has_track);
      return true;
    }
    if (prop == "CanPause") {
      AppendBoolValue(variant, has_handler && has_track &&
                                   g_state.playback_state !=
                                       SystemMediaSessionPlaybackState::kStopped);
      return true;
    }
    if (prop == "CanSeek") {
      AppendBoolValue(variant,
                      has_handler && has_track &&
                          g_state.playback_state !=
                              SystemMediaSessionPlaybackState::kStopped &&
                          g_state.metadata.duration > 0);
      return true;
    }
    if (prop == "CanGoNext" || prop == "CanGoPrevious") {
      // The native addon is not given queue bounds, so it cannot truthfully
      // promise that either operation will advance to another track.
      AppendBoolValue(variant, false);
      return true;
    }
  } else if (iface == kRootInterface) {
    if (prop == "Identity") {
      AppendStringValue(variant, "Aonsoku");
      return true;
    }
    if (prop == "DesktopEntry") {
      AppendStringValue(variant, "aonsoku");
      return true;
    }
    if (prop == "SupportedUriSchemes" || prop == "SupportedMimeTypes") {
      AppendStringArrayValue(variant, "");
      return true;
    }
    if (prop == "CanQuit" || prop == "CanRaise" || prop == "HasTrackList") {
      AppendBoolValue(variant, false);
      return true;
    }
  }

  return false;
}

// Appends all Player property dict entries. Caller must hold g_state.mutex.
void AppendAllPlayerProperties(DBusMessageIter* dict) {
  AppendStringEntry(dict, "PlaybackStatus",
                    PlaybackStatus(g_state.playback_state));
  AppendDoubleEntry(dict, "Rate", 1.0);
  AppendMetadataEntry(dict, g_state.metadata, g_state.track_id);
  AppendInt64Entry(dict, "Position",
                   static_cast<int64_t>(CurrentPosition() * 1'000'000));
  AppendDoubleEntry(dict, "MinimumRate", 1.0);
  AppendDoubleEntry(dict, "MaximumRate", 1.0);
  const bool has_handler = g_command_handler != nullptr;
  const bool has_track = g_state.track_id != kNoTrackId;
  AppendBoolEntry(dict, "CanControl", has_handler);
  AppendBoolEntry(dict, "CanPlay", has_handler && has_track);
  AppendBoolEntry(dict, "CanPause",
                  has_handler && has_track &&
                      g_state.playback_state !=
                          SystemMediaSessionPlaybackState::kStopped);
  AppendBoolEntry(dict, "CanSeek",
                  has_handler && has_track &&
                      g_state.playback_state !=
                          SystemMediaSessionPlaybackState::kStopped &&
                      g_state.metadata.duration > 0);
  AppendBoolEntry(dict, "CanGoNext", false);
  AppendBoolEntry(dict, "CanGoPrevious", false);
}

// Appends all Root property dict entries. Static; no lock required.
void AppendAllRootProperties(DBusMessageIter* dict) {
  AppendStringEntry(dict, "Identity", "Aonsoku");
  AppendBoolEntry(dict, "CanQuit", false);
  AppendBoolEntry(dict, "CanRaise", false);
  AppendBoolEntry(dict, "HasTrackList", false);
  AppendStringEntry(dict, "DesktopEntry", "aonsoku");
  AppendStringArrayEntry(dict, "SupportedUriSchemes", "");
  AppendStringArrayEntry(dict, "SupportedMimeTypes", "");
}

// ---------------------------------------------------------------------------
// Command dispatch + signals
// ---------------------------------------------------------------------------

void DispatchCommand(SystemMediaCommand command, double position) {
  // Keep the registration lock through the short non-blocking TSFN enqueue.
  // Teardown cannot destroy the opaque context after we copy it but before the
  // handler uses it.
  std::lock_guard<std::mutex> lock(g_state.mutex);
  if (g_command_handler != nullptr)
    g_command_handler(g_command_context, command, position);
}

void EmitSeeked(DBusConnection* connection, double position_seconds) {
  DBusMessage* signal = dbus_message_new_signal(kObjectPath, kPlayerInterface,
                                                "Seeked");
  if (!signal) return;
  int64_t position_micros =
      static_cast<int64_t>(std::max(0.0, position_seconds) * 1'000'000);
  dbus_message_append_args(signal, DBUS_TYPE_INT64, &position_micros,
                           DBUS_TYPE_INVALID);
  dbus_connection_send(connection, signal, nullptr);
  dbus_connection_flush(connection);
  dbus_message_unref(signal);
}

void SendEmptyReply(DBusConnection* connection, DBusMessage* message) {
  DBusMessage* reply = dbus_message_new_method_return(message);
  if (!reply) return;
  dbus_connection_send(connection, reply, nullptr);
  dbus_message_unref(reply);
}

void SendError(DBusConnection* connection, DBusMessage* message,
               const char* error_name, const char* error_message) {
  DBusMessage* error =
      dbus_message_new_error(message, error_name, error_message);
  if (!error) return;
  dbus_connection_send(connection, error, nullptr);
  dbus_message_unref(error);
}

// Caller must hold g_state.mutex.
void EmitPropertiesChanged();

// ---------------------------------------------------------------------------
// Message handling
// ---------------------------------------------------------------------------

DBusHandlerResult HandleIntrospect(DBusConnection* connection,
                                   DBusMessage* message) {
  static const char kIntrospection[] =
      "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection "
      "1.0//EN\" \"http://www.freedesktop.org/standards/dbus/1.0/introspect."
      "dtd\">\n"
      "<node>\n"
      "  <interface name='org.freedesktop.DBus.Introspectable'>\n"
      "    <method name='Introspect'>\n"
      "      <arg name='data' type='s' direction='out'/>\n"
      "    </method>\n"
      "  </interface>\n"
      "  <interface name='org.freedesktop.DBus.Properties'>\n"
      "    <method name='Get'>\n"
      "      <arg name='interface' direction='in' type='s'/>\n"
      "      <arg name='property' direction='in' type='s'/>\n"
      "      <arg name='value' direction='out' type='v'/>\n"
      "    </method>\n"
      "    <method name='Set'>\n"
      "      <arg name='interface' direction='in' type='s'/>\n"
      "      <arg name='property' direction='in' type='s'/>\n"
      "      <arg name='value' direction='in' type='v'/>\n"
      "    </method>\n"
      "    <method name='GetAll'>\n"
      "      <arg name='interface' direction='in' type='s'/>\n"
      "      <arg name='properties' direction='out' type='a{sv}'/>\n"
      "    </method>\n"
      "    <signal name='PropertiesChanged'>\n"
      "      <arg type='s' name='interface_name'/>\n"
      "      <arg type='a{sv}' name='changed_properties'/>\n"
      "      <arg type='as' name='invalidated_properties'/>\n"
      "    </signal>\n"
      "  </interface>\n"
      "  <interface name='org.mpris.MediaPlayer2'>\n"
      "    <method name='Raise'/>\n"
      "    <method name='Quit'/>\n"
      "    <property name='Identity' type='s' access='read'/>\n"
      "    <property name='CanQuit' type='b' access='read'/>\n"
      "    <property name='CanRaise' type='b' access='read'/>\n"
      "    <property name='HasTrackList' type='b' access='read'/>\n"
      "    <property name='DesktopEntry' type='s' access='read'/>\n"
      "    <property name='SupportedUriSchemes' type='as' access='read'/>\n"
      "    <property name='SupportedMimeTypes' type='as' access='read'/>\n"
      "  </interface>\n"
      "  <interface name='org.mpris.MediaPlayer2.Player'>\n"
      "    <method name='Next'/>\n"
      "    <method name='Previous'/>\n"
      "    <method name='Pause'/>\n"
      "    <method name='Play'/>\n"
      "    <method name='PlayPause'/>\n"
      "    <method name='Stop'/>\n"
      "    <method name='Seek'>\n"
      "      <arg direction='in' name='Offset' type='x'/>\n"
      "    </method>\n"
      "    <method name='SetPosition'>\n"
      "      <arg direction='in' name='TrackId' type='o'/>\n"
      "      <arg direction='in' name='Position' type='x'/>\n"
      "    </method>\n"
      "    <method name='OpenUri'>\n"
      "      <arg direction='in' name='Uri' type='s'/>\n"
      "    </method>\n"
      "    <signal name='Seeked'>\n"
      "      <arg name='Position' type='x'/>\n"
      "    </signal>\n"
      "    <property name='PlaybackStatus' type='s' access='read'/>\n"
      "    <property name='Rate' type='d' access='readwrite'/>\n"
      "    <property name='Metadata' type='a{sv}' access='read'/>\n"
      "    <property name='Position' type='x' access='read'/>\n"
      "    <property name='MinimumRate' type='d' access='read'/>\n"
      "    <property name='MaximumRate' type='d' access='read'/>\n"
      "    <property name='CanPlay' type='b' access='read'/>\n"
      "    <property name='CanPause' type='b' access='read'/>\n"
      "    <property name='CanSeek' type='b' access='read'/>\n"
      "    <property name='CanGoNext' type='b' access='read'/>\n"
      "    <property name='CanGoPrevious' type='b' access='read'/>\n"
      "    <property name='CanControl' type='b' access='read'/>\n"
      "  </interface>\n"
      "</node>\n";
  DBusMessage* reply = dbus_message_new_method_return(message);
  if (!reply) return DBUS_HANDLER_RESULT_NEED_MEMORY;
  const char* xml = kIntrospection;
  dbus_message_append_args(reply, DBUS_TYPE_STRING, &xml, DBUS_TYPE_INVALID);
  dbus_connection_send(connection, reply, nullptr);
  dbus_message_unref(reply);
  return DBUS_HANDLER_RESULT_HANDLED;
}

DBusHandlerResult HandlePropertyGet(DBusConnection* connection,
                                     DBusMessage* message) {
  DBusError error;
  dbus_error_init(&error);
  const char* iface_name = nullptr;
  const char* prop_name = nullptr;
  if (!dbus_message_get_args(message, &error, DBUS_TYPE_STRING, &iface_name,
                             DBUS_TYPE_STRING, &prop_name,
                             DBUS_TYPE_INVALID) ||
      iface_name == nullptr || prop_name == nullptr) {
    dbus_error_free(&error);
    SendError(connection, message, kErrorInvalidArgs,
               "Get expects (interface, property) strings.");
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  std::string iface = iface_name;
  std::string prop = prop_name;
  const char* signature = PropertySignature(iface, prop);
  if (signature == nullptr) {
    SendError(connection, message, kErrorUnknownProperty,
              "Unknown property or not readable.");
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  DBusMessage* reply = dbus_message_new_method_return(message);
  if (!reply) return DBUS_HANDLER_RESULT_NEED_MEMORY;
  DBusMessageIter root;
  DBusMessageIter variant;
  dbus_message_iter_init_append(reply, &root);
  dbus_message_iter_open_container(&root, DBUS_TYPE_VARIANT, signature,
                                    &variant);

  bool appended = false;
  {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    appended = AppendPropertyValue(&variant, iface, prop);
  }

  dbus_message_iter_close_container(&root, &variant);
  if (!appended) {
    dbus_message_unref(reply);
    SendError(connection, message, kErrorUnknownProperty,
               "Unknown property.");
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  dbus_connection_send(connection, reply, nullptr);
  dbus_message_unref(reply);
  return DBUS_HANDLER_RESULT_HANDLED;
}

DBusHandlerResult HandlePropertyGetAll(DBusConnection* connection,
                                        DBusMessage* message) {
  DBusError error;
  dbus_error_init(&error);
  const char* iface_name = nullptr;
  if (!dbus_message_get_args(message, &error, DBUS_TYPE_STRING, &iface_name,
                             DBUS_TYPE_INVALID) ||
      iface_name == nullptr) {
    dbus_error_free(&error);
    SendError(connection, message, kErrorInvalidArgs,
               "GetAll expects an interface string.");
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  std::string iface = iface_name;
  bool want_player = iface == kPlayerInterface;
  bool want_root = iface == kRootInterface;

  DBusMessage* reply = dbus_message_new_method_return(message);
  if (!reply) return DBUS_HANDLER_RESULT_NEED_MEMORY;
  DBusMessageIter root;
  DBusMessageIter dict;
  dbus_message_iter_init_append(reply, &root);
  dbus_message_iter_open_container(&root, DBUS_TYPE_ARRAY, "{sv}", &dict);
  if (want_player || want_root) {
    {
      std::lock_guard<std::mutex> lock(g_state.mutex);
      if (want_player) AppendAllPlayerProperties(&dict);
    }
    if (want_root) AppendAllRootProperties(&dict);
  }
  dbus_message_iter_close_container(&root, &dict);
  dbus_connection_send(connection, reply, nullptr);
  dbus_message_unref(reply);
  return DBUS_HANDLER_RESULT_HANDLED;
}

DBusHandlerResult HandlePropertySet(DBusConnection* connection,
                                    DBusMessage* message) {
  DBusMessageIter iter;
  if (!dbus_message_iter_init(message, &iter) ||
      dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_STRING) {
    SendError(connection, message, kErrorInvalidArgs,
              "Set expects (interface, property, variant).");
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  const char* iface = nullptr;
  dbus_message_iter_get_basic(&iter, &iface);
  if (!dbus_message_iter_next(&iter) ||
      dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_STRING) {
    SendError(connection, message, kErrorInvalidArgs,
              "Set expects (interface, property, variant).");
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  const char* property = nullptr;
  dbus_message_iter_get_basic(&iter, &property);
  if (!dbus_message_iter_next(&iter) ||
      dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_VARIANT) {
    SendError(connection, message, kErrorInvalidArgs,
              "Set expects (interface, property, variant).");
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (iface != nullptr && property != nullptr &&
      std::string(iface) == kPlayerInterface && std::string(property) == "Rate") {
    DBusMessageIter value;
    dbus_message_iter_recurse(&iter, &value);
    if (dbus_message_iter_get_arg_type(&value) != DBUS_TYPE_DOUBLE) {
      SendError(connection, message, kErrorInvalidArgs,
                "Rate must be a double.");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    double rate = 0;
    dbus_message_iter_get_basic(&value, &rate);
    if (std::abs(rate - 1.0) > 0.000001) {
      SendError(connection, message, kErrorInvalidArgs,
                "Aonsoku supports only rate 1.0.");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  SendError(connection, message, kErrorNotSupported,
            "Property is read-only or unsupported.");
  return DBUS_HANDLER_RESULT_HANDLED;
}

DBusHandlerResult HandlePlayerMethod(DBusConnection* connection,
                                     DBusMessage* message) {
  const char* method = dbus_message_get_member(message);
  if (method == nullptr) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  std::string method_name = method;

  // Simple transport methods with no arguments.
  if (method_name == "Play") {
    DispatchCommand(SystemMediaCommand::kPlay, 0);
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (method_name == "Pause") {
    DispatchCommand(SystemMediaCommand::kPause, 0);
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (method_name == "PlayPause") {
    DispatchCommand(SystemMediaCommand::kTogglePlayPause, 0);
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (method_name == "Stop") {
    DispatchCommand(SystemMediaCommand::kStop, 0);
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (method_name == "Next") {
    DispatchCommand(SystemMediaCommand::kNext, 0);
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (method_name == "Previous") {
    DispatchCommand(SystemMediaCommand::kPrevious, 0);
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (method_name == "Seek") {
    DBusError error;
    dbus_error_init(&error);
    dbus_int64_t offset = 0;
    if (!dbus_message_get_args(message, &error, DBUS_TYPE_INT64, &offset,
                               DBUS_TYPE_INVALID)) {
      dbus_error_free(&error);
      SendError(connection, message, kErrorInvalidArgs, "Seek expects (x).");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    double target = 0;
    bool go_next = false;
    {
      std::lock_guard<std::mutex> lock(g_state.mutex);
      if (g_state.playback_state == SystemMediaSessionPlaybackState::kStopped ||
          g_state.metadata.duration <= 0 || g_command_handler == nullptr) {
        SendEmptyReply(connection, message);
        return DBUS_HANDLER_RESULT_HANDLED;
      }
      const double requested = CurrentPosition() + offset / 1'000'000.0;
      go_next = requested > g_state.metadata.duration;
      target = std::max(0.0, requested);
      if (!go_next) {
        g_state.seek_pending = true;
        g_state.pending_seek_track_id = g_state.track_id;
      }
    }
    DispatchCommand(go_next ? SystemMediaCommand::kNext
                            : SystemMediaCommand::kSeek,
                    go_next ? 0 : target);
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (method_name == "SetPosition") {
    DBusError error;
    dbus_error_init(&error);
    const char* track_id = nullptr;
    dbus_int64_t position = 0;
    if (!dbus_message_get_args(message, &error, DBUS_TYPE_OBJECT_PATH,
                               &track_id, DBUS_TYPE_INT64, &position,
                               DBUS_TYPE_INVALID)) {
      dbus_error_free(&error);
      SendError(connection, message, kErrorInvalidArgs,
               "SetPosition expects (o, x).");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    const double target = position / 1'000'000.0;
    bool accepted = false;
    {
      std::lock_guard<std::mutex> lock(g_state.mutex);
      accepted = track_id != nullptr && track_id == g_state.track_id &&
                 position >= 0 && g_state.metadata.duration > 0 &&
                 target <= g_state.metadata.duration &&
                 g_state.playback_state !=
                     SystemMediaSessionPlaybackState::kStopped &&
                 g_command_handler != nullptr;
      if (accepted) {
        g_state.seek_pending = true;
        g_state.pending_seek_track_id = g_state.track_id;
      }
    }
    if (accepted) DispatchCommand(SystemMediaCommand::kSeek, target);
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (method_name == "OpenUri") {
    // Opening arbitrary URIs through MPRIS is not supported.
    SendError(connection, message, kErrorNotSupported, "OpenUri not supported.");
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

DBusHandlerResult HandleRootMethod(DBusConnection* connection,
                                   DBusMessage* message) {
  const char* method = dbus_message_get_member(message);
  if (method == nullptr) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  std::string method_name = method;

  // CanQuit/CanRaise are false, so well-behaved clients will not call these;
  // reply OK defensively if they do.
  if (method_name == "Raise" || method_name == "Quit") {
    SendEmptyReply(connection, message);
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

DBusHandlerResult HandleMessage(DBusConnection* connection, DBusMessage* message,
                                void*) {
  if (dbus_message_get_type(message) != DBUS_MESSAGE_TYPE_METHOD_CALL)
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

  if (dbus_message_is_method_call(message, kIntrospectableInterface,
                                  "Introspect")) {
    return HandleIntrospect(connection, message);
  }

  if (dbus_message_is_method_call(message, kPropertiesInterface, "Get")) {
    return HandlePropertyGet(connection, message);
  }
  if (dbus_message_is_method_call(message, kPropertiesInterface, "Set")) {
    return HandlePropertySet(connection, message);
  }
  if (dbus_message_is_method_call(message, kPropertiesInterface, "GetAll")) {
    return HandlePropertyGetAll(connection, message);
  }

  if (dbus_message_has_interface(message, kPlayerInterface)) {
    return HandlePlayerMethod(connection, message);
  }
  if (dbus_message_has_interface(message, kRootInterface)) {
    return HandleRootMethod(connection, message);
  }

  return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

DBusObjectPathVTable kObjectVTable = {nullptr, HandleMessage, nullptr, nullptr,
                                      nullptr, nullptr};

void DispatchLoop(DBusConnection* connection) {
  while (g_state.running.load()) {
    if (!dbus_connection_read_write_dispatch(connection, 100)) {
      g_state.running.store(false);
      return;
    }
  }
}

bool EnsureConnection() {
  if (g_state.initialized && g_state.connection != nullptr &&
      dbus_connection_get_is_connected(g_state.connection))
    return true;
  if (g_state.initialized) {
    // The dispatch thread invokes message handlers that also take this mutex.
    // Never join it here until it has reported that dispatch returned; the
    // next session update will retry initialization after that point.
    if (g_state.running.load()) return false;
    if (g_state.dispatch_thread.joinable()) g_state.dispatch_thread.join();
    if (g_state.connection != nullptr) {
      dbus_connection_unregister_object_path(g_state.connection, kObjectPath);
      dbus_connection_unref(g_state.connection);
      g_state.connection = nullptr;
    }
    g_state.initialized = false;
  }

  static std::once_flag dbus_threads_once;
  std::call_once(dbus_threads_once, [] { dbus_threads_init_default(); });
  DBusError error;
  dbus_error_init(&error);
  DBusConnection* connection = dbus_bus_get(DBUS_BUS_SESSION, &error);
  if (dbus_error_is_set(&error)) dbus_error_free(&error);
  if (!connection) return false;

  dbus_connection_set_exit_on_disconnect(connection, FALSE);
  dbus_error_init(&error);
  const int request_result = dbus_bus_request_name(
      connection, kBusName, DBUS_NAME_FLAG_DO_NOT_QUEUE, &error);
  const bool owns_name = !dbus_error_is_set(&error) &&
                         (request_result == DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER ||
                          request_result == DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER);
  if (dbus_error_is_set(&error)) dbus_error_free(&error);
  if (!owns_name) {
    dbus_connection_unref(connection);
    return false;
  }

  if (!dbus_connection_register_object_path(connection, kObjectPath,
                                            &kObjectVTable, nullptr)) {
    dbus_bus_release_name(connection, kBusName, nullptr);
    dbus_connection_unref(connection);
    return false;
  }

  g_state.connection = connection;
  g_state.initialized = true;
  g_state.running.store(true);
  g_state.dispatch_thread = std::thread(DispatchLoop, connection);
  return true;
}

// Caller must hold g_state.mutex.
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
  AppendAllPlayerProperties(&changed);
  dbus_message_iter_close_container(&root, &changed);
  dbus_message_iter_open_container(&root, DBUS_TYPE_ARRAY, "s", &invalidated);
  dbus_message_iter_close_container(&root, &invalidated);
  dbus_connection_send(connection, signal, nullptr);
  dbus_connection_flush(connection);
  dbus_message_unref(signal);
}

}  // namespace

// These are declared in system_media_session.h and called from
// aonsoku_libmpv.cc (a separate translation unit), so they must have external
// linkage. They are intentionally defined OUTSIDE the anonymous namespace above;
// defining them inside it (internal linkage) would leave them undefined to the
// addon linker. They still reference the anonymous-namespace globals, which are
// visible here via the anonymous namespace's implicit using-directive.
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

void UpdateSystemMediaSession(const SystemMediaSessionMetadata& metadata,
                              SystemMediaSessionPlaybackState state,
                              double position) {
  std::lock_guard<std::mutex> lock(g_state.mutex);
  if (!EnsureConnection()) return;
  const double previous_position = CurrentPosition();
  const double bounded_position =
      metadata.duration > 0
          ? std::min(std::max(0.0, position), metadata.duration)
          : std::max(0.0, position);
  const bool same_metadata = IsSameTrackMetadata(g_state.metadata, metadata);
  const bool restarted_same_track =
      same_metadata && !g_state.seek_pending && previous_position > 1.0 &&
      bounded_position < 0.25;
  if (g_state.track_id == kNoTrackId || !same_metadata ||
      restarted_same_track) {
    g_state.track_id = "/org/mpris/MediaPlayer2/track/" +
                       std::to_string(g_state.next_track_id++);
  }
  g_state.metadata = metadata;
  g_state.playback_state = state;
  g_state.position = bounded_position;
  g_state.position_updated_at = std::chrono::steady_clock::now();
  EmitPropertiesChanged();
  if (g_state.seek_pending &&
      g_state.pending_seek_track_id == g_state.track_id) {
    EmitSeeked(g_state.connection, g_state.position);
  }
  g_state.seek_pending = false;
  g_state.pending_seek_track_id.clear();
}

void ClearSystemMediaSession() {
  std::thread dispatch_thread;
  DBusConnection* connection = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    g_state.running.store(false);
    dispatch_thread = std::move(g_state.dispatch_thread);
    connection = g_state.connection;
    g_state.connection = nullptr;
    g_state.initialized = false;
    g_state.metadata = {};
    g_state.track_id = kNoTrackId;
    g_state.playback_state = SystemMediaSessionPlaybackState::kStopped;
    g_state.position = 0;
    g_state.position_updated_at = std::chrono::steady_clock::now();
    g_state.seek_pending = false;
    g_state.pending_seek_track_id.clear();
  }

  if (dispatch_thread.joinable()) dispatch_thread.join();
  if (!connection) return;
  dbus_connection_unregister_object_path(connection, kObjectPath);
  dbus_bus_release_name(connection, kBusName, nullptr);
  dbus_connection_unref(connection);
}
