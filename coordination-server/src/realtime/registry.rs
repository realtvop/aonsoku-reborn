//! In-memory connection registry (design §9.2, §14).
//!
//! Tracks active WebSocket connections per device. The registry is used to
//! route real-time messages (snapshots, commands, handoff) between devices
//! on the same account. On server restart, the registry is rebuilt from
//! SQLite presence records.

use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

use parking_lot::RwLock;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::protocol::{ConnectionId, ConnectionSeq, DeviceId, Envelope, MessageId};

const COMMAND_ACK_ROUTE_TTL: Duration = Duration::from_secs(30);

/// A live device connection with its outbound channel.
pub struct DeviceConnection {
    pub connection_id: ConnectionId,
    pub device_id: DeviceId,
    pub account_id: Uuid,
    pub tx: mpsc::UnboundedSender<Envelope>,
    pub last_seq: ConnectionSeq,
}

/// Registry of all active connections, indexed by device id.
#[derive(Default)]
pub struct ConnectionRegistry {
    by_device: RwLock<HashMap<DeviceId, DeviceConnection>>,
    by_connection: RwLock<HashMap<ConnectionId, DeviceId>>,
    by_account: RwLock<HashMap<Uuid, Vec<DeviceId>>>,
    /// Devices currently acting as a remote controller (design §10
    /// exclusivity). Key = controller device id (B), value = controlled
    /// device id (A). While B is in this map, other devices may not remote
    /// control or handoff-take B.
    controller_of: RwLock<HashMap<DeviceId, DeviceId>>,
    /// Routes target-device command acknowledgements back to the device that
    /// originally sent the command. Key = command message id.
    command_ack_routes: RwLock<HashMap<MessageId, CommandAckRoute>>,
}

struct CommandAckRoute {
    source_device_id: DeviceId,
    target_device_id: DeviceId,
    expires_at: Instant,
}

impl ConnectionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a new connection. Replaces any existing connection for the
    /// same device (design §9.1 — only one live connection per device).
    pub fn register(&self, conn: DeviceConnection) {
        let device_id = conn.device_id;
        let connection_id = conn.connection_id;
        let account_id = conn.account_id;
        self.by_device.write().insert(device_id, conn);
        self.by_connection.write().insert(connection_id, device_id);
        self.by_account
            .write()
            .entry(account_id)
            .or_default()
            .push(device_id);
    }

    /// Unregister a connection by device id.
    pub fn unregister(&self, device_id: DeviceId) {
        if let Some(conn) = self.by_device.write().remove(&device_id) {
            self.by_connection.write().remove(&conn.connection_id);
            if let Some(list) = self.by_account.write().get_mut(&conn.account_id) {
                list.retain(|d| *d != device_id);
            }
        }
        // Clear any active-control marker so a disconnecting controller does
        // not keep another device locked out (design §10 exclusivity).
        self.controller_of.write().remove(&device_id);
        self.command_ack_routes.write().retain(|_, route| {
            route.source_device_id != device_id && route.target_device_id != device_id
        });
    }

    /// Send an envelope to a device if online.
    pub fn send(&self, device_id: DeviceId, env: Envelope) -> Result<(), SendError> {
        let guard = self.by_device.read();
        match guard.get(&device_id) {
            Some(conn) => conn.tx.send(env).map_err(|_| SendError::DeviceGone),
            None => Err(SendError::DeviceOffline),
        }
    }

    /// List all online device ids for an account.
    pub fn online_devices_for_account(&self, account_id: Uuid) -> Vec<DeviceId> {
        self.by_account
            .read()
            .get(&account_id)
            .cloned()
            .unwrap_or_default()
    }

    /// Check if a device is currently connected.
    pub fn is_online(&self, device_id: DeviceId) -> bool {
        self.by_device.read().contains_key(&device_id)
    }

    /// Return the account id of an online device, if connected. Used by the
    /// realtime handler to enforce cross-account isolation: a command or
    /// handoff request targeting a device on a different account must be
    /// rejected (design §10 — control/handoff is same-account only).
    pub fn account_of(&self, device_id: DeviceId) -> Option<Uuid> {
        self.by_device.read().get(&device_id).map(|c| c.account_id)
    }

    /// Get the connection id for a device, if online.
    pub fn connection_id_for(&self, device_id: DeviceId) -> Option<ConnectionId> {
        self.by_device
            .read()
            .get(&device_id)
            .map(|c| c.connection_id)
    }

    /// Update the last-seen sequence for a device.
    pub fn update_seq(&self, device_id: DeviceId, seq: ConnectionSeq) {
        if let Some(conn) = self.by_device.write().get_mut(&device_id) {
            conn.last_seq = seq;
        }
    }

    /// Mark `controller` as actively remote-controlling `controlled` (design
    /// §10 exclusivity). While active, other devices are forbidden from
    /// remote-controlling or handoff-taking the controller device.
    pub fn begin_control(&self, controller: DeviceId, controlled: DeviceId) {
        self.controller_of.write().insert(controller, controlled);
    }

    /// Clear the active-control marker for `controller` (if any).
    pub fn end_control(&self, controller: DeviceId) {
        self.controller_of.write().remove(&controller);
    }

    /// Whether `device` is currently acting as a remote controller.
    pub fn is_controlling(&self, device: DeviceId) -> bool {
        self.controller_of.read().contains_key(&device)
    }

    /// Remember where the ack for a forwarded command should be sent.
    pub fn remember_command_ack_route(
        &self,
        message_id: MessageId,
        source_device_id: DeviceId,
        target_device_id: DeviceId,
    ) {
        let mut routes = self.command_ack_routes.write();
        Self::prune_expired_command_ack_routes(&mut routes);
        routes.insert(
            message_id,
            CommandAckRoute {
                source_device_id,
                target_device_id,
                expires_at: Instant::now() + COMMAND_ACK_ROUTE_TTL,
            },
        );
    }

    /// Resolve and remove the ack route for a forwarded command.
    pub fn take_command_ack_route(&self, message_id: MessageId) -> Option<DeviceId> {
        let mut routes = self.command_ack_routes.write();
        Self::prune_expired_command_ack_routes(&mut routes);
        routes
            .remove(&message_id)
            .map(|route| route.source_device_id)
    }

    fn prune_expired_command_ack_routes(routes: &mut HashMap<MessageId, CommandAckRoute>) {
        let now = Instant::now();
        routes.retain(|_, route| route.expires_at > now);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendError {
    DeviceOffline,
    DeviceGone,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Payload, PROTOCOL_VERSION};

    fn make_env() -> Envelope {
        Envelope {
            version: PROTOCOL_VERSION,
            message_id: Uuid::new_v4(),
            connection_id: None,
            source_device_id: None,
            target_device_id: None,
            session_id: None,
            expected_generation: None,
            seq: None,
            server_time: None,
            payload: Payload::Heartbeat,
        }
    }

    #[tokio::test]
    async fn register_send_unregister() {
        let reg = ConnectionRegistry::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        let dev = Uuid::new_v4();
        let acc = Uuid::new_v4();
        let conn = DeviceConnection {
            connection_id: Uuid::new_v4(),
            device_id: dev,
            account_id: acc,
            tx,
            last_seq: 0,
        };
        reg.register(conn);
        assert!(reg.is_online(dev));
        let env = make_env();
        reg.send(dev, env).unwrap();
        assert!(rx.try_recv().is_ok());
        reg.unregister(dev);
        assert!(!reg.is_online(dev));
        assert!(reg.send(dev, make_env()).is_err());
    }

    #[tokio::test]
    async fn online_devices_for_account() {
        let reg = ConnectionRegistry::new();
        let acc = Uuid::new_v4();
        let d1 = Uuid::new_v4();
        let d2 = Uuid::new_v4();
        for d in [d1, d2] {
            let (tx, _) = mpsc::unbounded_channel();
            reg.register(DeviceConnection {
                connection_id: Uuid::new_v4(),
                device_id: d,
                account_id: acc,
                tx,
                last_seq: 0,
            });
        }
        let online = reg.online_devices_for_account(acc);
        assert_eq!(online.len(), 2);
    }

    #[tokio::test]
    async fn control_marker_set_and_cleared() {
        let reg = ConnectionRegistry::new();
        let controller = Uuid::new_v4();
        let controlled = Uuid::new_v4();
        let acc = Uuid::new_v4();
        let (tx, _rx) = mpsc::unbounded_channel();
        reg.register(DeviceConnection {
            connection_id: Uuid::new_v4(),
            device_id: controller,
            account_id: acc,
            tx,
            last_seq: 0,
        });
        reg.begin_control(controller, controlled);
        assert!(reg.is_controlling(controller));
        reg.end_control(controller);
        assert!(!reg.is_controlling(controller));
    }

    #[tokio::test]
    async fn unregister_clears_control_marker() {
        let reg = ConnectionRegistry::new();
        let controller = Uuid::new_v4();
        let controlled = Uuid::new_v4();
        let acc = Uuid::new_v4();
        let (tx, _rx) = mpsc::unbounded_channel();
        reg.register(DeviceConnection {
            connection_id: Uuid::new_v4(),
            device_id: controller,
            account_id: acc,
            tx,
            last_seq: 0,
        });
        reg.begin_control(controller, controlled);
        assert!(reg.is_controlling(controller));
        reg.unregister(controller);
        // After the controller disconnects the exclusivity marker is cleared
        // so other devices can again control/handoff-take it.
        assert!(!reg.is_controlling(controller));
    }

    #[tokio::test]
    async fn command_ack_routes_are_one_shot_and_cleared_on_unregister() {
        let reg = ConnectionRegistry::new();
        let source = Uuid::new_v4();
        let target = Uuid::new_v4();
        let message_id = Uuid::new_v4();
        let acc = Uuid::new_v4();
        let (tx, _rx) = mpsc::unbounded_channel();
        reg.register(DeviceConnection {
            connection_id: Uuid::new_v4(),
            device_id: source,
            account_id: acc,
            tx,
            last_seq: 0,
        });

        reg.remember_command_ack_route(message_id, source, target);
        assert_eq!(reg.take_command_ack_route(message_id), Some(source));
        assert_eq!(reg.take_command_ack_route(message_id), None);

        reg.remember_command_ack_route(message_id, source, target);
        reg.unregister(source);
        assert_eq!(reg.take_command_ack_route(message_id), None);
    }

    #[tokio::test]
    async fn command_ack_routes_are_cleared_when_target_unregisters() {
        let reg = ConnectionRegistry::new();
        let source = Uuid::new_v4();
        let target = Uuid::new_v4();
        let message_id = Uuid::new_v4();
        let acc = Uuid::new_v4();
        let (tx, _rx) = mpsc::unbounded_channel();
        reg.register(DeviceConnection {
            connection_id: Uuid::new_v4(),
            device_id: target,
            account_id: acc,
            tx,
            last_seq: 0,
        });

        reg.remember_command_ack_route(message_id, source, target);
        reg.unregister(target);
        assert_eq!(reg.take_command_ack_route(message_id), None);
    }
}
