#include <mpv/client.h>
#include <node_api.h>

#include "system_media_session.h"

#include <atomic>
#include <clocale>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

enum class EventValueType {
  kNone,
  kBoolean,
  kNumber,
  kString,
};

struct QueuedEvent {
  std::string type;
  std::string name;
  std::string reason;
  std::string error;
  std::string code;
  std::string message;
  EventValueType value_type = EventValueType::kNone;
  bool bool_value = false;
  double number_value = 0;
  std::string string_value;
};

struct PlayerState {
  napi_env env = nullptr;
  napi_ref wrapper = nullptr;
  napi_threadsafe_function tsfn = nullptr;
  mpv_handle* handle = nullptr;
  std::thread event_thread;
  std::mutex mutex;
  std::atomic_bool running{false};
};

std::string Message(const std::string& prefix, int status) {
  return prefix + ": " + mpv_error_string(status);
}

napi_value Undefined(napi_env env) {
  napi_value value;
  napi_get_undefined(env, &value);
  return value;
}

void ThrowError(napi_env env, const char* code, const std::string& message) {
  napi_value error_message;
  napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH,
                          &error_message);

  napi_value error;
  napi_create_error(env, nullptr, error_message, &error);

  napi_value code_value;
  napi_create_string_utf8(env, code, NAPI_AUTO_LENGTH, &code_value);
  napi_set_named_property(env, error, "code", code_value);

  napi_throw(env, error);
}

bool ReadString(napi_env env, napi_value value, std::string* output) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
    return false;
  }

  std::vector<char> buffer(length + 1);
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                 &copied) != napi_ok) {
    return false;
  }

  output->assign(buffer.data(), copied);
  return true;
}

bool ReadOptionalStringProperty(napi_env env, napi_value object,
                                const char* name, std::string* output) {
  bool has_property = false;
  if (napi_has_named_property(env, object, name, &has_property) != napi_ok ||
      !has_property) {
    return true;
  }

  napi_value value;
  if (napi_get_named_property(env, object, name, &value) != napi_ok) {
    return false;
  }

  napi_valuetype type;
  if (napi_typeof(env, value, &type) != napi_ok || type == napi_undefined ||
      type == napi_null) {
    return true;
  }

  return ReadString(env, value, output);
}

bool ReadOptionalNumberProperty(napi_env env, napi_value object,
                                const char* name, double* output) {
  bool has_property = false;
  if (napi_has_named_property(env, object, name, &has_property) != napi_ok ||
      !has_property) {
    return true;
  }

  napi_value value;
  napi_valuetype type;
  if (napi_get_named_property(env, object, name, &value) != napi_ok ||
      napi_typeof(env, value, &type) != napi_ok || type == napi_undefined ||
      type == napi_null) {
    return true;
  }

  return type == napi_number && napi_get_value_double(env, value, output) == napi_ok;
}

PlayerState* UnwrapPlayer(napi_env env, napi_callback_info info,
                          size_t argc, napi_value* argv) {
  napi_value self;
  if (napi_get_cb_info(env, info, &argc, argv, &self, nullptr) != napi_ok) {
    ThrowError(env, "libmpv-napi-error", "Failed to read callback info.");
    return nullptr;
  }

  PlayerState* state = nullptr;
  if (napi_unwrap(env, self, reinterpret_cast<void**>(&state)) != napi_ok ||
      state == nullptr) {
    ThrowError(env, "libmpv-invalid-player", "Invalid libmpv player handle.");
    return nullptr;
  }

  return state;
}

mpv_format FormatFromName(const std::string& format) {
  if (format == "boolean") return MPV_FORMAT_FLAG;
  if (format == "number") return MPV_FORMAT_DOUBLE;
  if (format == "string") return MPV_FORMAT_STRING;

  return MPV_FORMAT_NONE;
}

void SetString(napi_env env, napi_value object, const char* name,
               const std::string& value) {
  napi_value napi_string;
  napi_create_string_utf8(env, value.c_str(), NAPI_AUTO_LENGTH, &napi_string);
  napi_set_named_property(env, object, name, napi_string);
}

void SetBoolean(napi_env env, napi_value object, const char* name, bool value) {
  napi_value napi_boolean;
  napi_get_boolean(env, value, &napi_boolean);
  napi_set_named_property(env, object, name, napi_boolean);
}

void SetNumber(napi_env env, napi_value object, const char* name,
               double value) {
  napi_value napi_number;
  napi_create_double(env, value, &napi_number);
  napi_set_named_property(env, object, name, napi_number);
}

napi_value EventToJs(napi_env env, const QueuedEvent& event) {
  napi_value object;
  napi_create_object(env, &object);

  SetString(env, object, "type", event.type);

  if (!event.name.empty()) SetString(env, object, "name", event.name);
  if (!event.reason.empty()) SetString(env, object, "reason", event.reason);
  if (!event.error.empty()) SetString(env, object, "error", event.error);
  if (!event.code.empty()) SetString(env, object, "code", event.code);
  if (!event.message.empty()) SetString(env, object, "message", event.message);

  switch (event.value_type) {
    case EventValueType::kBoolean:
      SetBoolean(env, object, "data", event.bool_value);
      break;
    case EventValueType::kNumber:
      SetNumber(env, object, "data", event.number_value);
      break;
    case EventValueType::kString:
      SetString(env, object, "data", event.string_value);
      break;
    case EventValueType::kNone: {
      napi_value null_value;
      napi_get_null(env, &null_value);
      napi_set_named_property(env, object, "data", null_value);
      break;
    }
  }

  return object;
}

void CallJs(napi_env env, napi_value callback, void* /*context*/, void* data) {
  std::unique_ptr<QueuedEvent> event(static_cast<QueuedEvent*>(data));

  if (env == nullptr || callback == nullptr) return;

  napi_value undefined;
  napi_get_undefined(env, &undefined);
  napi_value argv[] = {EventToJs(env, *event)};
  napi_call_function(env, undefined, callback, 1, argv, nullptr);
}

void QueueEvent(PlayerState* state, std::unique_ptr<QueuedEvent> event) {
  if (state->tsfn == nullptr) {
    fprintf(stderr, "[aonsoku-media] queue: tsfn null, dropping %s\n",
            event->type.c_str());
    fflush(stderr);
    return;
  }

  auto* raw_event = event.release();
  napi_status status =
      napi_call_threadsafe_function(state->tsfn, raw_event,
                                    napi_tsfn_nonblocking);

  if (status != napi_ok) {
    fprintf(stderr, "[aonsoku-media] queue: threadsafe call failed status=%d\n",
            static_cast<int>(status));
    fflush(stderr);
    delete raw_event;
  }
}

const char* SystemMediaCommandName(SystemMediaCommand command) {
  switch (command) {
    case SystemMediaCommand::kPlay:
      return "play";
    case SystemMediaCommand::kPause:
      return "pause";
    case SystemMediaCommand::kTogglePlayPause:
      return "togglePlayPause";
    case SystemMediaCommand::kNext:
      return "next";
    case SystemMediaCommand::kPrevious:
      return "previous";
    case SystemMediaCommand::kSeek:
      return "seek";
  }

  return "unknown";
}

void SystemMediaCommandDispatcher(void* context,
                                  SystemMediaCommand command,
                                  double position) {
  auto* state = static_cast<PlayerState*>(context);
  if (state == nullptr) {
    fprintf(stderr, "[aonsoku-media] dispatcher: null state\n");
    fflush(stderr);
    return;
  }

  auto queued = std::make_unique<QueuedEvent>();
  queued->type = "system-media-command";
  queued->name = SystemMediaCommandName(command);
  if (command == SystemMediaCommand::kSeek) {
    queued->value_type = EventValueType::kNumber;
    queued->number_value = position;
  }

  fprintf(stderr,
          "[aonsoku-media] dispatcher: name=%s position=%.3f tsfn=%p\n",
          queued->name.c_str(), position, (void*)state->tsfn);
  fflush(stderr);
  QueueEvent(state, std::move(queued));
}

std::string EndFileReason(mpv_end_file_reason reason) {
  switch (reason) {
    case MPV_END_FILE_REASON_EOF:
      return "eof";
    case MPV_END_FILE_REASON_STOP:
      return "stop";
    case MPV_END_FILE_REASON_QUIT:
      return "quit";
    case MPV_END_FILE_REASON_ERROR:
      return "error";
    case MPV_END_FILE_REASON_REDIRECT:
      return "redirect";
  }

  return "unknown";
}

std::unique_ptr<QueuedEvent> TranslatePropertyEvent(mpv_event* event) {
  auto* property = static_cast<mpv_event_property*>(event->data);
  if (property == nullptr || property->name == nullptr) return nullptr;

  auto queued = std::make_unique<QueuedEvent>();
  queued->type = "property-change";
  queued->name = property->name;

  if (property->format == MPV_FORMAT_FLAG && property->data != nullptr) {
    queued->value_type = EventValueType::kBoolean;
    queued->bool_value = *static_cast<int*>(property->data) != 0;
    return queued;
  }

  if (property->format == MPV_FORMAT_DOUBLE && property->data != nullptr) {
    queued->value_type = EventValueType::kNumber;
    queued->number_value = *static_cast<double*>(property->data);
    return queued;
  }

  if (property->format == MPV_FORMAT_INT64 && property->data != nullptr) {
    queued->value_type = EventValueType::kNumber;
    queued->number_value =
        static_cast<double>(*static_cast<int64_t*>(property->data));
    return queued;
  }

  if (property->format == MPV_FORMAT_STRING && property->data != nullptr) {
    char* value = *static_cast<char**>(property->data);
    if (value != nullptr) {
      queued->value_type = EventValueType::kString;
      queued->string_value = value;
    }
  }

  return queued;
}

std::unique_ptr<QueuedEvent> TranslateEvent(mpv_event* event) {
  switch (event->event_id) {
    case MPV_EVENT_START_FILE: {
      auto queued = std::make_unique<QueuedEvent>();
      queued->type = "start-file";
      return queued;
    }
    case MPV_EVENT_FILE_LOADED: {
      auto queued = std::make_unique<QueuedEvent>();
      queued->type = "file-loaded";
      return queued;
    }
    case MPV_EVENT_PLAYBACK_RESTART: {
      auto queued = std::make_unique<QueuedEvent>();
      queued->type = "playback-restart";
      return queued;
    }
    case MPV_EVENT_END_FILE: {
      auto* end_file = static_cast<mpv_event_end_file*>(event->data);
      auto queued = std::make_unique<QueuedEvent>();
      queued->type = "end-file";

      if (end_file == nullptr) {
        queued->reason = "unknown";
        return queued;
      }

      queued->reason = EndFileReason(end_file->reason);
      if (end_file->error < 0) {
        queued->error = mpv_error_string(end_file->error);
      }
      return queued;
    }
    case MPV_EVENT_PROPERTY_CHANGE:
      return TranslatePropertyEvent(event);
    case MPV_EVENT_SHUTDOWN: {
      auto queued = std::make_unique<QueuedEvent>();
      queued->type = "shutdown";
      return queued;
    }
    default:
      return nullptr;
  }
}

void EventLoop(PlayerState* state) {
  while (state->running.load()) {
    mpv_event* event = nullptr;

    mpv_handle* handle = nullptr;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      handle = state->handle;
    }

    if (handle == nullptr) break;

    event = mpv_wait_event(handle, -1);

    if (event == nullptr || event->event_id == MPV_EVENT_NONE) continue;

    auto queued = TranslateEvent(event);
    if (queued) QueueEvent(state, std::move(queued));

    if (event->event_id == MPV_EVENT_SHUTDOWN) break;
  }
}

void FinalizePlayer(napi_env env, void* data, void* /*hint*/) {
  auto* state = static_cast<PlayerState*>(data);
  if (state == nullptr) return;

  state->running.store(false);
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->handle != nullptr) {
      mpv_wakeup(state->handle);
    }
  }

  if (state->event_thread.joinable()) {
    state->event_thread.join();
  }

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->handle != nullptr) {
      mpv_terminate_destroy(state->handle);
      state->handle = nullptr;
    }
  }

  if (state->tsfn != nullptr) {
    napi_release_threadsafe_function(state->tsfn, napi_tsfn_abort);
    state->tsfn = nullptr;
  }

  ClearSystemMediaCommandHandler(state);
  ClearSystemMediaSession();

  delete state;
}

napi_value SetEventCallback(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  PlayerState* state = UnwrapPlayer(env, info, argc, argv);
  if (state == nullptr) return nullptr;

  napi_valuetype type;
  if (argc < 1 || napi_typeof(env, argv[0], &type) != napi_ok ||
      type != napi_function) {
    ThrowError(env, "libmpv-invalid-callback",
               "setEventCallback expects a function.");
    return nullptr;
  }

  if (state->tsfn != nullptr) {
    napi_release_threadsafe_function(state->tsfn, napi_tsfn_abort);
    state->tsfn = nullptr;
  }

  napi_value resource_name;
  napi_create_string_utf8(env, "AonsokuLibMpvEvents", NAPI_AUTO_LENGTH,
                          &resource_name);
  napi_status status = napi_create_threadsafe_function(
      env, argv[0], nullptr, resource_name, 0, 1, nullptr, nullptr, nullptr,
      CallJs, &state->tsfn);

  if (status != napi_ok) {
    ThrowError(env, "libmpv-napi-error",
               "Failed to create libmpv event callback.");
    return nullptr;
  }

  return Undefined(env);
}

napi_value Initialize(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  PlayerState* state = UnwrapPlayer(env, info, argc, argv);
  if (state == nullptr) return nullptr;

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->handle != nullptr) return Undefined(env);
  }

  std::setlocale(LC_NUMERIC, "C");

  mpv_handle* handle = mpv_create();
  if (handle == nullptr) {
    ThrowError(env, "libmpv-create-failed", "mpv_create returned null.");
    return nullptr;
  }

  napi_value options;
  bool has_options = false;
  if (argc >= 1 &&
      napi_has_named_property(env, argv[0], "options", &has_options) ==
          napi_ok &&
      has_options &&
      napi_get_named_property(env, argv[0], "options", &options) == napi_ok) {
    napi_value property_names;
    uint32_t property_count = 0;

    if (napi_get_property_names(env, options, &property_names) == napi_ok &&
        napi_get_array_length(env, property_names, &property_count) ==
            napi_ok) {
      for (uint32_t index = 0; index < property_count; index += 1) {
        napi_value key;
        napi_value value;
        std::string option_name;
        std::string option_value;

        if (napi_get_element(env, property_names, index, &key) != napi_ok ||
            !ReadString(env, key, &option_name) ||
            napi_get_property(env, options, key, &value) != napi_ok ||
            !ReadString(env, value, &option_value)) {
          mpv_terminate_destroy(handle);
          ThrowError(env, "libmpv-invalid-options",
                     "libmpv options must be string key/value pairs.");
          return nullptr;
        }

        int status =
            mpv_set_option_string(handle, option_name.c_str(),
                                  option_value.c_str());
        if (status < 0) {
          mpv_terminate_destroy(handle);
          ThrowError(env, "libmpv-option-failed",
                     Message("Failed to set libmpv option " + option_name,
                             status));
          return nullptr;
        }
      }
    }
  }

  int status = mpv_initialize(handle);
  if (status < 0) {
    mpv_terminate_destroy(handle);
    ThrowError(env, "libmpv-init-failed",
               Message("Failed to initialize libmpv", status));
    return nullptr;
  }

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->handle = handle;
    state->running.store(true);
  }

  SetSystemMediaCommandHandler(&SystemMediaCommandDispatcher, state);

  state->event_thread = std::thread(EventLoop, state);

  return Undefined(env);
}

napi_value Command(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  PlayerState* state = UnwrapPlayer(env, info, argc, argv);
  if (state == nullptr) return nullptr;

  bool is_array = false;
  if (argc < 1 || napi_is_array(env, argv[0], &is_array) != napi_ok ||
      !is_array) {
    ThrowError(env, "libmpv-invalid-command",
               "libmpv command expects a string array.");
    return nullptr;
  }

  uint32_t length = 0;
  napi_get_array_length(env, argv[0], &length);

  std::vector<std::string> storage;
  std::vector<const char*> args;
  storage.reserve(length);
  args.reserve(length + 1);

  for (uint32_t index = 0; index < length; index += 1) {
    napi_value item;
    std::string value;

    if (napi_get_element(env, argv[0], index, &item) != napi_ok ||
        !ReadString(env, item, &value)) {
      ThrowError(env, "libmpv-invalid-command",
                 "libmpv command arguments must be strings.");
      return nullptr;
    }

    storage.push_back(value);
    args.push_back(storage.back().c_str());
  }

  args.push_back(nullptr);

  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->handle == nullptr) {
    ThrowError(env, "libmpv-not-initialized", "libmpv is not initialized.");
    return nullptr;
  }

  int status = mpv_command(state->handle, args.data());
  if (status < 0) {
    ThrowError(env, "libmpv-command-failed",
               Message("libmpv command failed", status));
    return nullptr;
  }

  return Undefined(env);
}

napi_value SetProperty(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  PlayerState* state = UnwrapPlayer(env, info, argc, argv);
  if (state == nullptr) return nullptr;

  std::string name;
  if (argc < 2 || !ReadString(env, argv[0], &name)) {
    ThrowError(env, "libmpv-invalid-property",
               "setProperty expects a property name and value.");
    return nullptr;
  }

  napi_valuetype type;
  napi_typeof(env, argv[1], &type);

  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->handle == nullptr) {
    ThrowError(env, "libmpv-not-initialized", "libmpv is not initialized.");
    return nullptr;
  }

  int status = 0;
  if (type == napi_boolean) {
    bool value = false;
    napi_get_value_bool(env, argv[1], &value);
    int flag = value ? 1 : 0;
    status =
        mpv_set_property(state->handle, name.c_str(), MPV_FORMAT_FLAG, &flag);
  } else if (type == napi_number) {
    double value = 0;
    napi_get_value_double(env, argv[1], &value);
    status = mpv_set_property(state->handle, name.c_str(), MPV_FORMAT_DOUBLE,
                              &value);
  } else if (type == napi_string) {
    std::string value;
    ReadString(env, argv[1], &value);
    status =
        mpv_set_property_string(state->handle, name.c_str(), value.c_str());
  } else if (type == napi_null) {
    status =
        mpv_set_property(state->handle, name.c_str(), MPV_FORMAT_NONE, nullptr);
  } else {
    ThrowError(env, "libmpv-invalid-property",
               "setProperty only supports boolean, number, string, or null.");
    return nullptr;
  }

  if (status < 0) {
    ThrowError(env, "libmpv-property-failed",
               Message("libmpv property update failed", status));
    return nullptr;
  }

  return Undefined(env);
}

napi_value ObserveProperty(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  PlayerState* state = UnwrapPlayer(env, info, argc, argv);
  if (state == nullptr) return nullptr;

  std::string name;
  std::string format_name;
  if (argc < 2 || !ReadString(env, argv[0], &name) ||
      !ReadString(env, argv[1], &format_name)) {
    ThrowError(env, "libmpv-invalid-observer",
               "observeProperty expects a name and format.");
    return nullptr;
  }

  mpv_format format = FormatFromName(format_name);
  if (format == MPV_FORMAT_NONE) {
    ThrowError(env, "libmpv-invalid-observer",
               "Unsupported libmpv property observer format.");
    return nullptr;
  }

  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->handle == nullptr) {
    ThrowError(env, "libmpv-not-initialized", "libmpv is not initialized.");
    return nullptr;
  }

  int status = mpv_observe_property(state->handle, 0, name.c_str(), format);
  if (status < 0) {
    ThrowError(env, "libmpv-observer-failed",
               Message("libmpv property observer failed", status));
    return nullptr;
  }

  return Undefined(env);
}

napi_value UpdateSystemMediaSession(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  PlayerState* state = UnwrapPlayer(env, info, argc, argv);
  if (state == nullptr) return nullptr;

  napi_valuetype metadata_type;
  napi_valuetype options_type;
  if (argc < 2 || napi_typeof(env, argv[0], &metadata_type) != napi_ok ||
      napi_typeof(env, argv[1], &options_type) != napi_ok ||
      metadata_type != napi_object || options_type != napi_object) {
    ThrowError(env, "libmpv-invalid-system-media-session",
               "updateSystemMediaSession expects metadata and state objects.");
    return nullptr;
  }

  SystemMediaSessionMetadata metadata;
  if (!ReadOptionalStringProperty(env, argv[0], "title", &metadata.title) ||
      !ReadOptionalStringProperty(env, argv[0], "artist", &metadata.artist) ||
      !ReadOptionalStringProperty(env, argv[0], "album", &metadata.album) ||
      !ReadOptionalStringProperty(env, argv[0], "artworkUrl",
                                  &metadata.artwork_url) ||
      !ReadOptionalNumberProperty(env, argv[1], "duration", &metadata.duration)) {
    ThrowError(env, "libmpv-invalid-system-media-session",
               "System media session metadata is invalid.");
    return nullptr;
  }

  std::string state_name;
  double position = 0;
  if (!ReadOptionalStringProperty(env, argv[1], "state", &state_name) ||
      !ReadOptionalNumberProperty(env, argv[1], "position", &position)) {
    ThrowError(env, "libmpv-invalid-system-media-session",
               "System media session state is invalid.");
    return nullptr;
  }

  SystemMediaSessionPlaybackState playback_state =
      SystemMediaSessionPlaybackState::kPaused;
  if (state_name == "playing") {
    playback_state = SystemMediaSessionPlaybackState::kPlaying;
  } else if (state_name == "stopped") {
    playback_state = SystemMediaSessionPlaybackState::kStopped;
  }

  UpdateSystemMediaSession(metadata, playback_state, position);
  return Undefined(env);
}

napi_value ClearSystemMediaSessionCallback(napi_env env,
                                           napi_callback_info info) {
  size_t argc = 0;
  napi_value argv[1];
  PlayerState* state = UnwrapPlayer(env, info, argc, argv);
  if (state == nullptr) return nullptr;

  ClearSystemMediaSession();
  return Undefined(env);
}

napi_value Destroy(napi_env env, napi_callback_info info) {
  size_t argc = 0;
  napi_value argv[1];
  PlayerState* state = UnwrapPlayer(env, info, argc, argv);
  if (state == nullptr) return nullptr;

  state->running.store(false);

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->handle != nullptr) {
      const char* quit_command[] = {"quit", nullptr};
      mpv_command(state->handle, quit_command);
      mpv_wakeup(state->handle);
    }
  }

  if (state->event_thread.joinable()) {
    state->event_thread.join();
  }

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->handle != nullptr) {
      mpv_terminate_destroy(state->handle);
      state->handle = nullptr;
    }
  }

  if (state->tsfn != nullptr) {
    napi_release_threadsafe_function(state->tsfn, napi_tsfn_abort);
    state->tsfn = nullptr;
  }

  ClearSystemMediaCommandHandler(state);
  ClearSystemMediaSession();

  return Undefined(env);
}

napi_value RuntimeInfo(napi_env env, napi_callback_info /*info*/) {
  napi_value object;
  napi_create_object(env, &object);

  SetString(env, object, "clientApiVersion",
            std::to_string(MPV_CLIENT_API_VERSION));

  return object;
}

void DefineMethod(napi_env env, napi_value object, const char* name,
                  napi_callback callback) {
  napi_value function;
  napi_create_function(env, name, NAPI_AUTO_LENGTH, callback, nullptr,
                       &function);
  napi_set_named_property(env, object, name, function);
}

napi_value CreatePlayer(napi_env env, napi_callback_info /*info*/) {
  auto* state = new PlayerState();
  state->env = env;

  napi_value object;
  napi_create_object(env, &object);

  napi_status status = napi_wrap(env, object, state, FinalizePlayer, nullptr,
                                 &state->wrapper);
  if (status != napi_ok) {
    delete state;
    ThrowError(env, "libmpv-napi-error", "Failed to wrap libmpv player.");
    return nullptr;
  }

  DefineMethod(env, object, "setEventCallback", SetEventCallback);
  DefineMethod(env, object, "initialize", Initialize);
  DefineMethod(env, object, "command", Command);
  DefineMethod(env, object, "setProperty", SetProperty);
  DefineMethod(env, object, "observeProperty", ObserveProperty);
  DefineMethod(env, object, "updateSystemMediaSession", UpdateSystemMediaSession);
  DefineMethod(env, object, "clearSystemMediaSession",
               ClearSystemMediaSessionCallback);
  DefineMethod(env, object, "destroy", Destroy);

  return object;
}

napi_value Init(napi_env env, napi_value exports) {
  DefineMethod(env, exports, "createPlayer", CreatePlayer);
  DefineMethod(env, exports, "runtimeInfo", RuntimeInfo);

  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
