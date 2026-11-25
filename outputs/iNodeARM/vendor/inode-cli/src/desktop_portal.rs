use crate::portal_packet::{self, Packet};
use anyhow::{Context, Result, bail, ensure};
use std::{
    net::{Ipv4Addr, SocketAddrV4},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::net::UdpSocket;
use zeroize::{Zeroize, Zeroizing};
#[path = "desktop_portal_transport.rs"]
mod transport;
use transport::{exchange, transfer_endpoint};
#[path = "desktop_portal_heartbeat.rs"]
mod heartbeat;
use heartbeat::HeartbeatState;
const KEY: &[u8] = b"hello"; // Supplied client's default Portal packet compatibility key.
pub struct Portal {
    socket: UdpSocket,
    target: SocketAddrV4,
    ip: Ipv4Addr,
    serial: u16,
    started: u32,
    auth_type: u8,
    pub info: Packet,
    user: String,
    heartbeat_state: Option<HeartbeatState>,
}
fn address(value: &str) -> Result<SocketAddrV4> {
    let value = value
        .trim()
        .strip_prefix("portal://")
        .unwrap_or(value.trim())
        .trim_end_matches('/');
    let (host, port) = value
        .rsplit_once(':')
        .map(|(h, p)| Ok::<_, anyhow::Error>((h, p.parse::<u16>()?)))
        .transpose()?
        .unwrap_or((value, 50200));
    let ip: Ipv4Addr = host.parse().context("Portal 地址应为 IPv4，可附加 :端口")?;
    ensure!(
        !ip.is_unspecified() && !ip.is_multicast() && port > 0,
        "Invalid Portal address"
    );
    Ok(SocketAddrV4::new(ip, port))
}
impl Portal {
    pub async fn discover(server: &str) -> Result<Self> {
        let target = address(server)?;
        // Use a separate route probe, leaving the receiving socket unconnected:
        // the original accepts replies from the destination IP across UDP ports.
        let probe = std::net::UdpSocket::bind("0.0.0.0:0")?;
        probe.connect(target)?;
        let ip = match probe.local_addr()?.ip() {
            std::net::IpAddr::V4(v) => v,
            _ => bail!("Portal requires IPv4"),
        };
        let socket = UdpSocket::bind((ip, 0)).await?;
        let serial = (SystemTime::now().duration_since(UNIX_EPOCH)?.subsec_nanos() as u16).max(1);
        let attrs = vec![(103, ip.octets().to_vec()), (104, ip.octets().to_vec())];
        let bytes = portal_packet::encode(110, serial, ip, &attrs, KEY)?;
        let info = exchange(
            &socket,
            target,
            &bytes,
            111,
            serial,
            "域查询",
            Duration::from_secs(8),
        )
        .await?;
        ensure!(
            info.error == 0,
            "Portal 域查询失败（错误码 {}）",
            info.error
        );
        let target = transfer_endpoint(&info, target)?;
        let auth_type = info.auth_type;
        ensure!(
            auth_type <= 1,
            "该 Portal 认证方式 {auth_type} 需进一步适配"
        );
        let started = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() as u32;
        Ok(Self {
            socket,
            target,
            ip,
            serial,
            started,
            auth_type,
            info,
            user: String::new(),
            heartbeat_state: None,
        })
    }
    fn addresses(&self) -> Vec<(u8, Vec<u8>)> {
        vec![
            (103, self.ip.octets().to_vec()),
            (104, self.ip.octets().to_vec()),
        ]
    }
    pub async fn login(&mut self, user: &str, password: &str, domain: &str) -> Result<()> {
        ensure!(!user.is_empty() && !password.is_empty(), "请填写账号密码");
        let encryption = self
            .info
            .value(55)
            .and_then(|v| v.first())
            .copied()
            .unwrap_or(0);
        self.user = if domain.is_empty() || user.contains('@') {
            user.to_owned()
        } else {
            format!("{user}@{domain}")
        };
        let mut attrs = self.addresses();
        let interfaces: Vec<_> = getifaddrs::getifaddrs()?.collect();
        let index = interfaces
            .iter()
            .find(|i| i.address.ip_addr() == Some(std::net::IpAddr::V4(self.ip)))
            .and_then(|i| i.index);
        let mac = interfaces.iter().find_map(|i| {
            if index.is_some() && i.index == index {
                i.address.mac_addr()
            } else {
                None
            }
        });
        attrs.push((
            33,
            crate::portal_compat::client_info(mac.as_ref().map(|m| m.as_slice()))?,
        ));
        let encoded_password = crate::portal_compat::password(password, encryption)?;
        attrs.push((101, self.user.as_bytes().to_vec()));
        attrs.push((102, encoded_password.to_vec()));
        if encryption != 0 {
            attrs.push((56, vec![encryption]));
        }
        attrs.push((113, self.started.to_be_bytes().to_vec()));
        let packet = Zeroizing::new(portal_packet::encode_auth(
            100,
            self.auth_type,
            self.serial,
            self.ip,
            &attrs,
            KEY,
        )?);
        for (t, v) in &mut attrs {
            if *t == 102 {
                v.zeroize();
            }
        }
        let reply = exchange(
            &self.socket,
            self.target,
            &packet,
            101,
            self.serial,
            "登录认证",
            Duration::from_secs(25),
        )
        .await?;
        ensure!(
            reply.error == 0,
            "{}",
            crate::portal_reply::authentication_failure(&reply)
        );
        self.heartbeat_state = Some(HeartbeatState::login(&reply)?);
        let mut reply = reply;
        if reply.value(100).is_none() {
            if let Some(id) = self.info.value(100) {
                reply.attrs.push((100, id.to_vec()));
            }
        }
        self.info = reply;
        Ok(())
    }
    async fn logout(&mut self) -> Result<()> {
        let mut attrs = self.addresses();
        attrs.push((101, self.user.as_bytes().to_vec()));
        if let Some(id) = self.info.value(100) {
            attrs.push((100, id.to_vec()));
        }
        let bytes =
            portal_packet::encode_auth(102, self.auth_type, self.serial, self.ip, &attrs, KEY)?;
        let reply = exchange(
            &self.socket,
            self.target,
            &bytes,
            103,
            self.serial,
            "下线",
            Duration::from_secs(8),
        )
        .await?;
        ensure!(
            reply.error == 0,
            "Portal 下线失败（错误码 {}）",
            reply.error
        );
        Ok(())
    }
}
pub async fn connected(
    server: &str,
    user: &str,
    mut password: Zeroizing<String>,
    domain: &str,
) -> Result<()> {
    let mut stop = crate::stop_receiver();
    let mut portal = tokio::select! {r=Portal::discover(server)=>r?,_= &mut stop=>return Ok(())};
    tokio::select! {r=portal.login(user,&password,domain)=>r?,_= &mut stop=>{let _=portal.logout().await;return Ok(())}};
    password.zeroize();
    crate::event(serde_json::json!({"event":"authenticated"}));
    crate::event(
        serde_json::json!({"event":"connected","mode":"portal","address":portal.ip.to_string(),"interface":""}),
    );
    let result = portal.maintain(stop).await;
    let logout = portal.logout().await;
    if result.is_ok() {
        logout?;
        crate::event(serde_json::json!({"event":"disconnected"}));
    }
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn portal_uses_separate_ipv4_endpoint() {
        assert_eq!(address("192.0.2.10").unwrap().port(), 50200);
        assert_eq!(address("192.0.2.10:50100").unwrap().port(), 50100);
        assert!(address("https://example.com").is_err());
    }
}

#[cfg(test)]
#[path = "desktop_portal_tests.rs"]
mod network_tests;
