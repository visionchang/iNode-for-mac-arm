use super::KEY;
use crate::portal_packet::{self, Packet};
use anyhow::{Context, Result, bail, ensure};
use std::{
    net::{Ipv4Addr, SocketAddrV4},
    time::Duration,
};
use tokio::net::UdpSocket;

pub(super) fn transfer_endpoint(info: &Packet, fallback: SocketAddrV4) -> Result<SocketAddrV4> {
    let ip = match info.value(97) {
        Some(v) => std::str::from_utf8(v)?
            .trim_end_matches('\0')
            .parse::<Ipv4Addr>()
            .context("Portal 登录服务器地址无效")?,
        None => *fallback.ip(),
    };
    let port = match info.value(98) {
        Some(v) => {
            ensure!(v.len() == 4, "Portal 登录服务器端口无效");
            u16::try_from(u32::from_be_bytes(v.try_into()?)).context("Portal 登录服务器端口无效")?
        }
        None => fallback.port(),
    };
    ensure!(
        !ip.is_unspecified() && !ip.is_multicast() && port != 0,
        "Portal 登录服务器地址无效"
    );
    Ok(SocketAddrV4::new(ip, port))
}
pub(super) async fn exchange(
    socket: &UdpSocket,
    target: SocketAddrV4,
    request: &[u8],
    kind: u8,
    serial: u16,
    phase: &str,
    limit: Duration,
) -> Result<Packet> {
    socket
        .send_to(request, target)
        .await
        .with_context(|| format!("Portal {phase}发送失败（{target}）"))?;
    let mut observed = None;
    let result = tokio::time::timeout(limit, async {
        let mut bytes = [0; 4096];
        loop {
            let (n, peer) = socket.recv_from(&mut bytes).await?;
            if peer.ip() != std::net::IpAddr::V4(*target.ip()) {
                continue;
            }
            let p = portal_packet::decode(&bytes[..n], KEY)
                .with_context(|| format!("Portal {phase}响应格式或校验错误"))?;
            observed = Some((p.kind, p.serial, p.error));
            ensure!(p.kind != 118, "Portal 服务器已通知下线");
            ensure!(
                ![121, 127].contains(&p.kind),
                "该 Portal 要求附加客户端校验，当前版本需进一步适配"
            );
            // The supplied client checks source, digest and response type,
            // but does not require the server to echo g_usSerialNo. Some
            // deployments return their own sequence. Keep our outgoing
            // session number unchanged instead of adopting that value.
            if p.kind == kind {
                return Ok(p);
            }
        }
    })
    .await;
    match result {
        Ok(r) => r,
        Err(_) => {
            let detail = match observed {
                Some((k, s, e)) => format!("收到不匹配响应：类型 {k}，会话 {s}，错误码 {e}"),
                None => "未收到该服务器的响应".to_owned(),
            };
            bail!("Portal {phase}超时（{target}；请求编号 {serial}；{detail}）");
        }
    }
}
