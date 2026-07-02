fn main() {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut service = aonsoku_playerd::service::PlayerService::new(
        aonsoku_playerd::backend::MockPlaybackBackend::new(),
    );

    if let Err(error) =
        aonsoku_playerd::transport::run_ndjson(&mut service, stdin.lock(), stdout.lock())
    {
        eprintln!("aonsoku-playerd transport error: {error}");
        std::process::exit(1);
    }
}
