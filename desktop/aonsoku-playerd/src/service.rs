use crate::backend::{error_event, BackendError, PlaybackBackend};
use crate::protocol::{
    ErrorCode, JsonRpcFailure, JsonRpcRequest, JsonRpcSuccess, PlayerCommand, PlayerEvent,
};

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(untagged)]
pub enum OutboundMessage {
    Success(JsonRpcSuccess),
    Failure(JsonRpcFailure),
    Event(PlayerEvent),
}

pub struct PlayerService<TBackend> {
    backend: TBackend,
}

impl<TBackend> PlayerService<TBackend>
where
    TBackend: PlaybackBackend,
{
    pub fn new(backend: TBackend) -> Self {
        Self { backend }
    }

    pub fn handle(&mut self, request: JsonRpcRequest) -> Vec<OutboundMessage> {
        let id = request.id.clone();
        let event_request_id = id.as_event_request_id();

        match self.dispatch(request.command, event_request_id.clone()) {
            Ok(events) => {
                let mut messages = Vec::with_capacity(events.len() + 1);
                messages.push(OutboundMessage::Success(JsonRpcSuccess::empty(id)));
                messages.extend(events.into_iter().map(OutboundMessage::Event));
                messages
            }
            Err(error) => vec![
                OutboundMessage::Failure(JsonRpcFailure::new(
                    Some(id),
                    ErrorCode::BackendError,
                    error.message.clone(),
                )),
                OutboundMessage::Event(error_event(&error, Some(event_request_id))),
            ],
        }
    }

    fn dispatch(
        &mut self,
        command: PlayerCommand,
        fallback_request_id: String,
    ) -> Result<Vec<PlayerEvent>, BackendError> {
        match command {
            PlayerCommand::Load(mut options) => {
                options.request_id = options.request_id.or(Some(fallback_request_id));
                self.backend.load(options)
            }
            PlayerCommand::Play => self.backend.play(Some(fallback_request_id)),
            PlayerCommand::Pause => self.backend.pause(Some(fallback_request_id)),
            PlayerCommand::Stop => self.backend.stop(Some(fallback_request_id)),
            PlayerCommand::Seek(options) => self.backend.seek(options, Some(fallback_request_id)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::MockPlaybackBackend;
    use crate::protocol::{
        NativeAudioLoadOptions, NativeAudioMetadata, NativeAudioSeekOptions, NativeAudioSource,
        PlaybackState, RequestId,
    };

    #[test]
    fn service_returns_response_then_events() {
        let mut service = PlayerService::new(MockPlaybackBackend::new());

        let messages = service.handle(JsonRpcRequest::new(
            RequestId::Number(1),
            PlayerCommand::Load(NativeAudioLoadOptions {
                source: NativeAudioSource::Stream {
                    url: "https://example.test/song.flac".to_string(),
                    song_id: None,
                },
                metadata: Some(NativeAudioMetadata {
                    duration: Some(90.0),
                    ..NativeAudioMetadata::default()
                }),
                autoplay: Some(true),
                start_time: None,
                request_id: None,
            }),
        ));

        assert!(matches!(
            messages.first(),
            Some(OutboundMessage::Success(success)) if success.id == RequestId::Number(1)
        ));
        assert!(messages.iter().any(|message| matches!(
            message,
            OutboundMessage::Event(PlayerEvent::PlaybackStateChanged(event))
                if event.state == PlaybackState::Playing
        )));
    }

    #[test]
    fn service_reports_backend_errors_as_response_and_event() {
        let mut service = PlayerService::new(MockPlaybackBackend::new());

        let messages = service.handle(JsonRpcRequest::new(
            RequestId::String("seek-before-load".to_string()),
            PlayerCommand::Seek(NativeAudioSeekOptions { position: 10.0 }),
        ));

        assert!(matches!(
            messages.first(),
            Some(OutboundMessage::Failure(failure))
                if failure.error.code == ErrorCode::BackendError
        ));
        assert!(matches!(
            messages.get(1),
            Some(OutboundMessage::Event(PlayerEvent::Error(error)))
                if error.code.as_deref() == Some("NOT_LOADED")
        ));
    }
}
