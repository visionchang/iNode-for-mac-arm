use crate::portal_packet::Packet;
use serde::Serialize;

fn text(bytes: &[u8]) -> String {
    let bytes = bytes.split(|b| *b == 0).next().unwrap_or_default();
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_owned(),
        Err(_) => encoding_rs::GBK
            .decode_without_bom_handling(bytes)
            .0
            .into_owned(),
    }
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct DomainOption {
    pub id: String,
    pub name: String,
}
pub fn domain_options(packet: &Packet) -> Vec<DomainOption> {
    let labels = packet.value(61).map(text).unwrap_or_default();
    let labels: Vec<_> = labels.split(',').collect();
    // Keep positions, including empty labels, so a missing label cannot shift
    // the ID-to-name association for subsequent services.
    packet
        .value(60)
        .map(text)
        .unwrap_or_default()
        .split(',')
        .enumerate()
        .filter_map(|(i, id)| {
            let id = id.trim();
            if id.is_empty() {
                return None;
            }
            let label = labels.get(i).copied().unwrap_or("").trim();
            Some(DomainOption {
                id: id.to_owned(),
                name: if label.is_empty() { id } else { label }.to_owned(),
            })
        })
        .collect()
}

pub fn authentication_failure(packet: &Packet) -> String {
    // These code meanings are from the supplied client's Authentication jump
    // table and Chinese resources. Code 1 is general rejection, not proof of
    // a bad password. Preserve code 115's meaning without echoing arbitrary
    // server text, which could contain account secrets or encoded credentials.
    let reason = match packet.error {
        1 => "认证请求被服务器拒绝",
        2 => "用户已在线或存在未结束的连接",
        3 => "用户正在认证过程中，请稍后再试",
        4 => "认证挑战处理失败",
        6 => "客户端版本未通过服务器校验",
        124 => "认证网络错误",
        125 => "用户名或密码长度不符合要求",
        126 => "当前 IP 不在 Portal 服务器管理范围内",
        127 => "Portal 服务器正在停止服务",
        _ => "服务器返回认证失败",
    };
    let mut out = format!("Portal {reason}（错误码 {}）", packet.error);
    if let Some(raw) = packet.value(115) {
        let message = text(raw).to_lowercase();
        let mut categories = Vec::new();
        for (label, patterns) in [
            (
                "用户名或密码校验失败",
                &[
                    "用户名或密码",
                    "用户名密码",
                    "username or password",
                    "user name or password",
                ][..],
            ),
            (
                "用户不存在",
                &[
                    "用户不存在",
                    "账号不存在",
                    "unknown user",
                    "user does not exist",
                    "user not found",
                ][..],
            ),
            (
                "密码校验失败",
                &[
                    "密码错误",
                    "密码不正确",
                    "invalid password",
                    "incorrect password",
                    "wrong password",
                ][..],
            ),
            (
                "账号被锁定或禁用",
                &["锁定", "禁用", "locked", "disabled"][..],
            ),
            ("账号或密码已过期", &["过期", "expired"][..]),
            (
                "域或服务受限",
                &["域", "服务类型", "domain", "service type"][..],
            ),
            (
                "终端或 MAC 绑定校验失败",
                &["绑定", "终端", "mac", "网卡", "binding"][..],
            ),
            ("客户端版本校验失败", &["版本", "client version"][..]),
            (
                "已在线或并发连接受限",
                &["在线", "并发", "already online", "concurrent"][..],
            ),
            (
                "认证服务器或网络异常",
                &[
                    "认证服务器",
                    "radius",
                    "authentication server",
                    "超时",
                    "timeout",
                ][..],
            ),
            (
                "无访问权限",
                &["无权限", "权限不足", "not allowed", "permission denied"][..],
            ),
        ] {
            if patterns.iter().any(|p| message.contains(p)) {
                categories.push(label);
            }
        }
        if !categories.is_empty() {
            out.push_str("；服务器说明：");
            out.push_str(&categories.join("、"));
        } else if !message.trim().is_empty() {
            out.push_str("；服务器附带了其他拒绝说明，需结合管理员认证日志确认");
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    fn packet(attrs: Vec<(u8, Vec<u8>)>) -> Packet {
        Packet {
            kind: 101,
            auth_type: 0,
            serial: 1,
            error: 1,
            attrs,
        }
    }
    #[test]
    fn maps_real_gbk_domain_names_without_reordering_ids() {
        let labels = encoding_rs::GBK
            .encode("政务外网,WEB,客户端,二维码,")
            .0
            .into_owned();
        let p = packet(vec![(60, b"cegn,web,portal,guest,".to_vec()), (61, labels)]);
        let options = domain_options(&p);
        assert_eq!(
            options
                .iter()
                .map(|o| (o.id.as_str(), o.name.as_str()))
                .collect::<Vec<_>>(),
            vec![
                ("cegn", "政务外网"),
                ("web", "WEB"),
                ("portal", "客户端"),
                ("guest", "二维码")
            ]
        );
        let p = packet(vec![
            (60, b"a,b,c,".to_vec()),
            (61, b"First,,Third,".to_vec()),
        ]);
        assert_eq!(domain_options(&p)[2].name, "Third");
        assert_eq!(domain_options(&p)[1].name, "b");
    }
    #[test]
    fn general_rejection_does_not_assert_invalid_password() {
        let p = packet(vec![]);
        assert_eq!(
            authentication_failure(&p),
            "Portal 认证请求被服务器拒绝（错误码 1）"
        );
        let p = packet(vec![(
            115,
            encoding_rs::GBK
                .encode("用户名或密码错误 secret%26password")
                .0
                .into_owned(),
        )]);
        let error = authentication_failure(&p);
        assert!(error.contains("用户名或密码校验失败"));
        assert!(!error.contains("secret"));
        let p = packet(vec![(115, b"Cookie=synthetic-secret".to_vec())]);
        assert!(!authentication_failure(&p).contains("synthetic-secret"));
    }
}
