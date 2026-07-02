use std::io::{BufRead, Write};

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
    match serde_json::from_str::<JsonRpcRequest>(line) {
        Ok(request) => service.handle(request),
        Err(error) => vec![OutboundMessage::Failure(JsonRpcFailure::new(
            None,
            ErrorCode::InvalidRequest,
            format!("invalid JSON-RPC request: {error}"),
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

#[cfg(test)]
mod tests {
    use std::io::{BufReader, Cursor};

    use super::*;
    use crate::backend::MockPlaybackBackend;
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
}
