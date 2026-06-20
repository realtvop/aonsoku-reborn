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

# With Docker
docker build -t aonsoku-coordination .
docker run -p 3000:3000 -v $(pwd)/data:/data \
  -e AONSOKU_COORD_STABLE_KEY="your-stable-secret-key" \
  aonsoku-coordination
```

## Configuration

| Environment variable | Default | Description |
|---|---|---|
| `AONSOKU_COORD_LISTEN` | `127.0.0.1:3000` | Listen address |
| `AONSOKU_COORD_DATA_DIR` | `./data` | SQLite database directory |
| `AONSOKU_COORD_STABLE_KEY` | ephemeral | HMAC key for account lookup; **must be persisted** |

The stable key is used for HMAC account lookup key derivation (design §6.1).
Losing it makes existing accounts unmatchable. Include it in backups.

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