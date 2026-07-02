fn main() {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();

    let result = if std::env::var("AONSOKU_PLAYERD_BACKEND").as_deref() == Ok("mock") {
        let mut service = aonsoku_playerd::service::PlayerService::new(
            aonsoku_playerd::backend::MockPlaybackBackend::new(),
        );
        aonsoku_playerd::transport::run_ndjson(&mut service, stdin.lock(), stdout.lock())
    } else {
        match aonsoku_playerd::rodio_backend::RodioPlaybackBackend::new() {
            Ok(backend) => {
                let mut service = aonsoku_playerd::service::PlayerService::new(backend);
                aonsoku_playerd::transport::run_ndjson(&mut service, stdin.lock(), stdout.lock())
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
