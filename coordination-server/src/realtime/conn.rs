//! WebSocket connection handler (design §9, §10).
//!
//! The endpoint authenticates via a one-time WebSocket ticket (design §6.3),
//! performs the Hello/Welcome handshake with capability negotiation, and
//! processes incoming envelopes. Outgoing envelopes are sent through the
//! connection registry's channel.

use std::collections::HashMap;
use std::sync::Arc;

use axum::{
    extract::{
        Query, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::errors::ErrorCode;
use crate::protocol::{
    CapabilitySet, ConnectionId, ConnectionSeq, DeviceId, Envelope, PROTOCOL_VERSION, Payload,
};
use crate::realtime::registry::{ConnectionRegistry, DeviceConnection};
use crate::server::AppState;
use crate::storage::models::{PlaybackSession, SessionStatus};
use crate::storage::repository::{
    DeviceRepository, PresenceRepository, SessionRepository, TicketRepository,
};

/// Query params for the WebSocket handshake.
#[derive(Debug, serde::Deserialize)]
pub struct WsQuery {
    pub ticket: String,
}

/// GET /v1/realtime
pub async fn handle_ws(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    Query(query): Query<WsQuery>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| run_ws(socket, state, query.ticket))
}

async fn run_ws(socket: WebSocket, state: AppState, ticket: String) {
    // 1. Consume the one-time WebSocket ticket.
    let device_id = match state.repos.tickets.consume(&ticket).await {
        Ok(Some(id)) => id,
        _ => {
            tracing::warn!(target: "coordination::ws", "ws ticket invalid or expired");
            return;
        }
    };

    // 2. Load the device to verify it's not revoked.
    let device = match state.repos.devices.find_by_id(device_id).await {
        Ok(Some(d)) if d.revoked_at.is_none() => d,
        _ => {
            tracing::warn!(target: "coordination::ws", "device not found or revoked");
            return;
        }
    };
    let account_id = device.account_id;

    // 3. Split the WebSocket and set up the outbound channel.
    let (mut ws_sender, mut ws_receiver) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Envelope>();
    let connection_id = Uuid::new_v4();

    let registry = state.realtime.clone();
    let conn = DeviceConnection {
        connection_id,
        device_id,
        account_id,
        tx,
        last_seq: 0,
    };
    registry.register(conn);

    // Online status is tracked solely by the in-memory registry; the
    // `device_presence` and `devices.last_online_at` rows are only touched on
    // disconnect to persist the "last seen online" moment. This avoids a
    // SQLite write on every connect and every 15s heartbeat (design §9.2 —
    // presence is authoritative in memory while connected).

    // Prime the session cache for this account so subsequent reads/handoffs
    // are served from memory (design §9.2 — debounced persistence).
    let _ = state.session_cache.prime_account(account_id).await;

    tracing::info!(target: "coordination::ws", device = %device_id, "websocket connected");

    // 4. Outbound pump: forward envelopes from the channel to the WS.
    let send_task = tokio::spawn(async move {
        while let Some(env) = rx.recv().await {
            let json = match serde_json::to_string(&env) {
                Ok(j) => j,
                Err(_) => continue,
            };
            if ws_sender.send(Message::Text(json.into())).await.is_err() {
                break;
            }
        }
    });

    // 5. Inbound loop: read envelopes, handle Hello/Heartbeat/Snapshot/Command.
    let heartbeat_interval = state.config.heartbeat_interval;
    let registry_clone = registry.clone();
    let device_id_clone = device_id;
    let account_id_clone = account_id;
    let state_clone = state.clone();
    let connection_id_clone = connection_id;

    let inbound_task = tokio::spawn(async move {
        let mut last_seq: ConnectionSeq = 0;
        loop {
            // Use a timeout so we can enforce heartbeat grace on read.
            let msg = tokio::time::timeout(
                state_clone.config.heartbeat_grace + heartbeat_interval,
                ws_receiver.next(),
            )
            .await;
            match msg {
                Ok(Some(Ok(Message::Text(text)))) => {
                    let env: Envelope = match serde_json::from_str(&text) {
                        Ok(e) => e,
                        Err(_) => continue,
                    };
                    last_seq = last_seq.wrapping_add(1);
                    registry_clone.update_seq(device_id_clone, last_seq);
                    handle_inbound(
                        &state_clone,
                        &registry_clone,
                        device_id_clone,
                        account_id_clone,
                        connection_id_clone,
                        last_seq,
                        env,
                    )
                    .await;
                }
                Ok(Some(Ok(Message::Close(_)))) | Ok(None) => break,
                Ok(Some(Err(_))) => break,
                Ok(Some(Ok(_))) => continue,
                Err(_) => {
                    // Heartbeat timeout: mark offline.
                    tracing::info!(target: "coordination::ws", device = %device_id_clone, "heartbeat timeout");
                    break;
                }
            }
        }
    });

    // 6. Spawn a heartbeat ticker that sends HeartbeatAck periodically.
    let hb_registry = registry.clone();
    let hb_device = device_id;
    let hb_handle = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(heartbeat_interval);
        loop {
            ticker.tick().await;
            let server_time = chrono::Utc::now().timestamp();
            let env = Envelope {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                connection_id: None,
                source_device_id: None,
                target_device_id: Some(hb_device),
                session_id: None,
                expected_generation: None,
                seq: None,
                server_time: Some(server_time),
                payload: Payload::HeartbeatAck { server_time },
            };
            if hb_registry.send(hb_device, env).is_err() {
                break;
            }
        }
    });

    // Wait for either task to finish, then clean up.
    tokio::select! {
        _ = send_task => {}
        _ = inbound_task => {}
    }
    hb_handle.abort();

    // Mark offline: drop the in-memory connection, persist the last-online
    // moment and a presence row with is_online=false. While connected, online
    // status was served from the registry; this write records the "last seen
    // online" timestamp for the device list API and leaves a tombstone so
    // consumers reading presence after a restart see the device as offline.
    registry.unregister(device_id);
    let now = chrono::Utc::now();
    let _ = state.repos.devices.mark_online(device_id, now).await;
    let _ = state
        .repos
        .presence
        .upsert(&crate::storage::models::DevicePresence {
            device_id,
            account_id,
            is_online: false,
            last_seen_at: Some(now),
            last_seq: 0,
        })
        .await;

    // Freeze A's active playback session: flip status to Offline and record
    // offline_at so the 8-hour offline-handoff window (design §11.3) can be
    // enforced. Without this, the session stays Online in the DB and
    // offline_handoff (handoff.rs:261) rejects with BadMessage.
    let now = chrono::Utc::now();
    if let Ok(Some(session)) = state.session_cache.find_active_for_device(device_id).await {
        if session.status != SessionStatus::Transferred {
            let _ = state
                .session_cache
                .set_status(session.id, SessionStatus::Offline, now)
                .await;
        }
    }

    crate::api::devices::broadcast_device_list(&state, account_id).await;

    // Replay the just-disconnected device's frozen snapshot to every other
    // online device on the same account so their panels can surface A's card
    // and offer the "continue on this device" handoff action (design §11.3).
    let online_targets: Vec<DeviceId> = registry
        .online_devices_for_account(account_id)
        .into_iter()
        .filter(|d| *d != device_id)
        .collect();
    replay_offline_snapshots_to(&state, &registry, account_id, online_targets, device_id).await;

    tracing::info!(target: "coordination::ws", device = %device_id, "websocket disconnected");
}

async fn handle_inbound(
    state: &AppState,
    registry: &Arc<ConnectionRegistry>,
    device_id: DeviceId,
    account_id: Uuid,
    connection_id: ConnectionId,
    seq: ConnectionSeq,
    env: Envelope,
) {
    let server_time = chrono::Utc::now().timestamp();
    match &env.payload {
        Payload::Hello {
            protocol_version,
            capabilities,
            device_id: hello_device_id,
            ticket: _,
            last_seq,
        } => {
            // Negotiate capabilities: server supports all, intersect with client.
            let server_caps = CapabilitySet::HISTORY
                .union(CapabilitySet::OBSERVE)
                .union(CapabilitySet::CONTROL)
                .union(CapabilitySet::HANDOFF);
            let negotiated = server_caps.intersect(*capabilities);

            let confirmed_device = hello_device_id.unwrap_or(device_id);
            let response = Envelope {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                connection_id: Some(connection_id),
                source_device_id: None,
                target_device_id: Some(confirmed_device),
                session_id: None,
                expected_generation: None,
                seq: *last_seq,
                server_time: Some(server_time),
                payload: Payload::Welcome {
                    server_protocol_version: PROTOCOL_VERSION,
                    negotiated,
                    connection_id,
                    device_id: confirmed_device,
                    server_time,
                },
            };
            let _ = registry.send(confirmed_device, response);
            crate::api::devices::broadcast_device_list(state, account_id).await;

            // Replay frozen snapshots of offline devices on the same account
            // to the just-connected device (design §11.3). Without this, B
            // never learns A's last snapshot if A went offline before B
            // connected, and the cross-device panel filters A out.
            replay_offline_snapshots_to(
                state,
                registry,
                account_id,
                vec![confirmed_device],
                confirmed_device,
            )
            .await;

            // If protocol version is incompatible, send an error.
            if *protocol_version != PROTOCOL_VERSION {
                let err_env = Envelope {
                    version: PROTOCOL_VERSION,
                    message_id: Uuid::new_v4(),
                    connection_id: Some(connection_id),
                    source_device_id: None,
                    target_device_id: Some(confirmed_device),
                    session_id: None,
                    expected_generation: None,
                    seq: None,
                    server_time: Some(server_time),
                    payload: Payload::Error {
                        code: ErrorCode::ProtocolIncompatible,
                        reason: format!("server protocol is {PROTOCOL_VERSION}"),
                    },
                };
                let _ = registry.send(confirmed_device, err_env);
            }
        }
        Payload::Heartbeat => {
            // Ack the heartbeat.
            let ack = Envelope {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                connection_id: Some(connection_id),
                source_device_id: None,
                target_device_id: Some(device_id),
                session_id: None,
                expected_generation: None,
                seq: Some(seq),
                server_time: Some(server_time),
                payload: Payload::HeartbeatAck { server_time },
            };
            let _ = registry.send(device_id, ack);
            // Heartbeat does not write to SQLite — online status lives in the
            // in-memory registry. Presence is persisted only on disconnect.
        }
        Payload::Snapshot {
            session_id,
            generation,
            snapshot_revision,
            snapshot,
        } => {
            let actual_session_id = match session_id.or(env.session_id) {
                Some(id) => id,
                None => {
                    let err_env = Envelope {
                        version: PROTOCOL_VERSION,
                        message_id: Uuid::new_v4(),
                        connection_id: Some(connection_id),
                        source_device_id: None,
                        target_device_id: Some(device_id),
                        session_id: None,
                        expected_generation: None,
                        seq: None,
                        server_time: Some(server_time),
                        payload: Payload::Error {
                            code: ErrorCode::BadMessage,
                            reason: "missing session_id".into(),
                        },
                    };
                    let _ = registry.send(device_id, err_env);
                    return;
                }
            };

            // Validate and persist the snapshot (design §9.2).
            if let Err(e) = snapshot.validate(
                state.config.max_snapshot_songs,
                state.config.max_message_bytes,
            ) {
                let err_env = Envelope {
                    version: PROTOCOL_VERSION,
                    message_id: Uuid::new_v4(),
                    connection_id: Some(connection_id),
                    source_device_id: None,
                    target_device_id: Some(device_id),
                    session_id: Some(actual_session_id),
                    expected_generation: None,
                    seq: None,
                    server_time: Some(server_time),
                    payload: Payload::Error {
                        code: e.code,
                        reason: e.reason().to_string(),
                    },
                };
                let _ = registry.send(device_id, err_env);
                return;
            }

            // Session superseded check (design §11.3): if the session id
            // already exists and was transferred to another device, A is
            // trying to publish to a session it no longer owns. Reject the
            // write and instruct A to align its generation and pause.
            if let Ok(Some(existing)) = state.session_cache.find_by_id(actual_session_id).await {
                if existing.status == SessionStatus::Transferred
                    && existing
                        .transferred_to_device
                        .map(|d| d != device_id)
                        .unwrap_or(true)
                {
                    let superseded = Envelope {
                        version: PROTOCOL_VERSION,
                        message_id: Uuid::new_v4(),
                        connection_id: Some(connection_id),
                        source_device_id: None,
                        target_device_id: Some(device_id),
                        session_id: Some(actual_session_id),
                        expected_generation: Some(existing.generation),
                        seq: None,
                        server_time: Some(server_time),
                        payload: Payload::SessionSuperseded {
                            superseded_generation: existing.generation,
                            transferred_to_device: existing.transferred_to_device,
                        },
                    };
                    let _ = registry.send(device_id, superseded);
                    return;
                }
            }

            // Store the snapshot in the session record.
            let snapshot_json = serde_json::to_string(snapshot).unwrap_or_default();
            let session = crate::storage::models::PlaybackSession {
                id: actual_session_id,
                device_id,
                account_id,
                generation: *generation,
                snapshot_revision: *snapshot_revision,
                status: crate::storage::models::SessionStatus::Online,
                last_snapshot: Some(snapshot_json.clone()),
                last_snapshot_at: Some(chrono::Utc::now()),
                offline_at: None,
                transferred_to_device: None,
                transferred_to_session: None,
                created_at: chrono::Utc::now(),
                updated_at: chrono::Utc::now(),
            };
            if let Err(err) = state
                .session_cache
                .upsert_snapshot(&session, &snapshot_json)
                .await
            {
                tracing::error!(target: "coordination::ws", "failed to upsert snapshot: {:?}", err);
            }

            // Invariant (design §9.2 overwrite semantics, §11.3): only this
            // device's most recent activity may remain as an offline-relay
            // candidate. A fresh snapshot supersedes any older frozen offline
            // sessions from the same device, so hard-delete them now — before
            // broadcasting, so peers never see a stale offline card.
            if let Err(err) = state
                .session_cache
                .delete_offline_for_device(device_id, Some(actual_session_id))
                .await
            {
                tracing::warn!(target: "coordination::ws", "delete_offline_for_device failed: {:?}", err);
            }

            // Broadcast to all other online devices on the same account.
            let online = registry.online_devices_for_account(account_id);
            for other in online {
                if other == device_id {
                    continue;
                }
                let projection = Envelope {
                    version: PROTOCOL_VERSION,
                    message_id: Uuid::new_v4(),
                    connection_id: None,
                    source_device_id: Some(device_id),
                    target_device_id: Some(other),
                    session_id: Some(actual_session_id),
                    expected_generation: Some(*generation),
                    seq: None,
                    server_time: Some(server_time),
                    payload: Payload::SnapshotProjection {
                        device_id,
                        session_id: actual_session_id,
                        generation: *generation,
                        snapshot_revision: *snapshot_revision,
                        snapshot: snapshot.clone(),
                        is_online: true,
                        last_confirmed_at: server_time,
                    },
                };
                let _ = registry.send(other, projection);
            }
        }
        Payload::Command {
            target_device_id,
            expected_generation,
            command,
        } => {
            // Enforce cross-account isolation before routing (design §10).
            if let Err(code) = require_same_account(
                state,
                registry,
                account_id,
                *target_device_id,
            )
            .await
            {
                let ack = Envelope {
                    version: PROTOCOL_VERSION,
                    message_id: env.message_id,
                    connection_id: Some(connection_id),
                    source_device_id: Some(device_id),
                    target_device_id: Some(*target_device_id),
                    session_id: None,
                    expected_generation: Some(*expected_generation),
                    seq: None,
                    server_time: Some(server_time),
                    payload: Payload::CommandAck {
                        message_id: env.message_id,
                        result: crate::protocol::CommandResult::Error {
                            code,
                            reason: "target device does not belong to this account".into(),
                        },
                    },
                };
                let _ = registry.send(device_id, ack);
                return;
            }
            // Route command to target device (design §10).
            tracing::info!(
                target: "coordination::ws",
                from = %device_id,
                target = %target_device_id,
                expected_gen = expected_generation,
                command = ?command,
                "command received for routing"
            );
            if let Err(e) = command.validate(state.config.max_snapshot_songs) {
                tracing::warn!(
                    target: "coordination::ws",
                    code = ?e.code,
                    "command validation failed"
                );
                let ack = Envelope {
                    version: PROTOCOL_VERSION,
                    message_id: env.message_id,
                    connection_id: Some(connection_id),
                    source_device_id: Some(device_id),
                    target_device_id: Some(*target_device_id),
                    session_id: None,
                    expected_generation: Some(*expected_generation),
                    seq: None,
                    server_time: Some(server_time),
                    payload: Payload::CommandAck {
                        message_id: env.message_id,
                        result: crate::protocol::CommandResult::Error {
                            code: e.code,
                            reason: e.reason().to_string(),
                        },
                    },
                };
                let _ = registry.send(device_id, ack);
                return;
            }
            if !registry.is_online(*target_device_id) {
                tracing::warn!(
                    target: "coordination::ws",
                    target = %target_device_id,
                    "target device is offline, cannot forward command"
                );
                let ack = Envelope {
                    version: PROTOCOL_VERSION,
                    message_id: env.message_id,
                    connection_id: Some(connection_id),
                    source_device_id: Some(device_id),
                    target_device_id: Some(*target_device_id),
                    session_id: None,
                    expected_generation: Some(*expected_generation),
                    seq: None,
                    server_time: Some(server_time),
                    payload: Payload::CommandAck {
                        message_id: env.message_id,
                        result: crate::protocol::CommandResult::Error {
                            code: ErrorCode::TargetOffline,
                            reason: "target device is offline".into(),
                        },
                    },
                };
                let _ = registry.send(device_id, ack);
                return;
            }
            // §10 exclusivity: a device that is currently acting as a remote
            // controller cannot itself be remote-controlled by another
            // device. Surface as `forbidden` so the caller can react.
            if registry.is_controlling(*target_device_id) {
                tracing::info!(
                    target: "coordination::ws",
                    target = %target_device_id,
                    "target is currently acting as a controller, refusing incoming command"
                );
                let ack = Envelope {
                    version: PROTOCOL_VERSION,
                    message_id: env.message_id,
                    connection_id: Some(connection_id),
                    source_device_id: Some(device_id),
                    target_device_id: Some(*target_device_id),
                    session_id: None,
                    expected_generation: Some(*expected_generation),
                    seq: None,
                    server_time: Some(server_time),
                    payload: Payload::CommandAck {
                        message_id: env.message_id,
                        result: crate::protocol::CommandResult::Error {
                            code: ErrorCode::Forbidden,
                            reason: "target device is currently controlling another device".into(),
                        },
                    },
                };
                let _ = registry.send(device_id, ack);
                return;
            }
            // Forward the command to the target device.
            let forwarded = Envelope {
                version: PROTOCOL_VERSION,
                message_id: env.message_id,
                connection_id: Some(connection_id),
                source_device_id: Some(device_id),
                target_device_id: Some(*target_device_id),
                session_id: None,
                expected_generation: Some(*expected_generation),
                seq: None,
                server_time: Some(server_time),
                payload: Payload::Command {
                    target_device_id: *target_device_id,
                    expected_generation: *expected_generation,
                    command: command.clone(),
                },
            };
            match registry.send(*target_device_id, forwarded) {
                Ok(()) => {
                    registry.remember_command_ack_route(
                        env.message_id,
                        device_id,
                        *target_device_id,
                    );
                    tracing::info!(
                        target: "coordination::ws",
                        target = %target_device_id,
                        "command forwarded successfully"
                    );
                }
                Err(e) => {
                    tracing::error!(
                        target: "coordination::ws",
                        target = %target_device_id,
                        error = ?e,
                        "failed to send forwarded command"
                    );
                }
            }
        }
        Payload::CommandAck { message_id, result } => {
            if let Some(source_device_id) = registry.take_command_ack_route(*message_id) {
                let ack = Envelope {
                    version: PROTOCOL_VERSION,
                    message_id: *message_id,
                    connection_id: Some(connection_id),
                    source_device_id: Some(device_id),
                    target_device_id: Some(source_device_id),
                    session_id: None,
                    expected_generation: None,
                    seq: None,
                    server_time: Some(server_time),
                    payload: Payload::CommandAck {
                        message_id: *message_id,
                        result: result.clone(),
                    },
                };
                if let Err(e) = registry.send(source_device_id, ack) {
                    tracing::warn!(
                        target: "coordination::ws",
                        source = %source_device_id,
                        error = ?e,
                        "failed to forward command ack"
                    );
                }
            } else {
                tracing::debug!(
                    target: "coordination::ws",
                    message_id = %message_id,
                    "dropping command ack with no pending route"
                );
            }
        }
        Payload::HandoffCandidateRequest {
            source_device_id,
            expected_generation,
            expected_snapshot_revision,
        } => {
            // Enforce cross-account isolation before revealing a session
            // snapshot (design §10 — handoff is same-account only).
            if let Err(code) =
                require_same_account(state, registry, account_id, *source_device_id).await
            {
                let _ = registry.send(
                    device_id,
                    error_envelope(
                        env.message_id,
                        code,
                        "source device does not belong to this account",
                        server_time,
                    ),
                );
                return;
            }
            // §10 exclusivity: a device that is currently acting as a remote
            // controller cannot be handoff-taken by another device. Surface
            // as `forbidden` so B's UI can react.
            if registry.is_controlling(*source_device_id) {
                let _ = registry.send(
                    device_id,
                    error_envelope(
                        env.message_id,
                        ErrorCode::Forbidden,
                        "source device is currently controlling another device",
                        server_time,
                    ),
                );
                return;
            }
            // Look up the source device's session and validate (design §11.1 step 1).
            let session = state
                .repos
                .sessions
                .find_active_for_device(*source_device_id)
                .await;
            match session {
                Ok(Some(s)) => {
                    // Check generation match.
                    if s.generation != *expected_generation {
                        let _ = registry.send(
                            device_id,
                            error_envelope(
                                env.message_id,
                                ErrorCode::StaleEpoch,
                                "session generation mismatch",
                                server_time,
                            ),
                        );
                        return;
                    }
                    // Check snapshot revision.
                    if s.snapshot_revision != *expected_snapshot_revision {
                        let _ = registry.send(
                            device_id,
                            error_envelope(
                                env.message_id,
                                ErrorCode::SourceChanged,
                                "source snapshot changed",
                                server_time,
                            ),
                        );
                        return;
                    }
                    // Return the candidate snapshot.
                    if let Some(ref snapshot_json) = &s.last_snapshot {
                        if let Ok(snapshot) =
                            serde_json::from_str::<crate::protocol::PlaybackSnapshot>(snapshot_json)
                        {
                            let candidate = Envelope {
                                version: PROTOCOL_VERSION,
                                message_id: Uuid::new_v4(),
                                connection_id: None,
                                source_device_id: Some(*source_device_id),
                                target_device_id: Some(device_id),
                                session_id: Some(s.id),
                                expected_generation: Some(s.generation),
                                seq: None,
                                server_time: Some(server_time),
                                payload: Payload::HandoffCandidate {
                                    transaction_id: Uuid::new_v4(),
                                    snapshot,
                                    generation: s.generation,
                                    snapshot_revision: s.snapshot_revision,
                                    deadline: server_time + 15,
                                },
                            };
                            let _ = registry.send(device_id, candidate);
                        }
                    }
                }
                _ => {
                    let _ = registry.send(
                        device_id,
                        error_envelope(
                            env.message_id,
                            ErrorCode::TargetOffline,
                            "source device has no active session",
                            server_time,
                        ),
                    );
                }
            }
        }
        Payload::TargetReady {
            transaction_id,
            generation,
            snapshot_revision,
            source_device_id,
            session_id,
        } => {
            // B has preloaded and is ready (design §11.1 step 3).
            // Start the handoff transaction: validate source, send prepare_relinquish to A.
            // The source session id and source device id are carried in the
            // variant because the Envelope routing fields are
            // `#[serde(skip_deserializing)]` and always deserialize to `None`.
            let (source_device, session) = match (source_device_id, session_id) {
                (Some(d), Some(s)) => (*d, *s),
                _ => {
                    let _ = registry.send(
                        device_id,
                        error_envelope(
                            env.message_id,
                            ErrorCode::BadMessage,
                            "target_ready missing source_device_id or session_id",
                            server_time,
                        ),
                    );
                    return;
                }
            };

            // Enforce cross-account isolation before starting a handoff
            // transaction (design §10). Covers both the online and offline
            // handoff branches below.
            if let Err(code) =
                require_same_account(state, registry, account_id, source_device).await
            {
                let _ = registry.send(
                    device_id,
                    error_envelope(
                        env.message_id,
                        code,
                        "source device does not belong to this account",
                        server_time,
                    ),
                );
                return;
            }

            if registry.is_online(source_device) {
                // A is online: run the two-phase online handoff (design §11.1).
                // start_transaction validates A, sends prepare_relinquish, and
                // drives the rest of the flow via RelinquishAck/commit_relinquish.
                if let Err(e) = state
                    .handoff
                    .start_transaction(
                        &*state.session_cache,
                        registry,
                        *transaction_id,
                        source_device,
                        session,
                        *generation,
                        *snapshot_revision,
                        device_id, // B is the target
                        15,
                        account_id,
                    )
                    .await
                {
                    crate::handoff::HandoffCoordinator::send_failure_to_target(
                        registry,
                        device_id,
                        *transaction_id,
                        e.code,
                        Some(source_device),
                        Some(session),
                    );
                }
            } else {
                // A is offline: take over A's frozen snapshot directly (design §11.3).
                match state
                    .handoff
                    .offline_handoff(
                        &*state.session_cache,
                        registry,
                        source_device,
                        session,
                        device_id,
                        state.config.offline_snapshot_ttl,
                        account_id,
                    )
                    .await
                {
                    Ok(new_generation) => {
                        // Reload the session and replay A's latest snapshot to B.
                        let snapshot = state
                            .session_cache
                            .find_by_id(session)
                            .await
                            .ok()
                            .flatten()
                            .and_then(|s| s.last_snapshot)
                            .and_then(|json| {
                                serde_json::from_str::<crate::protocol::PlaybackSnapshot>(&json)
                                    .ok()
                            });

                        match snapshot {
                            Some(snapshot) => {
                                let committed = Envelope {
                                    version: PROTOCOL_VERSION,
                                    message_id: Uuid::new_v4(),
                                    connection_id: None,
                                    source_device_id: Some(source_device),
                                    target_device_id: Some(device_id),
                                    session_id: Some(session),
                                    expected_generation: Some(new_generation),
                                    seq: None,
                                    server_time: Some(server_time),
                                    payload: Payload::HandoffCommitted {
                                        transaction_id: *transaction_id,
                                        new_generation,
                                        snapshot,
                                    },
                                };
                                let _ = registry.send(device_id, committed);
                            }
                            None => {
                                // Generation was promoted but no snapshot could
                                // be materialized; surface the failure to B.
                                let _ = registry.send(
                                    device_id,
                                    Envelope {
                                        version: PROTOCOL_VERSION,
                                        message_id: Uuid::new_v4(),
                                        connection_id: None,
                                        source_device_id: Some(source_device),
                                        target_device_id: Some(device_id),
                                        session_id: Some(session),
                                        expected_generation: Some(new_generation),
                                        seq: None,
                                        server_time: Some(server_time),
                                        payload: Payload::HandoffFailed {
                                            transaction_id: *transaction_id,
                                            code: ErrorCode::NotFound,
                                        },
                                    },
                                );
                            }
                        }
                    }
                    Err(e) => {
                        let _ = registry.send(
                            device_id,
                            Envelope {
                                version: PROTOCOL_VERSION,
                                message_id: Uuid::new_v4(),
                                connection_id: None,
                                source_device_id: Some(source_device),
                                target_device_id: Some(device_id),
                                session_id: Some(session),
                                expected_generation: None,
                                seq: None,
                                server_time: Some(server_time),
                                payload: Payload::HandoffFailed {
                                    transaction_id: *transaction_id,
                                    code: e.code,
                                },
                            },
                        );
                    }
                }
            }
        }
        Payload::RelinquishAck {
            transaction_id,
            snapshot,
        } => {
            // A confirmed relinquish with final snapshot (design §11.1 step 5-6).
            match state
                .handoff
                .commit_relinquish(
                    &*state.session_cache,
                    registry,
                    *transaction_id,
                    snapshot.clone(),
                )
                .await
            {
                Ok(_new_gen) => {
                    // Success: B has been notified by commit_relinquish.
                }
                Err(e) => {
                    state
                        .handoff
                        .fail_transaction(registry, *transaction_id, e.code);
                }
            }
        }
        Payload::ControlSessionBegin { target_device_id } => {
            // Enforce cross-account isolation: B may only control a device on
            // the same account (design §10).
            if let Err(code) =
                require_same_account(state, registry, account_id, *target_device_id).await
            {
                let _ = registry.send(
                    device_id,
                    error_envelope(
                        env.message_id,
                        code,
                        "target device does not belong to this account",
                        server_time,
                    ),
                );
                return;
            }
            // §10 exclusivity: record B as an active controller. While set,
            // other devices cannot remote control or handoff-take B.
            registry.begin_control(device_id, *target_device_id);
            tracing::info!(
                target: "coordination::ws",
                controller = %device_id,
                target = %target_device_id,
                "control session begun"
            );
            // Re-broadcast the device list so observers see B's new
            // controlling state and hide it from their control/handoff lists.
            crate::api::devices::broadcast_device_list(state, account_id).await;
        }
        Payload::ControlSessionEnd => {
            // §10 exclusivity: clear B's active-controller marker.
            registry.end_control(device_id);
            tracing::info!(
                target: "coordination::ws",
                controller = %device_id,
                "control session ended"
            );
            crate::api::devices::broadcast_device_list(state, account_id).await;
        }
        Payload::RequestSnapshots => {
            // Replay in-window Online peer snapshots to the requester (design
            // §9.2 bootstrap). Offline peers are already replayed on Hello;
            // this covers the gap where B connects while A is already playing.
            replay_online_snapshots_to(state, registry, account_id, vec![device_id], device_id)
                .await;
        }
        _ => {
            // Other payloads are not handled in this version.
        }
    }
}

fn error_envelope(
    message_id: uuid::Uuid,
    code: ErrorCode,
    reason: &str,
    server_time: i64,
) -> Envelope {
    Envelope {
        version: PROTOCOL_VERSION,
        message_id: Uuid::new_v4(),
        connection_id: None,
        source_device_id: None,
        target_device_id: None,
        session_id: None,
        expected_generation: None,
        seq: None,
        server_time: Some(server_time),
        payload: Payload::Error {
            code,
            reason: reason.to_string(),
        },
    }
    .with_message_id(message_id)
}

/// Enforce cross-account isolation (design §10): a device may only send
/// commands, request handoff candidates, or target handoffs toward devices
/// on the same account. Online peers are checked via the in-memory registry;
/// offline peers fall back to the device repository. Returns `Ok(())` when
/// the peer belongs to the sender's account, or an `ErrorCode` describing
/// the rejection.
async fn require_same_account(
    state: &AppState,
    registry: &Arc<ConnectionRegistry>,
    sender_account_id: Uuid,
    peer_device_id: DeviceId,
) -> Result<(), ErrorCode> {
    if let Some(peer_acc) = registry.account_of(peer_device_id) {
        return if peer_acc == sender_account_id {
            Ok(())
        } else {
            Err(ErrorCode::Forbidden)
        };
    }
    match state.repos.devices.find_by_id(peer_device_id).await {
        Ok(Some(d)) if d.account_id == sender_account_id => Ok(()),
        Ok(Some(_)) => Err(ErrorCode::Forbidden),
        Ok(None) => Err(ErrorCode::NotFound),
        Err(_) => Err(ErrorCode::Internal),
    }
}

trait WithMessageId {
    fn with_message_id(self, id: uuid::Uuid) -> Self;
}

impl WithMessageId for Envelope {
    fn with_message_id(mut self, id: uuid::Uuid) -> Self {
        self.message_id = id;
        self
    }
}

/// Replay the frozen snapshots of offline devices on the same account to the
/// given target devices (design §11.3).
///
/// Only sessions whose status is `Offline`, that have not been transferred, and
/// whose `offline_at` is within `offline_snapshot_ttl` (8h) are replayed. This
/// lets a client that connected *after* a peer went offline — or that is
/// already online when a peer disconnects — surface the peer's last playback
/// state in the cross-device panel and offer the offline handoff action.
///
/// `exclude_device_id` skips the disconnected/connecting device itself.
///
/// Defensively caps at one offline card per source device: when a device has
/// more than one in-window `Offline` row (e.g. a stale row that survived
/// `delete_offline_for_device` due to a race, or a server restart), only the
/// row with the most recent `last_snapshot_at` (tie-broken by `updated_at`) is
/// emitted. This keeps the cross-device panel to one "continue on this
/// device" affordance per peer (design §11.3, §9.2 overwrite semantics).
async fn replay_offline_snapshots_to(
    state: &AppState,
    registry: &Arc<ConnectionRegistry>,
    account_id: Uuid,
    targets: Vec<DeviceId>,
    exclude_device_id: DeviceId,
) {
    if targets.is_empty() {
        return;
    }
    let ttl = state.config.offline_snapshot_ttl;
    let sessions = match state.session_cache.list_for_account(account_id).await {
        Ok(s) => s,
        Err(err) => {
            tracing::warn!(target: "coordination::ws", "replay: list sessions failed: {:?}", err);
            return;
        }
    };
    let now = chrono::Utc::now();
    let server_time = now.timestamp();

    // Select, per source device, the in-window Offline session with the
    // most recent confirmed snapshot. This is a defensive dedup: the
    // snapshot-publish path (`handle_inbound(Payload::Snapshot)`) already
    // hard-deletes older Offline rows for the same device, but races and
    // server restarts can briefly leave more than one, and replay must
    // never surface a stale candidate.
    let mut winners: HashMap<DeviceId, &PlaybackSession> = HashMap::new();
    for session in &sessions {
        if session.device_id == exclude_device_id {
            continue;
        }
        if session.status != SessionStatus::Offline {
            continue;
        }
        if session.transferred_to_device.is_some() {
            continue;
        }
        if !session.offline_at.map(|t| now - t <= ttl).unwrap_or(false) {
            continue;
        }
        if session.last_snapshot.is_none() {
            continue;
        }
        let take = match winners.get(&session.device_id) {
            None => true,
            Some(cur) => {
                let cand = session.last_snapshot_at.unwrap_or(session.updated_at);
                let existing = cur.last_snapshot_at.unwrap_or(cur.updated_at);
                cand > existing
            }
        };
        if take {
            winners.insert(session.device_id, session);
        }
    }

    for (_dev, session) in winners {
        let Some(snapshot_json) = session.last_snapshot.as_ref() else {
            continue;
        };
        let Ok(snapshot) = serde_json::from_str::<crate::protocol::PlaybackSnapshot>(snapshot_json)
        else {
            continue;
        };
        let last_confirmed_at = session
            .last_snapshot_at
            .map(|t| t.timestamp())
            .unwrap_or(server_time);
        for target in &targets {
            if *target == session.device_id {
                continue;
            }
            let env = Envelope {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                connection_id: None,
                source_device_id: Some(session.device_id),
                target_device_id: Some(*target),
                session_id: Some(session.id),
                expected_generation: Some(session.generation),
                seq: None,
                server_time: Some(server_time),
                payload: Payload::SnapshotProjection {
                    device_id: session.device_id,
                    session_id: session.id,
                    generation: session.generation,
                    snapshot_revision: session.snapshot_revision,
                    snapshot: snapshot.clone(),
                    is_online: false,
                    last_confirmed_at,
                },
            };
            let _ = registry.send(*target, env);
        }
    }
}

/// Replay online peers' current snapshots to the target device (design §9.2
/// bootstrap). Mirrors [`replay_offline_snapshots_to`] but selects sessions
/// with `status == Online` (and confirms the device is still connected via
/// the registry) and emits `is_online: true` projections.
///
/// Invoked on `Payload::RequestSnapshots`, typically sent by a client right
/// after the `Welcome` handshake, so the cross-device panel shows the live
/// playback states of already-connected peers without waiting for their
/// next periodic publish.
///
/// `exclude_device_id` skips the requester itself. Defensively caps at one
/// online card per source device (the row with the most recent
/// `last_snapshot_at`, tie-broken by `updated_at`).
async fn replay_online_snapshots_to(
    state: &AppState,
    registry: &Arc<ConnectionRegistry>,
    account_id: Uuid,
    targets: Vec<DeviceId>,
    exclude_device_id: DeviceId,
) {
    if targets.is_empty() {
        return;
    }
    let sessions = match state.session_cache.list_for_account(account_id).await {
        Ok(s) => s,
        Err(err) => {
            tracing::warn!(target: "coordination::ws", "replay_online: list sessions failed: {:?}", err);
            return;
        }
    };
    let now = chrono::Utc::now();
    let server_time = now.timestamp();

    // Select, per source device, the Online session with the most recent
    // confirmed snapshot. Only include peers that are actually connected
    // right now (the registry is authoritative for online status while a
    // device is connected; the session row may briefly lag on disconnect).
    let mut winners: HashMap<DeviceId, &PlaybackSession> = HashMap::new();
    for session in &sessions {
        if session.device_id == exclude_device_id {
            continue;
        }
        if session.status != SessionStatus::Online {
            continue;
        }
        if session.transferred_to_device.is_some() {
            continue;
        }
        if session.last_snapshot.is_none() {
            continue;
        }
        if !registry.is_online(session.device_id) {
            continue;
        }
        let take = match winners.get(&session.device_id) {
            None => true,
            Some(cur) => {
                let cand = session.last_snapshot_at.unwrap_or(session.updated_at);
                let existing = cur.last_snapshot_at.unwrap_or(cur.updated_at);
                cand > existing
            }
        };
        if take {
            winners.insert(session.device_id, session);
        }
    }

    for (_dev, session) in winners {
        let Some(snapshot_json) = session.last_snapshot.as_ref() else {
            continue;
        };
        let Ok(snapshot) = serde_json::from_str::<crate::protocol::PlaybackSnapshot>(snapshot_json)
        else {
            continue;
        };
        let last_confirmed_at = session
            .last_snapshot_at
            .map(|t| t.timestamp())
            .unwrap_or(server_time);
        for target in &targets {
            if *target == session.device_id {
                continue;
            }
            let env = Envelope {
                version: PROTOCOL_VERSION,
                message_id: Uuid::new_v4(),
                connection_id: None,
                source_device_id: Some(session.device_id),
                target_device_id: Some(*target),
                session_id: Some(session.id),
                expected_generation: Some(session.generation),
                seq: None,
                server_time: Some(server_time),
                payload: Payload::SnapshotProjection {
                    device_id: session.device_id,
                    session_id: session.id,
                    generation: session.generation,
                    snapshot_revision: session.snapshot_revision,
                    snapshot: snapshot.clone(),
                    is_online: true,
                    last_confirmed_at,
                },
            };
            let _ = registry.send(*target, env);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::protocol::{MediaKind, PlaybackSnapshot};
    use crate::storage::models::{PlaybackSession, SessionStatus};
    use crate::storage::repository::AccountRepository;
    use crate::storage::sqlite::SqliteRepositories;
    use chrono::Utc;
    use tokio::sync::mpsc;

    async fn setup_state() -> (tempfile::TempDir, AppState) {
        let dir = tempfile::tempdir().unwrap();
        let url = format!("sqlite://{}/test.db", dir.path().display());
        let pool = crate::storage::open_pool(&url).await.unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let repos = SqliteRepositories::new(pool.clone());
        let config = Arc::new(Config::new(
            "127.0.0.1:0".parse().unwrap(),
            dir.path().to_path_buf(),
            "stable-key-test".into(),
        ));
        let state = AppState::new(config, pool, repos);
        (dir, state)
    }

    fn sample_snapshot() -> PlaybackSnapshot {
        PlaybackSnapshot {
            session_id: Uuid::new_v4(),
            logical_playback_session_id: Uuid::new_v4(),
            media_kind: MediaKind::Song,
            song_id: "song-1".into(),
            progress_seconds: 10.0,
            duration_seconds: 180.0,
            is_playing: true,
            sampled_at: 1_700_000_000.0,
            context_queue: vec!["song-1".into()],
            context_index: Some(0),
            source_id: Some("album-1".into()),
            source_name: Some("album".into()),
            user_queue: vec![],
            in_user_queue: false,
            restore_previous: vec![],
            shuffle: false,
            repeat: "off".into(),
            volume: Some(0.5),
            accumulated_play_seconds: 12.0,
            history_written: false,
            now_playing_sent: true,
            scrobble_sent: false,
        }
    }

    /// Register a fake online device so `registry.send` has somewhere to
    /// deliver. Returns the receiving end of the outbound channel.
    fn register_fake_device(
        registry: &Arc<ConnectionRegistry>,
        device_id: DeviceId,
        account_id: Uuid,
    ) -> mpsc::UnboundedReceiver<Envelope> {
        let (tx, rx) = mpsc::unbounded_channel();
        registry.register(DeviceConnection {
            connection_id: Uuid::new_v4(),
            device_id,
            account_id,
            tx,
            last_seq: 0,
        });
        rx
    }

    #[tokio::test]
    async fn replay_delivers_offline_snapshot_to_target() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        // Account + two devices.
        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-k", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        // A's session: Online with a snapshot, then flipped to Offline.
        let snapshot = sample_snapshot();
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Online,
            last_snapshot: Some(serde_json::to_string(&snapshot).unwrap()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&session, &serde_json::to_string(&snapshot).unwrap())
            .await
            .unwrap();
        state
            .repos
            .sessions
            .set_status(session.id, SessionStatus::Offline, Utc::now())
            .await
            .unwrap();

        // B is online; A is offline (not registered).
        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);

        replay_offline_snapshots_to(&state, &registry, acc.id, vec![dev_b.id], dev_b.id).await;

        // B should receive one SnapshotProjection marked offline.
        let env = rx_b.recv().await.expect("B received a projection");
        match env.payload {
            Payload::SnapshotProjection {
                device_id,
                is_online,
                snapshot: proj_snapshot,
                generation,
                ..
            } => {
                assert_eq!(device_id, dev_a.id);
                assert!(!is_online, "offline snapshot must set is_online=false");
                assert_eq!(proj_snapshot.song_id, "song-1");
                assert_eq!(generation, 1);
            }
            other => panic!("expected SnapshotProjection, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn replay_skips_expired_offline_session() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-k2", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        let snapshot = sample_snapshot();
        // offline_at is 10 hours ago — beyond the 8h TTL.
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Offline,
            last_snapshot: Some(serde_json::to_string(&snapshot).unwrap()),
            last_snapshot_at: Some(Utc::now() - chrono::Duration::hours(10)),
            offline_at: Some(Utc::now() - chrono::Duration::hours(10)),
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now() - chrono::Duration::hours(10),
            updated_at: Utc::now() - chrono::Duration::hours(10),
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&session, &serde_json::to_string(&snapshot).unwrap())
            .await
            .unwrap();

        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);

        replay_offline_snapshots_to(&state, &registry, acc.id, vec![dev_b.id], dev_b.id).await;

        // B should receive nothing — the session is expired.
        assert!(
            rx_b.try_recv().is_err(),
            "expired offline session must not be replayed"
        );
    }

    #[tokio::test]
    async fn replay_skips_transferred_session() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-k3", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        let snapshot = sample_snapshot();
        let session_id = Uuid::new_v4();
        let session = PlaybackSession {
            id: session_id,
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Online,
            last_snapshot: Some(serde_json::to_string(&snapshot).unwrap()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&session, &serde_json::to_string(&snapshot).unwrap())
            .await
            .unwrap();
        state
            .repos
            .sessions
            .set_status(session_id, SessionStatus::Offline, Utc::now())
            .await
            .unwrap();
        // Mark as transferred to B.
        state
            .repos
            .sessions
            .transfer(session_id, 2, dev_b.id, session_id)
            .await
            .unwrap();

        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);

        replay_offline_snapshots_to(&state, &registry, acc.id, vec![dev_b.id], dev_b.id).await;

        assert!(
            rx_b.try_recv().is_err(),
            "transferred session must not be replayed"
        );
    }

    #[tokio::test]
    async fn snapshot_clears_stale_offline_sessions_for_same_device() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-clear", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        // Stale Offline session left by a prior disconnect of A (within TTL).
        let stale_snapshot = sample_snapshot();
        let stale_session_id = Uuid::new_v4();
        let stale = PlaybackSession {
            id: stale_session_id,
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Online,
            last_snapshot: Some(serde_json::to_string(&stale_snapshot).unwrap()),
            last_snapshot_at: Some(Utc::now() - chrono::Duration::hours(1)),
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now() - chrono::Duration::hours(2),
            updated_at: Utc::now() - chrono::Duration::hours(1),
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&stale, &serde_json::to_string(&stale_snapshot).unwrap())
            .await
            .unwrap();
        state
            .repos
            .sessions
            .set_status(stale_session_id, SessionStatus::Offline, Utc::now())
            .await
            .unwrap();
        assert!(
            state
                .repos
                .sessions
                .find_by_id(stale_session_id)
                .await
                .unwrap()
                .is_some()
        );

        // Register A and B so handle_inbound has a recipient for the fan-out
        // (the projection goes to B; A is the source).
        let _rx_a = register_fake_device(&registry, dev_a.id, acc.id);
        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);

        // A publishes a fresh snapshot — a brand-new logical session id.
        let fresh_session_id = Uuid::new_v4();
        let fresh_snapshot = sample_snapshot();
        let env = Envelope {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            connection_id: Some(Uuid::new_v4()),
            source_device_id: Some(dev_a.id),
            target_device_id: None,
            session_id: Some(fresh_session_id),
            expected_generation: None,
            seq: None,
            server_time: None,
            payload: Payload::Snapshot {
                session_id: Some(fresh_session_id),
                generation: 2,
                snapshot_revision: 1,
                snapshot: fresh_snapshot.clone(),
            },
        };
        handle_inbound(&state, &registry, dev_a.id, acc.id, Uuid::new_v4(), 0, env).await;

        // The stale Offline session must be hard-deleted (the cache forwards
        // delete_offline_for_device to the backing store, so this is visible
        // immediately).
        assert!(
            state
                .session_cache
                .find_by_id(stale_session_id)
                .await
                .unwrap()
                .is_none(),
            "stale offline session must be cleared when A publishes a fresh snapshot"
        );
        // The fresh session exists in the cache as Online. The debounced
        // upsert has not yet hit SQLite, so flush to materialise the row before
        // asserting persistence.
        state.session_cache.flush_dirty().await.unwrap();
        let fresh = state
            .session_cache
            .find_by_id(fresh_session_id)
            .await
            .unwrap()
            .expect("fresh session persisted");
        assert_eq!(fresh.status, SessionStatus::Online);
        assert_eq!(fresh.generation, 2);

        // B receives the live projection for the fresh session only.
        let mut saw_fresh = false;
        while let Ok(env) = rx_b.try_recv() {
            if let Payload::SnapshotProjection { session_id, .. } = env.payload {
                assert_ne!(
                    session_id, stale_session_id,
                    "stale offline session must not be projected"
                );
                if session_id == fresh_session_id {
                    saw_fresh = true;
                }
            }
        }
        assert!(saw_fresh, "B must receive the fresh online projection");
    }

    #[tokio::test]
    async fn replay_dedups_multiple_offline_sessions_per_device() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-dedup", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        // Two in-window Offline sessions from A: an older one and a newer one.
        let old_snapshot = sample_snapshot();
        let old_session_id = Uuid::new_v4();
        let older_at = Utc::now() - chrono::Duration::hours(3);
        let old = PlaybackSession {
            id: old_session_id,
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Offline,
            last_snapshot: Some(serde_json::to_string(&old_snapshot).unwrap()),
            last_snapshot_at: Some(older_at),
            offline_at: Some(older_at),
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: older_at,
            updated_at: older_at,
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&old, &serde_json::to_string(&old_snapshot).unwrap())
            .await
            .unwrap();

        let new_snapshot = sample_snapshot();
        let new_session_id = Uuid::new_v4();
        let newer_at = Utc::now() - chrono::Duration::minutes(10);
        let new = PlaybackSession {
            id: new_session_id,
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 2,
            status: SessionStatus::Offline,
            last_snapshot: Some(serde_json::to_string(&new_snapshot).unwrap()),
            last_snapshot_at: Some(newer_at),
            offline_at: Some(newer_at),
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: newer_at,
            updated_at: newer_at,
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&new, &serde_json::to_string(&new_snapshot).unwrap())
            .await
            .unwrap();

        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);

        replay_offline_snapshots_to(&state, &registry, acc.id, vec![dev_b.id], dev_b.id).await;

        // B must receive exactly one projection, and it must be the newer one.
        let mut count = 0;
        while let Ok(env) = rx_b.try_recv() {
            if let Payload::SnapshotProjection { session_id, .. } = env.payload {
                count += 1;
                assert_eq!(
                    session_id, new_session_id,
                    "dedup must keep only the most recent offline session per device"
                );
            }
        }
        assert_eq!(count, 1, "replay must emit one card per source device");
    }

    #[tokio::test]
    async fn replay_online_delivers_snapshot_to_target() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-online-1", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        // A's session: Online with a snapshot.
        let snapshot = sample_snapshot();
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 2,
            snapshot_revision: 3,
            status: SessionStatus::Online,
            last_snapshot: Some(serde_json::to_string(&snapshot).unwrap()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&session, &serde_json::to_string(&snapshot).unwrap())
            .await
            .unwrap();

        // Both A and B are online (registered).
        let _rx_a = register_fake_device(&registry, dev_a.id, acc.id);
        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);

        replay_online_snapshots_to(&state, &registry, acc.id, vec![dev_b.id], dev_b.id).await;

        // B should receive one SnapshotProjection marked online.
        let env = rx_b.recv().await.expect("B received a projection");
        match env.payload {
            Payload::SnapshotProjection {
                device_id,
                is_online,
                snapshot: proj_snapshot,
                generation,
                ..
            } => {
                assert_eq!(device_id, dev_a.id);
                assert!(is_online, "online snapshot must set is_online=true");
                assert_eq!(proj_snapshot.song_id, "song-1");
                assert_eq!(generation, 2);
            }
            other => panic!("expected SnapshotProjection, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn replay_online_skips_offline_peer() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-online-2", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        // A's session is Offline — online replay must not emit it.
        let snapshot = sample_snapshot();
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Offline,
            last_snapshot: Some(serde_json::to_string(&snapshot).unwrap()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: Some(Utc::now()),
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&session, &serde_json::to_string(&snapshot).unwrap())
            .await
            .unwrap();

        // A is registered (online in registry) but its session is Offline.
        let _rx_a = register_fake_device(&registry, dev_a.id, acc.id);
        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);

        replay_online_snapshots_to(&state, &registry, acc.id, vec![dev_b.id], dev_b.id).await;

        // B should not receive any projection.
        assert!(
            rx_b.try_recv().is_err(),
            "online replay must skip offline sessions"
        );
    }

    #[tokio::test]
    async fn replay_online_skips_peer_without_snapshot() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-online-3", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        // A is online but has no snapshot.
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Online,
            last_snapshot: None,
            last_snapshot_at: None,
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&session, "")
            .await
            .unwrap();

        let _rx_a = register_fake_device(&registry, dev_a.id, acc.id);
        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);

        replay_online_snapshots_to(&state, &registry, acc.id, vec![dev_b.id], dev_b.id).await;

        assert!(
            rx_b.try_recv().is_err(),
            "online replay must skip peers without a snapshot"
        );
    }

    #[tokio::test]
    async fn replay_online_excludes_self() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-online-4", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();

        let snapshot = sample_snapshot();
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Online,
            last_snapshot: Some(serde_json::to_string(&snapshot).unwrap()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        state
            .repos
            .sessions
            .upsert_snapshot(&session, &serde_json::to_string(&snapshot).unwrap())
            .await
            .unwrap();

        // A is the requester and the only device — replay must not echo back.
        let mut rx_a = register_fake_device(&registry, dev_a.id, acc.id);

        replay_online_snapshots_to(&state, &registry, acc.id, vec![dev_a.id], dev_a.id).await;

        assert!(
            rx_a.try_recv().is_err(),
            "online replay must exclude the requester itself"
        );
    }

    #[tokio::test]
    async fn target_ready_tolerates_snapshot_revision_update() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-handoff-source-changed", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        let snapshot = sample_snapshot();
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 2,
            status: SessionStatus::Online,
            last_snapshot: Some(serde_json::to_string(&snapshot).unwrap()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        state
            .session_cache
            .upsert_snapshot(&session, &serde_json::to_string(&snapshot).unwrap())
            .await
            .unwrap();

        let mut rx_a = register_fake_device(&registry, dev_a.id, acc.id);
        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);
        let transaction_id = Uuid::new_v4();
        let env = Envelope {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            connection_id: Some(Uuid::new_v4()),
            source_device_id: Some(dev_b.id),
            target_device_id: None,
            session_id: None,
            expected_generation: None,
            seq: None,
            server_time: None,
            payload: Payload::TargetReady {
                transaction_id,
                generation: 1,
                snapshot_revision: 1,
                source_device_id: Some(dev_a.id),
                session_id: Some(session.id),
            },
        };

        handle_inbound(&state, &registry, dev_b.id, acc.id, Uuid::new_v4(), 0, env).await;

        assert!(
            rx_b.try_recv().is_err(),
            "target_ready should not fail only because snapshot_revision changed"
        );
        let env = rx_a.recv().await.expect("A received prepare_relinquish");
        match env.payload {
            Payload::PrepareRelinquish {
                transaction_id: got_transaction_id,
                expected_snapshot_revision,
                ..
            } => {
                assert_eq!(got_transaction_id, transaction_id);
                assert_eq!(expected_snapshot_revision, 1);
            }
            other => panic!("expected PrepareRelinquish, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn target_ready_handoff_conflict_notifies_target() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc = state
            .repos
            .accounts
            .upsert_by_lookup_key("lookup-handoff-conflict", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc.id, "B", "web", None, 0, "h2", Uuid::new_v4())
            .await
            .unwrap();

        let snapshot = sample_snapshot();
        let session = PlaybackSession {
            id: Uuid::new_v4(),
            device_id: dev_a.id,
            account_id: acc.id,
            generation: 1,
            snapshot_revision: 1,
            status: SessionStatus::Online,
            last_snapshot: Some(serde_json::to_string(&snapshot).unwrap()),
            last_snapshot_at: Some(Utc::now()),
            offline_at: None,
            transferred_to_device: None,
            transferred_to_session: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        state
            .session_cache
            .upsert_snapshot(&session, &serde_json::to_string(&snapshot).unwrap())
            .await
            .unwrap();

        let _rx_a = register_fake_device(&registry, dev_a.id, acc.id);
        let mut rx_b = register_fake_device(&registry, dev_b.id, acc.id);
        state
            .handoff
            .start_transaction(
                &*state.session_cache,
                &registry,
                Uuid::new_v4(),
                dev_a.id,
                session.id,
                1,
                1,
                dev_b.id,
                15,
                acc.id,
            )
            .await
            .unwrap();

        let transaction_id = Uuid::new_v4();
        let env = Envelope {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            connection_id: Some(Uuid::new_v4()),
            source_device_id: Some(dev_b.id),
            target_device_id: None,
            session_id: None,
            expected_generation: None,
            seq: None,
            server_time: None,
            payload: Payload::TargetReady {
                transaction_id,
                generation: 1,
                snapshot_revision: 1,
                source_device_id: Some(dev_a.id),
                session_id: Some(session.id),
            },
        };

        handle_inbound(&state, &registry, dev_b.id, acc.id, Uuid::new_v4(), 0, env).await;

        let mut saw_failure = false;
        while let Ok(env) = rx_b.try_recv() {
            if let Payload::HandoffFailed {
                transaction_id: got_transaction_id,
                code,
            } = env.payload
            {
                assert_eq!(got_transaction_id, transaction_id);
                assert_eq!(code, ErrorCode::HandoffConflict);
                saw_failure = true;
            }
        }
        assert!(saw_failure, "B must receive handoff_conflict failure");
    }

    #[tokio::test]
    async fn command_to_cross_account_device_is_forbidden() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        // Account 1 with device A.
        let acc1 = state
            .repos
            .accounts
            .upsert_by_lookup_key("acc1", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc1.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        // Account 2 with device B.
        let acc2 = state
            .repos
            .accounts
            .upsert_by_lookup_key("acc2", 100)
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc2.id, "B", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();

        let _rx_a = register_fake_device(&registry, dev_a.id, acc1.id);
        let mut rx_b = register_fake_device(&registry, dev_b.id, acc2.id);

        // B (account 2) sends a command to A (account 1). Must be rejected.
        let env = Envelope {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            connection_id: Some(Uuid::new_v4()),
            source_device_id: Some(dev_b.id),
            target_device_id: None,
            session_id: None,
            expected_generation: None,
            seq: None,
            server_time: None,
            payload: Payload::Command {
                target_device_id: dev_a.id,
                expected_generation: 1,
                command: crate::protocol::RemoteCommand::Pause,
            },
        };
        handle_inbound(&state, &registry, dev_b.id, acc2.id, Uuid::new_v4(), 0, env).await;

        // B must receive a CommandAck with Forbidden, and A must receive nothing.
        let mut saw_forbidden = false;
        while let Ok(env) = rx_b.try_recv() {
            if let Payload::CommandAck { result, .. } = env.payload {
                match result {
                    crate::protocol::CommandResult::Error { code, .. } => {
                        assert_eq!(code, ErrorCode::Forbidden);
                        saw_forbidden = true;
                    }
                    _ => panic!("expected error ack for cross-account command"),
                }
            }
        }
        assert!(saw_forbidden, "B must receive forbidden ack");
    }

    #[tokio::test]
    async fn handoff_candidate_request_cross_account_is_forbidden() {
        let (_dir, state) = setup_state().await;
        let registry = state.realtime.clone();

        let acc1 = state
            .repos
            .accounts
            .upsert_by_lookup_key("acc1", 100)
            .await
            .unwrap();
        let dev_a = state
            .repos
            .devices
            .create(acc1.id, "A", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();
        let acc2 = state
            .repos
            .accounts
            .upsert_by_lookup_key("acc2", 100)
            .await
            .unwrap();
        let dev_b = state
            .repos
            .devices
            .create(acc2.id, "B", "web", None, 0, "h", Uuid::new_v4())
            .await
            .unwrap();

        let _rx_a = register_fake_device(&registry, dev_a.id, acc1.id);
        let mut rx_b = register_fake_device(&registry, dev_b.id, acc2.id);

        let env = Envelope {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            connection_id: Some(Uuid::new_v4()),
            source_device_id: Some(dev_b.id),
            target_device_id: None,
            session_id: None,
            expected_generation: None,
            seq: None,
            server_time: None,
            payload: Payload::HandoffCandidateRequest {
                source_device_id: dev_a.id,
                expected_generation: 1,
                expected_snapshot_revision: 1,
            },
        };
        handle_inbound(&state, &registry, dev_b.id, acc2.id, Uuid::new_v4(), 0, env).await;

        let mut saw_forbidden = false;
        while let Ok(env) = rx_b.try_recv() {
            if let Payload::Error { code, .. } = env.payload {
                assert_eq!(code, ErrorCode::Forbidden);
                saw_forbidden = true;
            }
        }
        assert!(saw_forbidden, "B must receive forbidden for cross-account handoff candidate");
    }
}
