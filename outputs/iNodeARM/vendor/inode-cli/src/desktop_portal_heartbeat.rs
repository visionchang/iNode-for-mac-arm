use super::{KEY, Portal};
use crate::portal_packet::{self, Packet};
use anyhow::{Result, bail, ensure};
use std::{future::pending, net::IpAddr, time::Duration};
use tokio::{
    sync::oneshot,
    time::{Instant, sleep_until},
};

pub(super) struct HeartbeatState {
    interval: Option<Duration>,
    timeout: Duration,
    name: Vec<u8>,
    ip_status: u32,
    beat_status: u8,
}
fn milliseconds(packet: &Packet, field: u8) -> Result<Option<Duration>> {
    packet
        .value(field)
        .map(|v| {
            ensure!(v.len() == 8, "Portal 心跳参数 {field} 长度无效");
            let n = u64::from_be_bytes(v.try_into()?);
            Ok(Duration::from_millis(n))
        })
        .transpose()
}
impl HeartbeatState {
    pub(super) fn login(packet: &Packet) -> Result<Self> {
        // E0641 Authentication reads 109/119 as milliseconds and stores the
        // server's attribute 114. StartHeartBeat returns when interval is 0.
        let interval = milliseconds(packet, 109)?.filter(|v| !v.is_zero());
        let timeout = milliseconds(packet, 119)?
            .filter(|v| !v.is_zero())
            .unwrap_or(Duration::from_secs(90));
        let ip_status = match packet.value(120) {
            Some(v) => {
                ensure!(v.len() == 4, "Portal 在线 IP 状态无效");
                u32::from_be_bytes(v.try_into()?)
            }
            None => 1,
        };
        Ok(Self {
            interval,
            timeout,
            name: packet
                .value(114)
                .filter(|v| !v.is_empty())
                .unwrap_or(b"m")
                .to_vec(),
            ip_status,
            beat_status: 99,
        })
    }
    fn update(&mut self, packet: &Packet) -> Result<()> {
        ensure!(
            packet.error == 0,
            "Portal 心跳失败（错误码 {}）",
            packet.error
        );
        if let Some(interval) = milliseconds(packet, 109)? {
            self.interval = (!interval.is_zero()).then_some(interval);
        }
        if let Some(timeout) = milliseconds(packet, 119)?.filter(|v| !v.is_zero()) {
            self.timeout = timeout;
        }
        if let Some(status) = packet.value(125).and_then(|v| v.first()) {
            self.beat_status = *status;
        }
        Ok(())
    }
}

async fn wait_at(when: Option<Instant>) {
    if let Some(when) = when {
        sleep_until(when).await;
    } else {
        pending::<()>().await;
    }
}
impl Portal {
    pub(super) fn heartbeat_packet(&self) -> Result<Vec<u8>> {
        let state = self.heartbeat_state.as_ref().expect("authenticated Portal");
        let mut attrs = self.addresses();
        attrs.push((126, self.ip.octets().to_vec()));
        attrs.push((127, self.ip.octets().to_vec()));
        attrs.push((114, state.name.clone()));
        if let Some(id) = self.info.value(100) {
            attrs.push((100, id.to_vec()));
        }
        if let Some(bas) = self.info.value(10).filter(|v| v.len() == 4) {
            attrs.push((10, bas.to_vec()));
        }
        attrs.push((113, self.started.to_be_bytes().to_vec()));
        attrs.push((122, 0u32.to_be_bytes().to_vec()));
        attrs.push((120, state.ip_status.to_be_bytes().to_vec()));
        attrs.push((125, vec![state.beat_status]));
        attrs.push((96, vec![1]));
        portal_packet::encode_auth(104, self.auth_type, self.serial, self.ip, &attrs, KEY)
    }
    pub(super) async fn maintain(&mut self, mut stop: oneshot::Receiver<()>) -> Result<()> {
        let mut next = self
            .heartbeat_state
            .as_ref()
            .unwrap()
            .interval
            .map(|_| Instant::now());
        let mut deadline = None;
        let mut bytes = [0; 4096];
        loop {
            tokio::select! {
                _ = &mut stop => return Ok(()),
                _ = wait_at(deadline) => bail!("Portal 在线心跳超时（{}；已按服务器超时窗口等待并重发心跳，未收到有效应答）",self.target),
                _ = wait_at(next) => {
                    self.socket.send_to(&self.heartbeat_packet()?, self.target).await?;
                    let state = self.heartbeat_state.as_ref().unwrap();
                    if deadline.is_none() {deadline = Instant::now().checked_add(state.timeout);}
                    // Retransmit only heartbeats while waiting; never resend a
                    // password. E0641 retries lost heartbeat responses at 10 s.
                    next = Instant::now().checked_add(state.interval.unwrap().min(Duration::from_secs(10)));
                },
                received = self.socket.recv_from(&mut bytes) => {
                    let (n, peer) = received?;
                    if peer.ip() != IpAddr::V4(*self.target.ip()) {continue;}
                    let packet = portal_packet::decode(&bytes[..n], KEY)?;
                    ensure!(packet.kind != 118, "Portal 服务器已通知下线");
                    if packet.kind != 105 {continue;}
                    let state = self.heartbeat_state.as_mut().unwrap();
                    state.update(&packet)?;
                    deadline = None;
                    next = state.interval.and_then(|period| Instant::now().checked_add(period));
                },
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn reply(attrs: Vec<(u8, Vec<u8>)>) -> Packet {
        Packet {
            kind: 101,
            auth_type: 0,
            serial: 1,
            error: 0,
            attrs,
        }
    }
    #[test]
    fn zero_or_absent_server_interval_disables_active_heartbeats() {
        assert!(
            HeartbeatState::login(&reply(vec![]))
                .unwrap()
                .interval
                .is_none()
        );
        assert!(
            HeartbeatState::login(&reply(vec![(109, 0u64.to_be_bytes().to_vec())]))
                .unwrap()
                .interval
                .is_none()
        );
    }
    #[test]
    fn server_identity_and_millisecond_schedule_are_preserved() {
        let mut state = HeartbeatState::login(&reply(vec![
            (109, 30_000u64.to_be_bytes().to_vec()),
            (119, 90_000u64.to_be_bytes().to_vec()),
            (114, b"canonical-user".to_vec()),
            (120, 2u32.to_be_bytes().to_vec()),
        ]))
        .unwrap();
        assert_eq!(state.interval, Some(Duration::from_secs(30)));
        assert_eq!(state.timeout, Duration::from_secs(90));
        assert_eq!(state.name, b"canonical-user");
        assert_eq!(state.ip_status, 2);
        assert_eq!(state.beat_status, 99);
        state
            .update(&reply(vec![
                (109, 0u64.to_be_bytes().to_vec()),
                (125, vec![7]),
            ]))
            .unwrap();
        assert!(state.interval.is_none());
        assert_eq!(state.beat_status, 7);
    }
}
