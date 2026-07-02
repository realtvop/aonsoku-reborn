use std::time::Duration;

fn main() {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();

    let result = if std::env::var("AONSOKU_PLAYERD_BACKEND").as_deref() == Ok("mock") {
        let mut service = aonsoku_playerd::service::PlayerService::new(
            aonsoku_playerd::backend::MockPlaybackBackend::new(),
        );
        aonsoku_playerd::transport::run_ndjson_with_events(
            &mut service,
            stdin,
            stdout.lock(),
            Duration::from_millis(250),
        )
    } else {
        match aonsoku_playerd::rodio_backend::RodioPlaybackBackend::new() {
            Ok(backend) => {
                let mut service = aonsoku_playerd::service::PlayerService::new(backend);
                aonsoku_playerd::transport::run_ndjson_with_events(
                    &mut service,
                    stdin,
                    stdout.lock(),
                    Duration::from_millis(250),
                )
            }
            Err(error) => {
                eprintln!("aonsoku-playerd backend error: {}", error.message);
                std::process::exit(1);
            }
        }
    };

    if let Err(error) = result {
        eprintln!("aonsoku-playerd transport error: {error}");
        std::process::exit(1);
    }
}
