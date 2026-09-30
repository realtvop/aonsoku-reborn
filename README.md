# Aonsoku coordination on Cloudflare Workers

A TypeScript implementation of the existing coordination protocol, alongside
`../coordination-server/` (Rust/Axum for self-hosting). The HTTP `/v1/*` routes
and version-1 WebSocket messages use the shared client types from
`../src/coordination/types.ts`. Web, Electron, iOS and Android continue using
their existing transports; configure the deployed URL in coordination settings.

## Runtime and storage

Each account has one SQLite-backed `AccountCoordinator` Durable Object. Its
SQLite records own devices, hashed refresh credentials, one-time challenges and
WebSocket tickets, history operations/tombstones, playback snapshots, command
acknowledgement routes and handoff transactions. There is no D1/KV/R2 dependency.

The Worker derives an opaque deterministic account UUID from HMAC-SHA256 of the
normalized identity URL and canonical username. Signed refresh credentials and
WebSocket tickets include the account route; access tokens keep the Rust format
(`base64url(JSON claims).base64url(HMAC)`, snake-case claims). Routing headers
from clients are replaced, and the object verifies credentials and membership.

Compound state changes use SQLite `transactionSync`. Refresh rotation compares
the current hash again after crypto/network awaits. WebSockets use the
Hibernation API and persist connection identity, negotiated capabilities,
heartbeat timestamp and control relationships in socket attachments. Pending
ack routes and handoffs survive eviction in SQLite. No setInterval keeps an
object resident; Alarms enforce handshake/heartbeat/handoff deadlines and clean
expired records. Heartbeats do not write SQLite records. Snapshots are persisted
on receipt rather than waiting for the Rust server's periodic flush.

Online handoff pauses the source before a generation change grants the target
ownership. Competing transfers are rejected. Offline handoff accepts the last
snapshot within eight hours; superseded source publications are rejected even
after the target has published its own state. Logical playback IDs and history /
now-playing / scrobble flags travel unchanged in the snapshot.

Operational bounds: 512 KiB requests/messages, 2,000 songs per snapshot/queue
command, 100 devices/account, 1,000 history entries/account, 1,000 operations or
legacy items per request. Operation IDs, tombstones and superseded-session guards
are retained for 30 days, 30 days and 7 days respectively. Clients offline beyond
the tombstone retention window should reset their history cursor and resync.

## Identity verification policy

Set `ALLOWED_IDENTITY_ORIGINS` to a comma-separated list of **exact trusted HTTPS
origins**, including non-default ports if needed, e.g.
`https://music.example.com,https://other.example.com:8443`.
Identity URLs may retain an application base path. Userinfo, queries, fragments,
HTTP and origins outside the list are rejected. Verification calls Subsonic
`rest/ping.view` with the supplied token/salt or password proof, rejects every
redirect, and caps responses at 64 KiB with a 15-second timeout. Credentials are
never persisted or logged.

This is intentionally different from the Rust public server's arbitrary-host
DNS/IP-pinning SSRF policy: Workers fetch cannot use that native resolver. The
allowlist must contain origins controlled or trusted by the operator. This
version does not offer open registration against arbitrary server origins or
Rust's private-LAN self-hosted mode. Native clients must use an identity endpoint
reachable from Cloudflare.

## Develop, verify, deploy

Use Node.js 22 or newer and pnpm from the repository root:

```sh
pnpm install --frozen-lockfile
pnpm --filter @aonsoku/coordination-worker check
pnpm --filter @aonsoku/coordination-worker test
pnpm --filter @aonsoku/coordination-worker build
```

Tests run the compiled Worker in Miniflare/workerd with real SQLite Durable
Objects and WebSockets. Only outbound Navidrome verification is mocked; no
Cloudflare account or real server credentials are required. They cover account
isolation, challenge/ticket consumption, refresh rotation/recovery, revocation,
history idempotency/pruning/import, remote command ACKs, online/offline handoff,
concurrent transfer rejection, hibernation and alarm expiry.

For local development, create `coordination-worker/.dev.vars` (gitignored):

```dotenv
STABLE_KEY="replace-with-a-random-secret-of-at-least-32-characters"
ALLOWED_IDENTITY_ORIGINS="https://your-navidrome.example.com"
```

Then run `pnpm --filter @aonsoku/coordination-worker dev`. Wrangler persists local
SQLite state under `.wrangler/`, independently of production.

For deployment:

1. Set the desired Worker `name` and actual allowed origins in `wrangler.jsonc`.
2. Run `pnpm --filter @aonsoku/coordination-worker exec wrangler login`.
3. Run `pnpm --filter @aonsoku/coordination-worker exec wrangler secret put STABLE_KEY`
   and enter a durable random secret of at least 32 characters.
4. Run `pnpm --filter @aonsoku/coordination-worker deploy`.
5. Check `/healthz` and `/readyz`, then configure the HTTPS Worker/custom-domain
   URL in Aonsoku. Readiness checks configuration and a Durable Object SQL query.

Keep the stable key backed up: changing it changes account routing and
invalidates credentials. SQLite DO classes are provisioned by the checked-in
`v1` migration. Do not remove or replay migration tags. Configure normal
Cloudflare usage limits/observability for the intended deployment.

## Existing Rust deployments

The two deployments use separate databases. Existing Rust account/device UUIDs,
refresh tokens and tickets are **not** imported automatically. Switching the
server URL requires re-registering devices; old playback history remains in the
old service unless an explicit migration is performed. The client legacy-import
endpoint is supported, but it is not a Rust-database migration tool.

The existing Rust server and its Docker deployment remain available. The
Workers implementation preserves the client protocol, not binary/storage
interchangeability. Production deployment and real Navidrome/native-device tests
require the operator's Cloudflare account and identity origin; local integration
tests do not prove those external environments.

References: [Durable Object WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/),
[SQLite storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/),
[Alarms](https://developers.cloudflare.com/durable-objects/api/alarms/).
