//! iNode IPv4 Portal v2 packet format, from the supplied client.
use anyhow::{Result, ensure};
use std::net::Ipv4Addr;
#[derive(Debug)]
pub struct Packet {
    pub kind: u8,
    pub auth_type: u8,
    pub serial: u16,
    pub error: u8,
    pub attrs: Vec<(u8, Vec<u8>)>,
}
impl Packet {
    pub fn value(&self, t: u8) -> Option<&[u8]> {
        self.attrs
            .iter()
            .find(|(k, _)| *k == t)
            .map(|(_, v)| v.as_slice())
    }
    pub fn domains(&self) -> Vec<String> {
        self.value(60)
            .map(|v| {
                String::from_utf8_lossy(v)
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    }
}
pub fn encode(
    kind: u8,
    serial: u16,
    ip: Ipv4Addr,
    attrs: &[(u8, Vec<u8>)],
    key: &[u8],
) -> Result<Vec<u8>> {
    encode_auth(kind, 0, serial, ip, attrs, key)
}
pub fn encode_auth(
    kind: u8,
    auth_type: u8,
    serial: u16,
    ip: Ipv4Addr,
    attrs: &[(u8, Vec<u8>)],
    key: &[u8],
) -> Result<Vec<u8>> {
    ensure!(
        attrs.len() <= 64 && key.len() <= 128,
        "Invalid Portal attributes"
    );
    let mut out = vec![0; 32];
    out[0] = 2;
    out[1] = kind;
    out[2] = auth_type;
    out[4..6].copy_from_slice(&serial.to_be_bytes());
    out[8..12].copy_from_slice(&ip.octets());
    out[15] = attrs.len() as u8;
    for (t, v) in attrs {
        ensure!(v.len() <= 253, "Portal attribute too long");
        out.push(*t);
        out.push((v.len() + 2) as u8);
        out.extend_from_slice(v);
    }
    ensure!(out.len() <= 4096, "Portal packet too large");
    let mut check = out.clone();
    check.extend_from_slice(key);
    let digest = md5::compute(&check);
    out[16..32].copy_from_slice(&digest.0);
    use zeroize::Zeroize;
    check.zeroize();
    Ok(out)
}
pub fn decode(bytes: &[u8], key: &[u8]) -> Result<Packet> {
    ensure!(
        (32..=4096).contains(&bytes.len()) && bytes[0] == 2,
        "Unsupported Portal response"
    );
    let mut check = bytes.to_vec();
    check[16..32].fill(0);
    check.extend_from_slice(key);
    ensure!(
        md5::compute(&check).0.as_slice() == &bytes[16..32],
        "Portal packet integrity check failed"
    );
    let mut attrs = Vec::new();
    let mut offset = 32;
    for _ in 0..bytes[15] {
        ensure!(offset + 2 <= bytes.len(), "Truncated Portal attribute");
        let n = bytes[offset + 1] as usize;
        ensure!(
            n >= 2 && offset + n <= bytes.len(),
            "Invalid Portal attribute length"
        );
        attrs.push((bytes[offset], bytes[offset + 2..offset + n].to_vec()));
        offset += n;
    }
    ensure!(offset == bytes.len(), "Unexpected Portal trailing bytes");
    Ok(Packet {
        kind: bytes[1],
        auth_type: bytes[2],
        serial: u16::from_be_bytes([bytes[4], bytes[5]]),
        error: bytes[14],
        attrs,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn packet_checks_integrity_and_lengths() {
        let ip = "192.0.2.3".parse().unwrap();
        let mut b = encode(
            111,
            7,
            ip,
            &[(60, b"cegn,web,portal,guest,".to_vec())],
            b"hello",
        )
        .unwrap();
        let p = decode(&b, b"hello").unwrap();
        assert_eq!(p.domains(), ["cegn", "web", "portal", "guest"]);
        assert_eq!(p.serial, 7);
        b[32] ^= 1;
        assert!(decode(&b, b"hello").is_err());
    }
}
