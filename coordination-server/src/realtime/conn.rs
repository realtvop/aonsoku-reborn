//! WebSocket connection handler (design §9, §10).
//!
//! The endpoint authenticates via a one-time WebSocket ticket (design §6.3),
//! performs the Hello/Welcome handshake with capability negotiation, and
//! processes incoming envelopes. Outgoing envelopes are sent through the
//! connection registry's channel.

use std::sync::Arc;

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Query, State,
    },
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::errors::ErrorCode;
use crate::protocol::{
    CapabilitySet, ConnectionId, ConnectionSeq, DeviceId, Envelope, Payload, PROTOCOL_VERSION,
};
use crate::realtime::registry::{ConnectionRegistry, DeviceConnection};
use crate::server::AppState;
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

    // Mark device online in SQLite presence.
    let presence = crate::storage::models::DevicePresence {
        device_id,
        account_id,
        is_online: true,
        last_seen_at: Some(chrono::Utc::now()),
        last_seq: 0,
    };
    let _ = state.repos.presence.upsert(&presence).await;
    let _ = state
        .repos
        .devices
        .mark_online(device_id, chrono::Utc::now())
        .await;

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

    // Mark offline.
    registry.unregister(device_id);
    let _ = state
        .repos
        .devices
        .mark_offline(device_id, chrono::Utc::now())
        .await;
    let _ = state
        .repos
        .presence
        .upsert(&crate::storage::models::DevicePresence {
            device_id,
            account_id,
            is_online: false,
            last_seen_at: Some(chrono::Utc::now()),
            last_seq: 0,
        })
        .await;
    crate::api::devices::broadcast_device_list(&state, account_id).await;
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
            // Update presence.
            let _ = state
                .repos
                .presence
                .upsert(&crate::storage::models::DevicePresence {
                    device_id,
                    account_id,
                    is_online: true,
                    last_seen_at: Some(chrono::Utc::now()),
                    last_seq: seq as i64,
                })
                .await;
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
                .repos
                .sessions
                .upsert_snapshot(&session, &snapshot_json)
                .await
            {
                tracing::error!(target: "coordination::ws", "failed to upsert snapshot: {:?}", err);
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
            // Route command to target device (design §10).
            if let Err(e) = command.validate(state.config.max_snapshot_songs) {
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
            let _ = registry.send(*target_device_id, forwarded);
        }
        Payload::HandoffCandidateRequest {
            source_device_id,
            expected_generation,
            expected_snapshot_revision,
        } => {
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
        } => {
            // B has preloaded and is ready (design §11.1 step 3).
            // Start the handoff transaction: validate source, send prepare_relinquish to A.
            // We need the source session id; look it up from the transaction's
            // pending state. For the first version, we create the transaction
            // using the HandoffCandidate that was sent earlier. Since we don't
            // persist the pending transaction here, we rely on the
            // HandoffCoordinator to look up the source session.
            // In a full implementation, the HandoffCandidate would carry the
            // source_session_id; B echoes it back. For now, we use the session_id
            // from the envelope if present.
            if let Some(session_id) = env.session_id {
                let _ = state
                    .handoff
                    .start_transaction(
                        &state.repos.sessions,
                        registry,
                        *transaction_id,
                        env.source_device_id.unwrap_or(device_id), // A is the source
                        session_id,
                        *generation,
                        *snapshot_revision,
                        device_id, // B is the target
                        15,
                    )
                    .await;
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
                    &state.repos.sessions,
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
                    state.handoff.mark_failed(*transaction_id, e.code);
                }
            }
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

trait WithMessageId {
    fn with_message_id(self, id: uuid::Uuid) -> Self;
}

impl WithMessageId for Envelope {
    fn with_message_id(mut self, id: uuid::Uuid) -> Self {
        self.message_id = id;
        self
    }
}
