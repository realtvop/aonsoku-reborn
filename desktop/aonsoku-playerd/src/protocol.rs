use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const JSONRPC_VERSION: &str = "2.0";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: RequestId,
    #[serde(flatten)]
    pub command: PlayerCommand,
}

impl JsonRpcRequest {
    pub fn new(id: RequestId, command: PlayerCommand) -> Self {
        Self {
            jsonrpc: JSONRPC_VERSION.to_string(),
            id,
            command,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RequestId {
    String(String),
    Number(i64),
}

impl RequestId {
    pub fn as_event_request_id(&self) -> String {
        match self {
            Self::String(value) => value.clone(),
            Self::Number(value) => value.to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "method", content = "params")]
#[serde(rename_all = "camelCase")]
pub enum PlayerCommand {
    Load(NativeAudioLoadOptions),
    Play,
    Pause,
    Stop,
    Seek(NativeAudioSeekOptions),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JsonRpcSuccess {
    pub jsonrpc: String,
    pub id: RequestId,
    pub result: Value,
}

impl JsonRpcSuccess {
    pub fn empty(id: RequestId) -> Self {
        Self {
            jsonrpc: JSONRPC_VERSION.to_string(),
            id,
            result: Value::Object(Default::default()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JsonRpcFailure {
    pub jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<RequestId>,
    pub error: JsonRpcError,
}

impl JsonRpcFailure {
    pub fn new(id: Option<RequestId>, code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: JSONRPC_VERSION.to_string(),
            id,
            error: JsonRpcError {
                code,
                message: message.into(),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JsonRpcError {
    pub code: ErrorCode,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    InvalidRequest,
    InvalidParams,
    BackendError,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", content = "payload")]
#[serde(rename_all = "camelCase")]
pub enum PlayerEvent {
    PlaybackStateChanged(NativeAudioPlaybackStateChangedEvent),
    Progress(NativeAudioProgressEvent),
    DurationChanged(NativeAudioDurationChangedEvent),
    BufferingChanged(NativeAudioBufferingChangedEvent),
    Ended(NativeAudioEndedEvent),
    Error(NativeAudioErrorEvent),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum NativeAudioSource {
    #[serde(rename_all = "camelCase")]
    Stream {
        url: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        song_id: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Blob {
        url: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        song_id: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    NativeFile {
        uri: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        song_id: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Radio {
        url: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        radio_id: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioMetadata {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artwork_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_art_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioLoadOptions {
    pub source: NativeAudioSource,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<NativeAudioMetadata>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub autoplay: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_time: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioSeekOptions {
    pub position: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PlaybackState {
    Idle,
    Loading,
    Playing,
    Paused,
    Stopped,
    Ended,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioPlaybackStateChangedEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub state: PlaybackState,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioProgressEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub current_time: f64,
    pub duration: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub buffered_time: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioDurationChangedEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub duration: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioBufferingChangedEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub is_buffering: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EndedReason {
    Finished,
    Stopped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioEndedEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<EndedReason>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeAudioErrorEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn load_request_matches_audio_contract_shape() {
        let request = JsonRpcRequest::new(
            RequestId::String("req-1".to_string()),
            PlayerCommand::Load(NativeAudioLoadOptions {
                source: NativeAudioSource::Stream {
                    url: "https://example.test/song.flac".to_string(),
                    song_id: Some("song-1".to_string()),
                },
                metadata: Some(NativeAudioMetadata {
                    title: Some("Intro".to_string()),
                    artist: Some("Aonsoku".to_string()),
                    duration: Some(180.5),
                    ..NativeAudioMetadata::default()
                }),
                autoplay: Some(true),
                start_time: Some(12.25),
                request_id: Some("load-1".to_string()),
            }),
        );

        assert_eq!(
            serde_json::to_value(request).unwrap(),
            json!({
                "jsonrpc": "2.0",
                "id": "req-1",
                "method": "load",
                "params": {
                    "source": {
                        "kind": "stream",
                        "url": "https://example.test/song.flac",
                        "songId": "song-1"
                    },
                    "metadata": {
                        "title": "Intro",
                        "artist": "Aonsoku",
                        "duration": 180.5,
                    },
                    "autoplay": true,
                    "startTime": 12.25,
                    "requestId": "load-1"
                }
            })
        );
    }

    #[test]
    fn progress_event_matches_audio_contract_shape() {
        let event = PlayerEvent::Progress(NativeAudioProgressEvent {
            request_id: Some("seek-1".to_string()),
            current_time: 42.0,
            duration: 240.0,
            buffered_time: Some(90.0),
        });

        assert_eq!(
            serde_json::to_value(event).unwrap(),
            json!({
                "event": "progress",
                "payload": {
                    "requestId": "seek-1",
                    "currentTime": 42.0,
                    "duration": 240.0,
                    "bufferedTime": 90.0
                }
            })
        );
    }
}
