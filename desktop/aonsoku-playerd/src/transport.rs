use std::io::{BufRead, Write};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::Duration;

use crate::backend::PlaybackBackend;
use crate::protocol::{ErrorCode, JsonRpcFailure, JsonRpcRequest};
use crate::service::{OutboundMessage, PlayerService};

pub fn handle_ndjson_line<TBackend>(
    service: &mut PlayerService<TBackend>,
    line: &str,
) -> Vec<OutboundMessage>
where
    TBackend: PlaybackBackend,
{
    match serde_json::from_str(line) {
        Ok(value) => match JsonRpcRequest::from_value(value) {
            Ok(request) => service.handle(request),
            Err(error) => vec![OutboundMessage::Failure(JsonRpcFailure::new(
                error.id,
                error.code,
                error.message,
            ))],
        },
        Err(error) => vec![OutboundMessage::Failure(JsonRpcFailure::new(
            None,
            ErrorCode::InvalidRequest,
            format!("invalid JSON: {error}"),
        ))],
    }
}

pub fn run_ndjson<TBackend, TRead, TWrite>(
    service: &mut PlayerService<TBackend>,
    reader: TRead,
    mut writer: TWrite,
) -> std::io::Result<()>
where
    TBackend: PlaybackBackend,
    TRead: BufRead,
    TWrite: Write,
{
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        for message in handle_ndjson_line(service, &line) {
            serde_json::to_writer(&mut writer, &message)?;
            writer.write_all(b"\n")?;
        }
        writer.flush()?;
    }

    Ok(())
}

pub fn run_ndjson_with_events<TBackend, TRead, TWrite>(
    service: &mut PlayerService<TBackend>,
    reader: TRead,
    mut writer: TWrite,
    tick_interval: Duration,
) -> std::io::Result<()>
where
    TBackend: PlaybackBackend,
    TRead: std::io::Read + Send + 'static,
    TWrite: Write,
{
    let (line_tx, line_rx) = mpsc::channel();

    std::thread::spawn(move || {
        for line in std::io::BufReader::new(reader).lines() {
            if line_tx.send(line).is_err() {
                return;
            }
        }
    });

    loop {
        match line_rx.recv_timeout(tick_interval) {
            Ok(Ok(line)) => {
                if !line.trim().is_empty() {
                    write_messages(&mut writer, handle_ndjson_line(service, &line))?;
                }
            }
            Ok(Err(error)) => return Err(error),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                write_messages(&mut writer, service.drain_events())?;
                return Ok(());
            }
        }

        write_messages(&mut writer, service.drain_events())?;
    }
}

fn write_messages<TWrite>(
    writer: &mut TWrite,
    messages: Vec<OutboundMessage>,
) -> std::io::Result<()>
where
    TWrite: Write,
{
    if messages.is_empty() {
        return Ok(());
    }

    for message in messages {
        serde_json::to_writer(&mut *writer, &message)?;
        writer.write_all(b"\n")?;
    }
    writer.flush()
}

#[cfg(test)]
mod tests {
    use std::io::{BufReader, Cursor};
    use std::time::Duration;

    use super::*;
    use crate::backend::{BackendError, MockPlaybackBackend};
    use crate::protocol::{
        NativeAudioLoadOptions, NativeAudioProgressEvent, NativeAudioSeekOptions, PlayerEvent,
    };
    use crate::service::OutboundMessage;

    #[test]
    fn ndjson_transport_writes_response_and_events() {
        let input = concat!(
            "{\"jsonrpc\":\"2.0\",\"id\":\"load-1\",\"method\":\"load\",",
            "\"params\":{\"source\":{\"kind\":\"stream\",",
            "\"url\":\"https://example.test/song.flac\"},",
            "\"metadata\":{\"duration\":60},\"autoplay\":true}}\n",
            "{\"jsonrpc\":\"2.0\",\"id\":\"pause-1\",\"method\":\"pause\"}\n",
            "{\"jsonrpc\":\"2.0\",\"id\":\"seek-1\",\"method\":\"seek\",",
            "\"params\":{\"position\":12}}\n"
        );
        let mut output = Vec::new();
        let mut service = PlayerService::new(MockPlaybackBackend::new());

        run_ndjson(
            &mut service,
            BufReader::new(Cursor::new(input)),
            &mut output,
        )
        .unwrap();

        let lines = String::from_utf8(output).unwrap();
        let messages = lines
            .lines()
            .map(|line| serde_json::from_str::<OutboundMessage>(line).unwrap())
            .collect::<Vec<_>>();

        assert!(matches!(
            messages.first(),
            Some(OutboundMessage::Success(success))
                if success.id == crate::protocol::RequestId::String("load-1".to_string())
        ));
        assert!(messages.iter().any(|message| matches!(
            message,
            OutboundMessage::Event(crate::protocol::PlayerEvent::Progress(event))
                if event.current_time == 12.0
        )));
    }

    #[test]
    fn ndjson_transport_rejects_invalid_jsonrpc_version() {
        let mut service = PlayerService::new(MockPlaybackBackend::new());

        let messages = handle_ndjson_line(
            &mut service,
            "{\"jsonrpc\":\"1.0\",\"id\":\"bad-version\",\"method\":\"play\"}",
        );

        assert!(matches!(
            messages.first(),
            Some(OutboundMessage::Failure(failure))
                if failure.id == Some(crate::protocol::RequestId::String(
                    "bad-version".to_string()
                ))
                    && failure.error.code == ErrorCode::InvalidRequest
                    && failure.error.message == "jsonrpc must be \"2.0\""
        ));
    }

    #[test]
    fn ndjson_transport_rejects_malformed_request_shape() {
        let mut service = PlayerService::new(MockPlaybackBackend::new());

        let messages = handle_ndjson_line(&mut service, "[]");

        assert!(matches!(
            messages.first(),
            Some(OutboundMessage::Failure(failure))
                if failure.id.is_none()
                    && failure.error.code == ErrorCode::InvalidRequest
                    && failure.error.message == "request must be an object"
        ));
    }

    #[test]
    fn ndjson_transport_rejects_invalid_command_params() {
        let mut service = PlayerService::new(MockPlaybackBackend::new());

        let messages = handle_ndjson_line(
            &mut service,
            "{\"jsonrpc\":\"2.0\",\"id\":\"bad-seek\",\"method\":\"seek\",\
             \"params\":{\"position\":\"later\"}}",
        );

        assert!(matches!(
            messages.first(),
            Some(OutboundMessage::Failure(failure))
                if failure.id == Some(crate::protocol::RequestId::String(
                    "bad-seek".to_string()
                ))
                    && failure.error.code == ErrorCode::InvalidParams
        ));
    }

    #[test]
    fn ndjson_event_loop_drains_backend_events() {
        let mut output = Vec::new();
        let mut service = PlayerService::new(EventDrainBackend { drained: false });

        run_ndjson_with_events(
            &mut service,
            Cursor::new(""),
            &mut output,
            Duration::from_millis(1),
        )
        .unwrap();

        let lines = String::from_utf8(output).unwrap();
        let messages = lines
            .lines()
            .map(|line| serde_json::from_str::<OutboundMessage>(line).unwrap())
            .collect::<Vec<_>>();

        assert!(matches!(
            messages.first(),
            Some(OutboundMessage::Event(PlayerEvent::Progress(event)))
                if event.current_time == 7.0
        ));
    }

    struct EventDrainBackend {
        drained: bool,
    }

    impl PlaybackBackend for EventDrainBackend {
        fn load(
            &mut self,
            _options: NativeAudioLoadOptions,
        ) -> Result<Vec<PlayerEvent>, BackendError> {
            Ok(Vec::new())
        }

        fn play(&mut self, _request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError> {
            Ok(Vec::new())
        }

        fn pause(&mut self, _request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError> {
            Ok(Vec::new())
        }

        fn stop(&mut self, _request_id: Option<String>) -> Result<Vec<PlayerEvent>, BackendError> {
            Ok(Vec::new())
        }

        fn seek(
            &mut self,
            _options: NativeAudioSeekOptions,
            _request_id: Option<String>,
        ) -> Result<Vec<PlayerEvent>, BackendError> {
            Ok(Vec::new())
        }

        fn drain_events(&mut self) -> Vec<PlayerEvent> {
            if self.drained {
                return Vec::new();
            }
            self.drained = true;
            vec![PlayerEvent::Progress(NativeAudioProgressEvent {
                request_id: None,
                current_time: 7.0,
                duration: 10.0,
                buffered_time: Some(10.0),
            })]
        }
    }
}
