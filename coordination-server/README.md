# Aonsoku Cross-Device Coordination Server

A Rust coordination service for synchronizing Aonsoku playback history,
device presence, and playback handoff across devices bound to the same
Navidrome account.

See `docs/spark/2026-06-20-cross-device-coordination-server-design.md` for
the full design document.

## Quick start

```bash
# Build and run locally
cargo run --bin aonsoku-coordination-server

# With a config file
AONSOKU_COORD_CONFIG=./config.toml cargo run --bin aonsoku-coordination-server

# With Docker
docker build -t aonsoku-coordination .
docker run -p 3000:3000 -v $(pwd)/data:/data \
  -v $(pwd)/config.toml:/config.toml:ro \
  -e AONSOKU_COORD_CONFIG=/config.toml \
  -e AONSOKU_COORD_STABLE_KEY="your-stable-secret-key" \
  aonsoku-coordination
```

## Configuration

Runtime settings can be provided in a TOML config file. Start from
`config.example.toml`, then point the server at it with
`AONSOKU_COORD_CONFIG=/path/to/config.toml`.

| Environment variable | Default | Description |
|---|---|---|
| `AONSOKU_COORD_CONFIG` | unset | Optional TOML config file path |
| `AONSOKU_COORD_LISTEN` | `127.0.0.1:3000` | Listen address |
| `AONSOKU_COORD_DATA_DIR` | `./data` | SQLite database directory |
| `AONSOKU_COORD_DATABASE_URL` | derived from data dir | Full SQLite database URL |
| `AONSOKU_COORD_DEPLOYMENT` | `public` | `public` or `self-hosted` |
| `AONSOKU_COORD_STABLE_KEY` | ephemeral | HMAC key for account lookup; **must be persisted** |

Environment variables override values from the config file for deployment
systems that inject secrets or bind addresses at runtime.

The stable key is used for HMAC account lookup key derivation (design §6.1).
Losing it makes existing accounts unmatchable. Include it in backups.

### Config file

```toml
[server]
listen = "127.0.0.1:3000"
data_dir = "./data"
deployment = "public"
stable_key = "replace-with-a-long-random-secret"

[auth]
access_token_ttl_seconds = 900
refresh_token_max_age_seconds = 7776000
ws_ticket_ttl_seconds = 30
challenge_ttl_seconds = 60

[ssrf]
connect_timeout_seconds = 5
first_byte_timeout_seconds = 5
total_timeout_seconds = 15
max_body_bytes = 65536
max_redirects = 2

[realtime]
heartbeat_interval_seconds = 15
heartbeat_grace_seconds = 45
max_message_bytes = 524288
max_snapshot_songs = 2000
snapshot_flush_interval_seconds = 30

[history]
default_history_limit = 100
min_history_limit = 1
max_history_limit = 1000

[retention]
offline_snapshot_ttl_seconds = 28800
tombstone_retention_seconds = 2592000
transferred_retention_seconds = 604800
transferred_gc_interval_seconds = 86400
```

## API

### HTTP
- `POST /v1/auth/challenge` — request one-time registration challenge
- `POST /v1/auth/register` — verify Navidrome credentials, create device
- `POST /v1/auth/token` — refresh access token
- `POST /v1/auth/ws-ticket` — obtain one-time WebSocket ticket
- `GET /v1/devices` — list bound devices
- `PATCH /v1/devices/{id}` — rename device
- `DELETE /v1/devices/{id}` — revoke device
- `GET /v1/history` — incremental history sync
- `POST /v1/history` — upload history operations
- `POST /v1/history/legacy-import` — one-time legacy import
- `DELETE /v1/account` — delete all coordination data

### WebSocket
- `GET /v1/realtime` — realtime protocol (snapshots, commands, handoff)

### Operations
- `GET /healthz` — liveness
- `GET /readyz` — readiness (migrations applied, DB reachable)

## Deployment

TLS is terminated by a reverse proxy (Caddy, Nginx, etc.). The server
listens on plain HTTP. For public deployments, the SSRF policy is strict
(HTTPS-only identity URLs, private/loopback addresses rejected). Self-hosted
deployments may relax this via the deployment mode (design §6.4, §14).

## Testing

```bash
cargo fmt --all
cargo clippy --all-targets -- -D warnings
cargo test
```
