use std::fs::File;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use rodio::{Decoder, DeviceSinkBuilder, MixerDeviceSink, Player, Source};

use crate::backend::{BackendError, PlaybackBackend};
use crate::protocol::{
    EndedReason, NativeAudioBufferingChangedEvent, NativeAudioDurationChangedEvent,
    NativeAudioEndedEvent, NativeAudioErrorEvent, NativeAudioLoadOptions, NativeAudioProgressEvent,
    NativeAudioSeekOptions, NativeAudioSource, PlaybackState, PlayerEvent,
};

const DEFAULT_HTTP_BODY_LIMIT: u64 = 256 * 1024 * 1024;
const PROGRESS_EVENT_INTERVAL: Duration = Duration::from_millis(500);

pub struct RodioPlaybackBackend {
    device_sink: MixerDeviceSink,
    player: Option<Player>,
    state: PlaybackState,
    duration: f64,
    loaded: bool,
    last_progress_event_at: Option<Instant>,
    runtime_errors: mpsc::Receiver<String>,
}

impl RodioPlaybackBackend {
    pub fn new() -> Result<Self, BackendError> {
        let (runtime_error_tx, runtime_errors) = mpsc::channel();
        let mut device_sink = open_output_sink(runtime_error_tx).map_err(|error| {
            BackendError::new(
                "OUTPUT_DEVICE_ERROR",
                format!("open output device: {error}"),
            )
        })?;
        device_sink.log_on_drop(false);

        Ok(Self {
            device_sink,
            player: None,
            state: PlaybackState::Idle,
            duration: 0.0,
            loaded: false,
            last_progress_event_at: None,
            runtime_errors,
        })
    }

    fn state_event(&self, request_id: Option<String>) -> PlayerEvent {
        PlayerEvent::PlaybackStateChanged(crate::protocol::NativeAudioPlaybackStateChangedEvent {
            request_id,
            state: self.state,
        })
    }

    fn progress_event(&self, request_id: Option<String>) -> PlayerEvent {
        PlayerEvent::Progress(NativeAudioProgressEvent {
            request_id,
            current_time: self.position(),
            duration: self.duration,
            buffered_time: Some(self.duration),
        })
    }

    fn position(&self) -> f64 {
        self.player
            .as_ref()
            .map(|player| player.get_pos().as_secs_f64())
            .unwrap_or(0.0)
    }

    fn require_loaded(&self) -> Result<(), BackendError> {
        if self.loaded {
            Ok(())
        } else {
            Err(BackendError::new(
                "NOT_LOADED",
                "cannot control playback before load",
            ))
        }
    }

    fn load_source(&self, source: &NativeAudioSource) -> Result<LoadedSource, BackendError> {
        match source {
            NativeAudioSource::Stream { url, .. }
            | NativeAudioSource::Blob { url, .. }
            | NativeAudioSource::Radio { url, .. } => load_url_source(url),
            NativeAudioSource::NativeFile { uri, .. } => load_file_source(uri),
        }
    }

    fn install_loaded_source(
        &mut self,
        source: LoadedSource,
        request_id: Option<String>,
        autoplay: bool,
        start_time: f64,
    ) -> Result<Vec<PlayerEvent>, BackendError> {
        if let Some(player) = self.player.take() {
            player.stop();
        }

        self.state = PlaybackState::Loading;
        self.loaded = false;
        let mut events = vec![
            self.state_event(request_id.clone()),
            PlayerEvent::BufferingChanged(NativeAudioBufferingChangedEvent {
                request_id: request_id.clone(),
                is_buffering: true,
            }),
        ];

        let (player, duration) = match source {
            LoadedSource::File { file, byte_len, hint } => {
                self.player_from_reader(file, byte_len, hint.as_deref(), start_time)?
            }
            LoadedSource::Memory { bytes, hint } => {
                let byte_len = bytes.len() as u64;
                self.player_from_reader(Cursor::new(bytes), byte_len, hint.as_deref(), start_time)?
            }
        };

        if autoplay {
            player.play();
            self.state = PlaybackState::Playing;
        } else {
            player.pause();
            self.state = PlaybackState::Paused;
        }

        self.duration = duration;
        self.loaded = true;
        self.player = Some(player);
        self.last_progress_event_at = Some(Instant::now());

        events.push(PlayerEvent::DurationChanged(
            NativeAudioDurationChangedEvent {
                request_id: request_id.clone(),
                duration: self.duration,
            },
        ));
        events.push(PlayerEvent::BufferingChanged(
            NativeAudioBufferingChangedEvent {
                request_id: request_id.clone(),
                is_buffering: false,
            },
        ));
        events.push(self.state_event(request_id.clone()));
        events.push(self.progress_event(request_id));

        Ok(events)
    }

    fn player_from_reader<R>(
        &self,
        reader: R,
        byte_len: u64,
        hint: Option<&str>,
        start_time: f64,
    ) -> Result<(Player, f64), BackendError>
    where
        R: std::io::Read + std::io::Seek + Send + Sync + 'static,
    {
        let mut builder = Decoder::builder()
            .with_data(reader)
            .with_byte_len(byte_len);

        if let Some(h) = hint {
            builder = builder.with_hint(h);
        }

        let decoder = builder
            .build()
            .map_err(|error| BackendError::new("DECODE_ERROR", format!("decode audio: {error}")))?;
        let duration = decoder
            .total_duration()
            .map(|duration| duration.as_secs_f64())
            .unwrap_or(0.0);
        let player = Player::connect_new(self.device_sink.mixer());
        player.append(decoder);

        if start_time > 0.0 {
            player
                .try_seek(Duration::from_secs_f64(start_time))
                .map_err(|error| BackendError::new("SEEK_ERROR", format!("seek audio: {error}")))?;
        }

        Ok((player, duration))
    }
}

impl PlaybackBackend for RodioPlaybackBackend {
    fn load(&mut self, options: NativeAudioLoadOptions) -> Result<Vec<PlayerEvent>, BackendError> {
        let request_id = options.request_id.clone();
        let start_time = options.start_time.unwrap_or(0.0);
        if start_time.is_sign_negative() {
            return Err(BackendError::new(
                "INVALID_POSITION",
                "start time must be non-negative",
            ));
        }

        let source = self.load_source(&options.source)?;
        self.install_loaded_source(
            source,
            request_id,
            options.autoplay.unwrap_or(false),
            start_time,
        )
    }

    fn play(&mut self, request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError> {
        self.require_loaded()?;
        if let Some(player) = &self.player {
            player.play();
        }
        self.state = PlaybackState::Playing;
        Ok(vec![
            self.state_event(request_id.clone()),
            self.progress_event(request_id),
        ])
    }

    fn pause(&mut self, request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError> {
        self.require_loaded()?;
        if let Some(player) = &self.player {
            player.pause();
        }
        self.state = PlaybackState::Paused;
        Ok(vec![
            self.state_event(request_id.clone()),
            self.progress_event(request_id),
        ])
    }

    fn stop(&mut self, request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError> {
        self.require_loaded()?;
        if let Some(player) = self.player.take() {
            player.stop();
        }
        self.state = PlaybackState::Stopped;
        self.loaded = false;
        self.last_progress_event_at = None;
        Ok(vec![
            self.state_event(request_id.clone()),
            self.progress_event(request_id.clone()),
            PlayerEvent::Ended(NativeAudioEndedEvent {
                request_id,
                reason: Some(EndedReason::Stopped),
            }),
        ])
    }

    fn seek(
        &mut self,
        options: NativeAudioSeekOptions,
        request_id: Option<String>,
    ) -> Result<Vec<PlayerEvent>, BackendError> {
        self.require_loaded()?;
        if options.position.is_sign_negative() {
            return Err(BackendError::new(
                "INVALID_POSITION",
                "seek position must be non-negative",
            ));
        }

        if let Some(player) = &self.player {
            player
                .try_seek(Duration::from_secs_f64(options.position))
                .map_err(|error| BackendError::new("SEEK_ERROR", format!("seek audio: {error}")))?;
        }

        Ok(vec![self.progress_event(request_id)])
    }

    fn drain_events(&mut self) -> Vec<PlayerEvent> {
        let runtime_errors = drain_runtime_error_events(&self.runtime_errors);
        if !runtime_errors.is_empty() {
            self.state = PlaybackState::Failed;
            return std::iter::once(self.state_event(None))
                .chain(runtime_errors)
                .collect();
        }

        let Some(player) = &self.player else {
            return Vec::new();
        };

        if self.state == PlaybackState::Playing && player.empty() {
            self.state = PlaybackState::Ended;
            self.loaded = false;
            self.last_progress_event_at = None;
            return vec![
                self.progress_event(None),
                self.state_event(None),
                PlayerEvent::Ended(NativeAudioEndedEvent {
                    request_id: None,
                    reason: Some(EndedReason::Finished),
                }),
            ];
        }

        if self.state != PlaybackState::Playing {
            return Vec::new();
        }

        let now = Instant::now();
        let should_emit = self
            .last_progress_event_at
            .map(|last| now.duration_since(last) >= PROGRESS_EVENT_INTERVAL)
            .unwrap_or(true);
        if !should_emit {
            return Vec::new();
        }

        self.last_progress_event_at = Some(now);
        vec![self.progress_event(None)]
    }
}

fn open_output_sink(
    runtime_error_tx: mpsc::Sender<String>,
) -> Result<MixerDeviceSink, rodio::stream::DeviceSinkError> {
    match DeviceSinkBuilder::from_default_device() {
        Ok(builder) => {
            let error_callback = move |error| {
                let _ = runtime_error_tx.send(format!("audio stream error: {error}"));
            };
            builder
                .with_error_callback(error_callback)
                .open_sink_or_fallback()
        }
        Err(_) => DeviceSinkBuilder::open_default_sink(),
    }
}

fn drain_runtime_error_events(runtime_errors: &mpsc::Receiver<String>) -> Vec<PlayerEvent> {
    let mut events = Vec::new();

    while let Ok(message) = runtime_errors.try_recv() {
        events.push(PlayerEvent::Error(NativeAudioErrorEvent {
            request_id: None,
            code: Some("AUDIO_STREAM_ERROR".to_string()),
            message,
        }));
    }

    events
}

fn get_format_hint(url: &str, mime_type: Option<&str>) -> Option<&'static str> {
    if let Some(mime) = mime_type {
        let mime = mime.to_lowercase();
        if mime.contains("mpeg") || mime.contains("mp3") {
            return Some("mp3");
        } else if mime.contains("flac") {
            return Some("flac");
        } else if mime.contains("aac") {
            return Some("aac");
        } else if mime.contains("mp4") || mime.contains("m4a") {
            return Some("m4a");
        } else if mime.contains("ogg") || mime.contains("vorbis") {
            return Some("ogg");
        } else if mime.contains("wav") || mime.contains("wave") {
            return Some("wav");
        }
    }

    let url_lower = url.to_lowercase();
    if url_lower.contains("format=mp3") || url_lower.contains(".mp3") {
        Some("mp3")
    } else if url_lower.contains("format=flac") || url_lower.contains(".flac") {
        Some("flac")
    } else if url_lower.contains("format=aac") || url_lower.contains(".aac") {
        Some("aac")
    } else if url_lower.contains("format=m4a") || url_lower.contains(".m4a") || url_lower.contains("format=mp4") || url_lower.contains(".mp4") {
        Some("m4a")
    } else if url_lower.contains("format=ogg") || url_lower.contains(".ogg") || url_lower.contains("format=vorbis") || url_lower.contains(".opus") || url_lower.contains("format=opus") {
        Some("ogg")
    } else if url_lower.contains("format=wav") || url_lower.contains(".wav") {
        Some("wav")
    } else {
        None
    }
}

enum LoadedSource {
    File {
        file: File,
        byte_len: u64,
        hint: Option<String>,
    },
    Memory {
        bytes: Vec<u8>,
        hint: Option<String>,
    },
}

fn load_url_source(url: &str) -> Result<LoadedSource, BackendError> {
    if url.trim().is_empty() {
        return Err(BackendError::new(
            "INVALID_SOURCE",
            "load source must include a url",
        ));
    }

    let mut response = ureq::get(url)
        .call()
        .map_err(|error| BackendError::new("NETWORK_ERROR", format!("fetch audio: {error}")))?;
    let status = response.status();
    if !status.is_success() {
        return Err(BackendError::new(
            "NETWORK_ERROR",
            format!("fetch audio returned HTTP {status}"),
        ));
    }

    let mime_type = response
        .headers()
        .get("content-type")
        .and_then(|val| val.to_str().ok());
    let hint = get_format_hint(url, mime_type).map(|s| s.to_string());

    eprintln!("[audio-sidecar-log] URL: {}, MIME-type: {:?}, Hint: {:?}", url, mime_type, hint);

    let bytes = response
        .body_mut()
        .with_config()
        .limit(DEFAULT_HTTP_BODY_LIMIT)
        .read_to_vec()
        .map_err(|error| BackendError::new("NETWORK_ERROR", format!("read audio: {error}")))?;
    if bytes.is_empty() {
        return Err(BackendError::new(
            "EMPTY_SOURCE",
            "audio response was empty",
        ));
    }

    Ok(LoadedSource::Memory { bytes, hint })
}

fn load_file_source(uri: &str) -> Result<LoadedSource, BackendError> {
    let path = native_file_path(uri)?;
    let file = File::open(&path).map_err(|error| {
        BackendError::new(
            "FILE_ERROR",
            format!("open audio file {}: {error}", path.display()),
        )
    })?;
    let byte_len = file
        .metadata()
        .map_err(|error| BackendError::new("FILE_ERROR", format!("stat audio file: {error}")))?
        .len();
    if byte_len == 0 {
        return Err(BackendError::new("EMPTY_SOURCE", "audio file was empty"));
    }

    let hint = get_format_hint(uri, None).map(|s| s.to_string());

    eprintln!("[audio-sidecar-log] URI: {}, Hint: {:?}", uri, hint);

    Ok(LoadedSource::File { file, byte_len, hint })
}

fn native_file_path(uri: &str) -> Result<PathBuf, BackendError> {
    if uri.trim().is_empty() {
        return Err(BackendError::new(
            "INVALID_SOURCE",
            "load source must include a uri",
        ));
    }

    if let Some(file_url) = uri.strip_prefix("file://") {
        let decoded = percent_decode_file_url_path(file_url_path(file_url)?)?;
        Ok(Path::new(&decoded).to_path_buf())
    } else {
        Ok(Path::new(uri).to_path_buf())
    }
}

fn file_url_path(file_url: &str) -> Result<&str, BackendError> {
    if let Some(path) = file_url.strip_prefix("localhost") {
        if path.starts_with('/') {
            return Ok(path);
        }
    }

    if file_url.starts_with('/') {
        return Ok(file_url);
    }

    Err(BackendError::new(
        "INVALID_SOURCE",
        "file uri host must be empty or localhost",
    ))
}

fn percent_decode_file_url_path(path: &str) -> Result<String, BackendError> {
    let bytes = path.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] != b'%' {
            decoded.push(bytes[index]);
            index += 1;
            continue;
        }

        let Some(hex) = bytes.get(index + 1..index + 3) else {
            return Err(BackendError::new(
                "INVALID_SOURCE",
                "file uri contains an invalid percent escape",
            ));
        };
        let value = decode_hex_pair(hex).ok_or_else(|| {
            BackendError::new(
                "INVALID_SOURCE",
                "file uri contains an invalid percent escape",
            )
        })?;
        decoded.push(value);
        index += 3;
    }

    String::from_utf8(decoded).map_err(|error| {
        BackendError::new(
            "INVALID_SOURCE",
            format!("file uri path must decode to UTF-8: {error}"),
        )
    })
}

fn decode_hex_pair(hex: &[u8]) -> Option<u8> {
    let high = decode_hex_digit(*hex.first()?)?;
    let low = decode_hex_digit(*hex.get(1)?)?;
    Some((high << 4) | low)
}

fn decode_hex_digit(digit: u8) -> Option<u8> {
    match digit {
        b'0'..=b'9' => Some(digit - b'0'),
        b'a'..=b'f' => Some(digit - b'a' + 10),
        b'A'..=b'F' => Some(digit - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_file_path_accepts_file_uri_and_plain_path() {
        assert_eq!(
            native_file_path("file:///tmp/song.mp3").unwrap(),
            PathBuf::from("/tmp/song.mp3")
        );
        assert_eq!(
            native_file_path("file://localhost/tmp/song.mp3").unwrap(),
            PathBuf::from("/tmp/song.mp3")
        );
        assert_eq!(
            native_file_path("/tmp/song.mp3").unwrap(),
            PathBuf::from("/tmp/song.mp3")
        );
    }

    #[test]
    fn native_file_path_rejects_empty_uri() {
        let error = native_file_path(" ").unwrap_err();
        assert_eq!(error.code, "INVALID_SOURCE");
    }

    #[test]
    fn native_file_path_decodes_file_uri_percent_escapes() {
        assert_eq!(
            native_file_path("file:///tmp/Aonsoku%20Smoke%20%E2%99%AB.wav").unwrap(),
            PathBuf::from("/tmp/Aonsoku Smoke \u{266b}.wav")
        );
    }

    #[test]
    fn native_file_path_rejects_invalid_percent_escapes() {
        let error = native_file_path("file:///tmp/song%XZ.mp3").unwrap_err();

        assert_eq!(error.code, "INVALID_SOURCE");
    }

    #[test]
    fn native_file_path_rejects_remote_file_uri_hosts() {
        let error = native_file_path("file://example.test/tmp/song.mp3").unwrap_err();

        assert_eq!(error.code, "INVALID_SOURCE");
    }

    #[test]
    fn runtime_stream_errors_emit_error_events() {
        let (tx, rx) = mpsc::channel();
        tx.send("audio stream error: underrun".to_string()).unwrap();

        let events = drain_runtime_error_events(&rx);

        assert!(matches!(
            events.first(),
            Some(PlayerEvent::Error(event))
                if event.code.as_deref() == Some("AUDIO_STREAM_ERROR")
                    && event.message == "audio stream error: underrun"
        ));
    }

    #[test]
    fn get_format_hint_detects_proper_formats() {
        assert_eq!(get_format_hint("http://example.com/stream?format=flac", None), Some("flac"));
        assert_eq!(get_format_hint("http://example.com/song.mp3", None), Some("mp3"));
        assert_eq!(get_format_hint("http://example.com/stream", Some("audio/mpeg")), Some("mp3"));
        assert_eq!(get_format_hint("http://example.com/stream", Some("audio/x-m4a")), Some("m4a"));
        assert_eq!(get_format_hint("http://example.com/stream", Some("audio/aac")), Some("aac"));
        assert_eq!(get_format_hint("http://example.com/stream", None), None);
    }
}
