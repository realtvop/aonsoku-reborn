use crate::protocol::{
    EndedReason, NativeAudioBufferingChangedEvent, NativeAudioDurationChangedEvent,
    NativeAudioEndedEvent, NativeAudioErrorEvent, NativeAudioLoadOptions, NativeAudioProgressEvent,
    NativeAudioSeekOptions, NativeAudioSource, PlaybackState, PlayerEvent,
};

pub trait PlaybackBackend {
    fn load(&mut self, options: NativeAudioLoadOptions) -> Result<Vec<PlayerEvent>, BackendError>;
    fn play(&mut self, request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError>;
    fn pause(&mut self, request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError>;
    fn stop(&mut self, request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError>;
    fn seek(
        &mut self,
        options: NativeAudioSeekOptions,
        request_id: Option<String>,
    ) -> Result<Vec<PlayerEvent>, BackendError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendError {
    pub code: String,
    pub message: String,
}

impl BackendError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct MockPlaybackBackend {
    state: PlaybackState,
    position: f64,
    duration: f64,
    loaded: bool,
}

impl Default for MockPlaybackBackend {
    fn default() -> Self {
        Self {
            state: PlaybackState::Idle,
            position: 0.0,
            duration: 0.0,
            loaded: false,
        }
    }
}

impl MockPlaybackBackend {
    pub fn new() -> Self {
        Self::default()
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
            current_time: self.position,
            duration: self.duration,
            buffered_time: Some(self.duration),
        })
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

    fn validate_source(source: &NativeAudioSource) -> Result<(), BackendError> {
        let valid = match source {
            NativeAudioSource::Stream { url, .. }
            | NativeAudioSource::Blob { url, .. }
            | NativeAudioSource::Radio { url, .. } => !url.is_empty(),
            NativeAudioSource::NativeFile { uri, .. } => !uri.is_empty(),
        };

        if valid {
            Ok(())
        } else {
            Err(BackendError::new(
                "INVALID_SOURCE",
                "load source must include a url or uri",
            ))
        }
    }
}

impl PlaybackBackend for MockPlaybackBackend {
    fn load(&mut self, options: NativeAudioLoadOptions) -> Result<Vec<PlayerEvent>, BackendError> {
        Self::validate_source(&options.source)?;

        let request_id = options.request_id.clone();
        self.loaded = true;
        self.position = options.start_time.unwrap_or(0.0).max(0.0);
        self.duration = options
            .metadata
            .as_ref()
            .and_then(|metadata| metadata.duration)
            .unwrap_or(0.0)
            .max(0.0);

        let mut events = Vec::new();
        self.state = PlaybackState::Loading;
        events.push(self.state_event(request_id.clone()));
        events.push(PlayerEvent::BufferingChanged(
            NativeAudioBufferingChangedEvent {
                request_id: request_id.clone(),
                is_buffering: true,
            },
        ));
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

        self.state = if options.autoplay.unwrap_or(false) {
            PlaybackState::Playing
        } else {
            PlaybackState::Paused
        };
        events.push(self.state_event(request_id.clone()));
        events.push(self.progress_event(request_id));
        Ok(events)
    }

    fn play(&mut self, request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError> {
        self.require_loaded()?;
        self.state = PlaybackState::Playing;
        Ok(vec![
            self.state_event(request_id.clone()),
            self.progress_event(request_id),
        ])
    }

    fn pause(&mut self, request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError> {
        self.require_loaded()?;
        self.state = PlaybackState::Paused;
        Ok(vec![
            self.state_event(request_id.clone()),
            self.progress_event(request_id),
        ])
    }

    fn stop(&mut self, request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError> {
        self.require_loaded()?;
        self.state = PlaybackState::Stopped;
        self.position = 0.0;
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

        self.position = if self.duration > 0.0 {
            options.position.min(self.duration)
        } else {
            options.position
        };
        Ok(vec![self.progress_event(request_id)])
    }
}

pub fn error_event(error: &BackendError, request_id: Option<String>) -> PlayerEvent {
    PlayerEvent::Error(NativeAudioErrorEvent {
        request_id,
        code: Some(error.code.clone()),
        message: error.message.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::NativeAudioMetadata;

    #[test]
    fn mock_backend_load_play_pause_stop_seek_flow_emits_events() {
        let mut backend = MockPlaybackBackend::new();
        let load_events = backend
            .load(NativeAudioLoadOptions {
                source: NativeAudioSource::Stream {
                    url: "https://example.test/song.flac".to_string(),
                    song_id: Some("song-1".to_string()),
                },
                metadata: Some(NativeAudioMetadata {
                    duration: Some(120.0),
                    ..NativeAudioMetadata::default()
                }),
                autoplay: Some(false),
                start_time: Some(5.0),
                request_id: Some("load-1".to_string()),
            })
            .unwrap();

        assert!(matches!(
            load_events.last(),
            Some(PlayerEvent::Progress(event))
                if event.current_time == 5.0 && event.duration == 120.0
        ));

        let play_events = backend.play(Some("play-1".to_string())).unwrap();
        assert!(matches!(
            play_events.first(),
            Some(PlayerEvent::PlaybackStateChanged(event))
                if event.state == PlaybackState::Playing
        ));

        let seek_events = backend
            .seek(
                NativeAudioSeekOptions { position: 30.0 },
                Some("seek-1".to_string()),
            )
            .unwrap();
        assert!(matches!(
            seek_events.first(),
            Some(PlayerEvent::Progress(event)) if event.current_time == 30.0
        ));

        let pause_events = backend.pause(Some("pause-1".to_string())).unwrap();
        assert!(matches!(
            pause_events.first(),
            Some(PlayerEvent::PlaybackStateChanged(event))
                if event.state == PlaybackState::Paused
        ));

        let stop_events = backend.stop(Some("stop-1".to_string())).unwrap();
        assert!(matches!(
            stop_events.last(),
            Some(PlayerEvent::Ended(event)) if event.reason == Some(EndedReason::Stopped)
        ));
    }
}
